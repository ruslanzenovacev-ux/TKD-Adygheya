// Спортсмены. Родитель добавляет ребёнка и выбирает группу, тренер группы или админ подтверждает.
// До подтверждения оплатить абонемент нельзя — так чужой человек не «прикрепится» к группе.

import { badRequest, conflict, forbidden } from '../domain/errors.js';
import { isIsoDate } from '../domain/time.js';
import { remainingOf } from '../domain/balance.js';
import { ROLES, assertCanSee, assertCanTrain, childView, hasRole, isAdmin, loadChild, nowIso, publicUser, today } from './common.js';

const MAX_CHILDREN_PER_PARENT = 10;
export const CHILD_STATUS = { pending: 'pending', active: 'active', archived: 'archived' };

function cleanName(name) {
  const n = String(name ?? '').trim().replace(/\s+/g, ' ');
  if (n.length < 2 || n.length > 100) throw badRequest('Укажите имя и фамилию ребёнка');
  return n;
}

function cleanBirthDate(value, date) {
  if (value === undefined || value === null || value === '') return null;
  if (!isIsoDate(value) || value > date || value < '1950-01-01') throw badRequest('Проверьте дату рождения');
  return value;
}

async function activeGroup(t, groupId) {
  const group = groupId ? await t.get('groups', String(groupId)) : null;
  if (!group || !group.active) throw badRequest('Выберите группу');
  return group;
}

// Список с остатками: родитель — свои дети, тренер — дети своих групп, админ — все.
export async function listChildren(ctx, user, { groupId, status } = {}) {
  const date = today(ctx);
  return ctx.repo.tx(async (t) => {
    const byId = new Map();
    if (isAdmin(user)) {
      for (const c of groupId ? await t.find('children', 'groupId', groupId) : await t.find('children')) byId.set(c.id, c);
    } else {
      for (const c of await t.find('children', 'parentId', user.id)) byId.set(c.id, c);
      if (hasRole(user, ROLES.trainer)) {
        for (const g of await t.find('groups', 'trainerId', user.id)) {
          if (groupId && g.id !== groupId) continue;
          for (const c of await t.find('children', 'groupId', g.id)) byId.set(c.id, c);
        }
      }
      if (groupId) for (const [id, c] of byId) if (c.groupId !== groupId) byId.delete(id);
    }
    const groups = new Map();
    const out = [];
    for (const c of byId.values()) {
      if (status ? c.status !== status : c.status === CHILD_STATUS.archived) continue;
      if (c.groupId && !groups.has(c.groupId)) groups.set(c.groupId, await t.get('groups', c.groupId));
      out.push(childView(c, date, groups.get(c.groupId)));
    }
    return out.sort((a, b) => a.name.localeCompare(b.name, 'ru'));
  });
}

export async function addChild(ctx, parent, body) {
  const date = today(ctx);
  return ctx.repo.tx(async (t) => {
    const mine = await t.find('children', 'parentId', parent.id);
    if (mine.filter((c) => c.status !== CHILD_STATUS.archived).length >= MAX_CHILDREN_PER_PARENT) {
      throw conflict('Слишком много детей в одном аккаунте');
    }
    const name = cleanName(body.name);
    if (mine.some((c) => c.status !== CHILD_STATUS.archived && c.name.toLowerCase() === name.toLowerCase())) {
      throw conflict('Ребёнок с таким именем уже добавлен');
    }
    const group = await activeGroup(t, body.groupId);
    const child = {
      id: ctx.ids.uuid(),
      parentId: parent.id,
      name,
      birthDate: cleanBirthDate(body.birthDate, date),
      groupId: group.id,
      status: CHILD_STATUS.pending,
      ledger: { pkgs: [], debt: 0 },
      createdAt: nowIso(ctx),
    };
    await t.put('children', child);
    return childView(child, date, group);
  });
}

export async function approveChild(ctx, user, childId) {
  const date = today(ctx);
  return ctx.repo.tx(async (t) => {
    const child = await loadChild(t, childId);
    await assertCanTrain(t, user, child);
    if (child.status !== CHILD_STATUS.pending) throw conflict('Спортсмен уже подтверждён');
    child.status = CHILD_STATUS.active;
    child.approvedBy = user.id;
    child.approvedAt = nowIso(ctx);
    await t.put('children', child);
    return childView(child, date, await t.get('groups', child.groupId));
  });
}

// Родитель может поправить имя и дату рождения своего ребёнка.
// Админ — ещё группу и статус (перевод в другую группу, архив).
export async function updateChild(ctx, user, childId, body) {
  const date = today(ctx);
  return ctx.repo.tx(async (t) => {
    const child = await loadChild(t, childId);
    const admin = isAdmin(user);
    if (!admin && child.parentId !== user.id) throw forbidden();
    if (body.name !== undefined) child.name = cleanName(body.name);
    if (body.birthDate !== undefined) child.birthDate = cleanBirthDate(body.birthDate, date);
    if (body.groupId !== undefined) {
      if (!admin) throw forbidden('Перевести в другую группу может администратор');
      child.groupId = (await activeGroup(t, body.groupId)).id;
    }
    if (body.status !== undefined) {
      if (!admin) throw forbidden();
      if (!Object.values(CHILD_STATUS).includes(body.status)) throw badRequest('Неизвестный статус');
      child.status = body.status;
    }
    await t.put('children', child);
    return childView(child, date, child.groupId ? await t.get('groups', child.groupId) : null);
  });
}

// Карточка ребёнка: остаток, абонементы, последние посещения и платежи.
export async function getChild(ctx, user, childId) {
  const date = today(ctx);
  return ctx.repo.tx(async (t) => {
    const child = await loadChild(t, childId);
    await assertCanSee(t, user, child);
    const group = child.groupId ? await t.get('groups', child.groupId) : null;
    const packages = await t.find('packages', 'childId', child.id);
    const attendance = await t.find('attendance', 'childId', child.id);
    const payments = await t.find('payments', 'childId', child.id);
    const parent = isAdmin(user) || child.parentId !== user.id ? await t.get('users', child.parentId) : null;
    return {
      ...childView(child, date, group),
      parent: parent ? publicUser(parent) : undefined,
      packages: packages
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
        .map((p) => ({
          id: p.id,
          title: p.title,
          lessonsTotal: p.lessonsTotal,
          lessonsUsed: p.lessonsUsed,
          remaining: p.revoked ? 0 : remainingOf(p),
          validFrom: p.validFrom,
          validUntil: p.validUntil,
          expired: p.validUntil < date,
          revoked: Boolean(p.revoked),
          source: p.source,
        })),
      attendance: attendance
        .filter((a) => a.status === 'present')
        .sort((a, b) => b.date.localeCompare(a.date))
        .slice(0, 100)
        .map((a) => ({ id: a.id, date: a.date, groupId: a.groupId, debt: !a.packageId })),
      payments: payments
        .filter((p) => p.status !== 'failed')
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
        .slice(0, 50)
        .map((p) => ({ id: p.id, createdAt: p.createdAt, amount: p.amount, title: p.title, status: p.status, method: p.method })),
    };
  });
}

