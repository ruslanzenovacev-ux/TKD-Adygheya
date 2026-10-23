// Группы (с тренером и расписанием) и виды абонементов. Настраивает администратор.

import { badRequest, forbidden, notFound } from '../domain/errors.js';
import { ROLES, hasRole, isAdmin, nowIso } from './common.js';

function cleanText(value, field, { min = 1, max = 200 } = {}) {
  const s = String(value ?? '').trim();
  if (s.length < min || s.length > max) throw badRequest(`Проверьте поле «${field}»`);
  return s;
}

function intInRange(value, field, min, max) {
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) throw badRequest(`Поле «${field}»: от ${min} до ${max}`);
  return n;
}

// Цена приходит в рублях (например 4000 или 4000.50), храним в копейках.
function rublesToKopecks(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0 || n > 1_000_000) throw badRequest('Проверьте цену');
  return Math.round(n * 100);
}

const planView = (p) => ({ id: p.id, title: p.title, lessons: p.lessons, price: p.price, validDays: p.validDays, active: p.active });

export async function listPlans(ctx, user) {
  const plans = await ctx.repo.tx((t) => t.find('plans'));
  return plans
    .filter((p) => p.active || isAdmin(user))
    .sort((a, b) => a.lessons - b.lessons)
    .map(planView);
}

export async function createPlan(ctx, admin, body) {
  if (!isAdmin(admin)) throw forbidden();
  const plan = {
    id: ctx.ids.uuid(),
    title: cleanText(body.title, 'Название', { max: 80 }),
    lessons: intInRange(body.lessons, 'Занятий', 1, 200),
    price: rublesToKopecks(body.priceRub),
    validDays: intInRange(body.validDays, 'Срок действия, дней', 1, 366),
    active: true,
    createdAt: nowIso(ctx),
  };
  await ctx.repo.tx((t) => t.put('plans', plan));
  return planView(plan);
}

// Изменение цены не влияет на уже купленные абонементы: в платеже сохраняется цена на момент покупки.
export async function updatePlan(ctx, admin, id, body) {
  if (!isAdmin(admin)) throw forbidden();
  return ctx.repo.tx(async (t) => {
    const plan = await t.get('plans', id);
    if (!plan) throw notFound('Абонемент не найден');
    if (body.title !== undefined) plan.title = cleanText(body.title, 'Название', { max: 80 });
    if (body.lessons !== undefined) plan.lessons = intInRange(body.lessons, 'Занятий', 1, 200);
    if (body.priceRub !== undefined) plan.price = rublesToKopecks(body.priceRub);
    if (body.validDays !== undefined) plan.validDays = intInRange(body.validDays, 'Срок действия, дней', 1, 366);
    if (body.active !== undefined) plan.active = Boolean(body.active);
    await t.put('plans', plan);
    return planView(plan);
  });
}

async function groupView(t, g, withTrainer = true) {
  const trainer = withTrainer && g.trainerId ? await t.get('users', g.trainerId) : null;
  return {
    id: g.id,
    name: g.name,
    schedule: g.schedule ?? '',
    place: g.place ?? '',
    trainerId: g.trainerId ?? null,
    trainerName: trainer?.name ?? null,
    active: g.active,
  };
}

// Родителю нужен список групп, чтобы выбрать группу ребёнка при добавлении.
// Тренер видит свои группы, админ — все.
export async function listGroups(ctx, user, { mine = false } = {}) {
  return ctx.repo.tx(async (t) => {
    let groups = mine ? await t.find('groups', 'trainerId', user.id) : await t.find('groups');
    if (!isAdmin(user)) groups = groups.filter((g) => g.active);
    groups.sort((a, b) => a.name.localeCompare(b.name, 'ru'));
    const out = [];
    for (const g of groups) out.push(await groupView(t, g));
    return out;
  });
}

async function checkTrainer(t, trainerId) {
  if (trainerId === null || trainerId === undefined || trainerId === '') return null;
  const u = await t.get('users', String(trainerId));
  if (!u || !hasRole(u, ROLES.trainer)) throw badRequest('Выбранный пользователь не тренер');
  return u.id;
}

export async function createGroup(ctx, admin, body) {
  if (!isAdmin(admin)) throw forbidden();
  return ctx.repo.tx(async (t) => {
    const group = {
      id: ctx.ids.uuid(),
      name: cleanText(body.name, 'Название группы', { max: 80 }),
      schedule: body.schedule ? cleanText(body.schedule, 'Расписание', { max: 300 }) : '',
      place: body.place ? cleanText(body.place, 'Зал', { max: 200 }) : '',
      trainerId: await checkTrainer(t, body.trainerId),
      active: true,
      createdAt: nowIso(ctx),
    };
    await t.put('groups', group);
    return groupView(t, group);
  });
}

export async function updateGroup(ctx, admin, id, body) {
  if (!isAdmin(admin)) throw forbidden();
  return ctx.repo.tx(async (t) => {
    const group = await t.get('groups', id);
    if (!group) throw notFound('Группа не найдена');
    if (body.name !== undefined) group.name = cleanText(body.name, 'Название группы', { max: 80 });
    if (body.schedule !== undefined) group.schedule = body.schedule ? cleanText(body.schedule, 'Расписание', { max: 300 }) : '';
    if (body.place !== undefined) group.place = body.place ? cleanText(body.place, 'Зал', { max: 200 }) : '';
    if (body.trainerId !== undefined) group.trainerId = await checkTrainer(t, body.trainerId);
    if (body.active !== undefined) group.active = Boolean(body.active);
    await t.put('groups', group);
    return groupView(t, group);
  });
}
