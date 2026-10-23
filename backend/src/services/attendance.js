// Отметка посещений. Приложение тренера хранит отметки в телефоне и отправляет пачкой, когда есть связь.
// Каждая отметка несёт свой id (UUID, создаётся в телефоне), поэтому повторная отправка ничего не задвоит.

import { AppError, badRequest, conflict, notFound } from '../domain/errors.js';
import { pickPackage } from '../domain/balance.js';
import { addDays, isIsoDate } from '../domain/time.js';
import { assertCanTrain, childView, isAdmin, loadChild, nowIso, rebalance, requireRole, ROLES, today } from './common.js';
import { CHILD_STATUS } from './children.js';

const MAX_BATCH = 200;
const MAX_BACKDATE_DAYS = 31;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function markOne(ctx, user, mark, date) {
  const { id, childId } = mark;
  if (typeof id !== 'string' || !UUID_RE.test(id)) throw badRequest('Некорректный id отметки');
  if (!isIsoDate(mark.date)) throw badRequest('Некорректная дата');
  if (mark.date > date) throw badRequest('Нельзя отметить занятие в будущем');
  if (mark.date < addDays(date, -MAX_BACKDATE_DAYS)) throw badRequest('Отметка старше месяца — обратитесь к администратору');

  return ctx.repo.tx(async (t) => {
    const existing = await t.get('attendance', id);
    if (existing) {
      if (existing.childId !== childId) throw conflict('Повтор id отметки');
      return { id, status: existing.status === 'present' ? 'ok' : 'cancelled', debt: !existing.packageId };
    }
    const child = await loadChild(t, childId);
    await assertCanTrain(t, user, child);
    if (child.status !== CHILD_STATUS.active) throw conflict('Спортсмен ещё не подтверждён');

    const history = await t.find('attendance', 'childId', child.id);
    const same = history.find((a) => a.date === mark.date && a.status === 'present');
    if (same) return { id: same.id, status: 'duplicate', debt: !same.packageId };

    const packages = await t.find('packages', 'childId', child.id);
    const pkg = pickPackage(packages, mark.date, date);
    if (pkg) {
      pkg.lessonsUsed += 1;
      await t.put('packages', pkg);
    }
    await t.put('attendance', {
      id,
      childId: child.id,
      groupId: child.groupId,
      groupDate: `${child.groupId}|${mark.date}`,
      date: mark.date,
      trainerId: user.id,
      packageId: pkg?.id ?? null,
      status: 'present',
      createdAt: nowIso(ctx),
    });
    await rebalance(t, ctx, child.id);
    return { id, status: 'ok', debt: !pkg };
  });
}

// Возвращает результат по каждой отметке; ошибка одной не мешает остальным.
export async function markBatch(ctx, user, { marks }) {
  requireRole(user, ROLES.trainer, ROLES.admin);
  if (!Array.isArray(marks) || marks.length === 0) throw badRequest('Нет отметок');
  if (marks.length > MAX_BATCH) throw badRequest(`Не больше ${MAX_BATCH} отметок за раз`);
  const date = today(ctx);
  const results = [];
  for (const mark of marks) {
    try {
      results.push(await markOne(ctx, user, mark ?? {}, date));
    } catch (e) {
      if (!(e instanceof AppError)) throw e;
      results.push({ id: mark?.id ?? null, status: 'error', code: e.code, message: e.message });
    }
  }
  return { results };
}

// Отмена ошибочной отметки: занятие возвращается в тот же абонемент.
export async function cancelMark(ctx, user, attendanceId) {
  requireRole(user, ROLES.trainer, ROLES.admin);
  return ctx.repo.tx(async (t) => {
    const a = await t.get('attendance', attendanceId);
    if (!a) throw notFound('Отметка не найдена');
    const child = await loadChild(t, a.childId);
    await assertCanTrain(t, user, child);
    if (a.status !== 'present') return { id: a.id, status: 'cancelled' };
    if (a.packageId) {
      const pkg = await t.get('packages', a.packageId);
      if (pkg) {
        pkg.lessonsUsed = Math.max(0, pkg.lessonsUsed - 1);
        await t.put('packages', pkg);
      }
    }
    a.status = 'cancelled';
    a.packageId = null;
    a.cancelledBy = user.id;
    a.cancelledAt = nowIso(ctx);
    await t.put('attendance', a);
    await rebalance(t, ctx, child.id);
    return { id: a.id, status: 'cancelled' };
  });
}

// Экран тренера «Занятие»: дети группы с остатком и отметкой за выбранный день.
export async function roster(ctx, user, groupId, { date } = {}) {
  requireRole(user, ROLES.trainer, ROLES.admin);
  const day = date ?? today(ctx);
  if (!isIsoDate(day)) throw badRequest('Некорректная дата');
  const now = today(ctx);
  return ctx.repo.tx(async (t) => {
    const group = await t.get('groups', String(groupId));
    if (!group) throw notFound('Группа не найдена');
    if (!isAdmin(user) && group.trainerId !== user.id) throw notFound('Группа не найдена');
    const children = (await t.find('children', 'groupId', group.id)).filter((c) => c.status !== CHILD_STATUS.archived);
    const marks = (await t.find('attendance', 'groupDate', `${group.id}|${day}`)).filter((a) => a.status === 'present');
    const markByChild = new Map(marks.map((a) => [a.childId, a]));
    return {
      group: { id: group.id, name: group.name, schedule: group.schedule ?? '' },
      date: day,
      children: children
        .map((c) => {
          const m = markByChild.get(c.id);
          return { ...childView(c, now, group), mark: m ? { id: m.id, debt: !m.packageId } : null };
        })
        .sort((a, b) => a.name.localeCompare(b.name, 'ru')),
    };
  });
}
