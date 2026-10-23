// Вход по одноразовому коду на почту (SMS не используем: они платные и не входят в бесплатный лимит).
// Регистрация = первый вход: при нём родитель даёт согласие на обработку персональных данных (152-ФЗ).

import { createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { badRequest, forbidden, tooMany, unauthorized } from '../domain/errors.js';
import { ROLES, isAdmin, nowIso, publicUser } from './common.js';

const CODE_TTL_MS = 10 * 60 * 1000;
const RESEND_AFTER_MS = 60 * 1000;
const MAX_ATTEMPTS = 5;
const SESSION_TTL_MS = 180 * 24 * 60 * 60 * 1000; // полгода: родители не должны часто перелогиниваться
const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // без похожих символов O/0, I/1

export function normalizeEmail(email) {
  const e = String(email ?? '').trim().toLowerCase();
  if (e.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) throw badRequest('Проверьте адрес почты', 'invalid_email');
  return e;
}

const hashToken = (token) => createHash('sha256').update(token).digest('hex');
const codeDigest = (ctx, email, code) => createHmac('sha256', ctx.config.secret).update(`${email}:${code}`).digest();

export async function requestCode(ctx, { email }) {
  const addr = normalizeEmail(email);
  const now = ctx.clock.now().getTime();
  const code = String(randomInt(0, 1_000_000)).padStart(6, '0');

  await ctx.repo.tx(async (t) => {
    const existing = await t.get('loginCodes', addr);
    if (existing && now - existing.sentAt < RESEND_AFTER_MS) {
      throw tooMany('Код уже отправлен. Повторить можно через минуту');
    }
    await t.put('loginCodes', {
      id: addr,
      digest: codeDigest(ctx, addr, code).toString('hex'),
      sentAt: now,
      expiresAt: now + CODE_TTL_MS,
      attempts: 0,
    });
  });

  await ctx.mailer.send({
    to: addr,
    subject: `Код входа: ${code}`,
    text: `Ваш код для входа в приложение секции: ${code}\n\nКод действует 10 минут. Если вы не запрашивали код, просто проигнорируйте это письмо.`,
  });
  return { sent: true };
}

export async function verifyCode(ctx, { email, code, name, phone, consent }) {
  const addr = normalizeEmail(email);
  const now = ctx.clock.now().getTime();
  const codeStr = String(code ?? '').trim();

  // Попытка считается в отдельной транзакции, чтобы её нельзя было «откатить» ошибкой.
  const check = await ctx.repo.tx(async (t) => {
    const rec = await t.get('loginCodes', addr);
    if (!rec || rec.expiresAt < now) return 'expired';
    if (rec.attempts >= MAX_ATTEMPTS) return 'locked';
    const ok = /^\d{6}$/.test(codeStr) && timingSafeEqual(Buffer.from(rec.digest, 'hex'), codeDigest(ctx, addr, codeStr));
    if (!ok) {
      rec.attempts += 1;
      await t.put('loginCodes', rec);
      return 'wrong';
    }
    return 'ok';
  });
  if (check === 'expired') throw badRequest('Код устарел. Запросите новый', 'code_expired');
  if (check === 'locked') throw tooMany('Слишком много попыток. Запросите новый код');
  if (check === 'wrong') throw badRequest('Неверный код', 'code_wrong');

  const token = randomBytes(32).toString('base64url');
  const user = await ctx.repo.tx(async (t) => {
    const rec = await t.get('loginCodes', addr);
    if (!rec || rec.expiresAt < now) throw badRequest('Код устарел. Запросите новый', 'code_expired');
    let [user] = await t.find('users', 'email', addr);
    if (!user) {
      if (consent !== true) throw badRequest('Нужно согласие на обработку персональных данных', 'consent_required');
      const cleanName = String(name ?? '').trim();
      if (cleanName.length < 2 || cleanName.length > 100) throw badRequest('Укажите имя и фамилию', 'name_required');
      const roles = [ROLES.parent];
      if (ctx.config.adminEmails.includes(addr)) roles.push(ROLES.admin);
      user = {
        id: ctx.ids.uuid(),
        email: addr,
        name: cleanName,
        phone: phone ? String(phone).trim().slice(0, 20) : null,
        roles,
        consentAt: nowIso(ctx),
        createdAt: nowIso(ctx),
      };
      await t.put('users', user);
    }
    await t.del('loginCodes', addr);
    await t.put('sessions', { id: hashToken(token), userId: user.id, createdAt: now, expiresAt: now + SESSION_TTL_MS });
    return user;
  });
  return { token, user: publicUser(user) };
}

export async function authenticate(ctx, token) {
  if (!token) throw unauthorized();
  const now = ctx.clock.now().getTime();
  return ctx.repo.tx(async (t) => {
    const session = await t.get('sessions', hashToken(token));
    if (!session || session.expiresAt < now) throw unauthorized('Сессия истекла, войдите снова');
    const user = await t.get('users', session.userId);
    if (!user || user.disabled) throw unauthorized();
    return user;
  });
}

export async function logout(ctx, token) {
  await ctx.repo.tx((t) => t.del('sessions', hashToken(token)));
  return { ok: true };
}

export async function updateProfile(ctx, user, { name, phone }) {
  return ctx.repo.tx(async (t) => {
    const u = await t.get('users', user.id);
    if (name !== undefined) {
      const n = String(name).trim();
      if (n.length < 2 || n.length > 100) throw badRequest('Укажите имя и фамилию');
      u.name = n;
    }
    if (phone !== undefined) u.phone = phone ? String(phone).trim().slice(0, 20) : null;
    await t.put('users', u);
    return publicUser(u);
  });
}

// Приглашение тренера: админ создаёт код, тренер входит как обычный пользователь и вводит код.
export async function createTrainerInvite(ctx, admin) {
  if (!isAdmin(admin)) throw forbidden();
  const code = Array.from({ length: 8 }, () => INVITE_ALPHABET[randomInt(0, INVITE_ALPHABET.length)]).join('');
  const now = ctx.clock.now().getTime();
  await ctx.repo.tx((t) => t.put('invites', { id: code, role: ROLES.trainer, createdBy: admin.id, createdAt: now, expiresAt: now + INVITE_TTL_MS, usedBy: null }));
  return { code, expiresAt: new Date(now + INVITE_TTL_MS).toISOString() };
}

export async function redeemInvite(ctx, user, { code }) {
  const id = String(code ?? '').trim().toUpperCase();
  const now = ctx.clock.now().getTime();
  return ctx.repo.tx(async (t) => {
    const invite = id ? await t.get('invites', id) : null;
    if (!invite || invite.usedBy || invite.expiresAt < now) throw badRequest('Код приглашения недействителен', 'invite_invalid');
    const u = await t.get('users', user.id);
    if (!u.roles.includes(invite.role)) u.roles.push(invite.role);
    invite.usedBy = u.id;
    invite.usedAt = now;
    await t.put('users', u);
    await t.put('invites', invite);
    return publicUser(u);
  });
}

export async function listStaff(ctx, admin) {
  if (!isAdmin(admin)) throw forbidden();
  const users = await ctx.repo.tx((t) => t.find('users'));
  return users.filter((u) => u.roles.includes(ROLES.trainer) || u.roles.includes(ROLES.admin)).map(publicUser);
}

// Админ может снять роль тренера (например, тренер ушёл). Админ не может разжаловать сам себя.
export async function setTrainerRole(ctx, admin, userId, enabled) {
  if (!isAdmin(admin)) throw forbidden();
  return ctx.repo.tx(async (t) => {
    const u = await t.get('users', userId);
    if (!u) throw badRequest('Пользователь не найден');
    const has = u.roles.includes(ROLES.trainer);
    if (enabled && !has) u.roles.push(ROLES.trainer);
    if (!enabled && has) u.roles = u.roles.filter((r) => r !== ROLES.trainer);
    await t.put('users', u);
    return publicUser(u);
  });
}
