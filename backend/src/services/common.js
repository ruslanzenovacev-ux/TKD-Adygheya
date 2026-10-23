// Общие помощники сервисов: роли, проверка доступа и пересчёт остатка ребёнка.

import { forbidden, notFound } from '../domain/errors.js';
import { remainingOf, settleDebts } from '../domain/balance.js';
import { mskDate } from '../domain/time.js';

export const ROLES = { parent: 'parent', trainer: 'trainer', admin: 'admin' };

export const hasRole = (user, role) => Array.isArray(user?.roles) && user.roles.includes(role);
export const isAdmin = (user) => hasRole(user, ROLES.admin);

export function requireRole(user, ...roles) {
  if (!roles.some((r) => hasRole(user, r))) throw forbidden();
}

export function today(ctx) {
  return mskDate(ctx.clock.now());
}

export function nowIso(ctx) {
  return ctx.clock.now().toISOString();
}

export async function loadChild(t, childId) {
  const child = typeof childId === 'string' ? await t.get('children', childId) : null;
  if (!child) throw notFound('Спортсмен не найден');
  return child;
}

// Может ли пользователь видеть ребёнка: админ, родитель ребёнка или тренер его группы.
export async function canSeeChild(t, user, child) {
  if (isAdmin(user)) return true;
  if (child.parentId === user.id) return true;
  return canTrainChild(t, user, child);
}

// Может ли пользователь отмечать посещения ребёнка: админ или тренер его текущей группы.
export async function canTrainChild(t, user, child) {
  if (isAdmin(user)) return true;
  if (!hasRole(user, ROLES.trainer) || !child.groupId) return false;
  const group = await t.get('groups', child.groupId);
  return group?.trainerId === user.id;
}

export async function assertCanSee(t, user, child) {
  if (!(await canSeeChild(t, user, child))) throw notFound('Спортсмен не найден');
}

export async function assertCanTrain(t, user, child) {
  if (!(await canTrainChild(t, user, child))) throw forbidden('Это не ваш спортсмен');
}

// Гасит долги свободными занятиями и сохраняет в карточке ребёнка краткую сводку (ledger),
// чтобы списки с остатками строились без чтения всех пакетов и посещений.
// Вызывается в конце каждой транзакции, которая меняет пакеты или посещения ребёнка.
export async function rebalance(t, ctx, childId) {
  const date = today(ctx);
  const child = await t.get('children', childId);
  const packages = await t.find('packages', 'childId', childId);
  const attendance = await t.find('attendance', 'childId', childId);
  const debts = attendance.filter((a) => a.status === 'present' && !a.packageId);

  const assignments = settleDebts(packages, debts, date);
  const byId = new Map(packages.map((p) => [p.id, p]));
  for (const { attendanceId, packageId } of assignments) {
    const a = attendance.find((x) => x.id === attendanceId);
    a.packageId = packageId;
    a.settledAt = nowIso(ctx);
    await t.put('attendance', a);
  }
  for (const id of new Set(assignments.map((x) => x.packageId))) await t.put('packages', byId.get(id));

  child.ledger = {
    pkgs: packages
      .filter((p) => !p.revoked && remainingOf(p) > 0)
      .map((p) => ({ id: p.id, validUntil: p.validUntil, remaining: remainingOf(p) })),
    debt: debts.length - assignments.length,
    updatedAt: nowIso(ctx),
  };
  await t.put('children', child);
  return child;
}

// Остаток по сводке ребёнка на дату `date` (сгоревшие пакеты не считаются).
export function balanceOf(child, date) {
  const pkgs = (child.ledger?.pkgs ?? []).filter((p) => p.validUntil >= date);
  const available = pkgs.reduce((s, p) => s + p.remaining, 0);
  const debt = child.ledger?.debt ?? 0;
  const next = [...pkgs].sort((a, b) => a.validUntil.localeCompare(b.validUntil))[0];
  return {
    available,
    debt,
    balance: available - debt,
    nextExpiry: next ? { date: next.validUntil, lessons: next.remaining } : null,
  };
}

export function publicUser(user) {
  if (!user) return null;
  return { id: user.id, email: user.email, name: user.name, phone: user.phone ?? null, roles: user.roles };
}

export function childView(child, date, group) {
  return {
    id: child.id,
    name: child.name,
    birthDate: child.birthDate ?? null,
    status: child.status,
    groupId: child.groupId ?? null,
    groupName: group?.name ?? null,
    parentId: child.parentId,
    ...balanceOf(child, date),
  };
}
