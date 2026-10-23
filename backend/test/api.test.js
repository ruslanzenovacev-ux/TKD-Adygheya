import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { balanceOf, createTestApp, payOnline, seedClub } from './helpers.js';

const DAY = 24 * 60 * 60 * 1000;
const mark = (app, token, childId, date) => app.call('POST', '/attendance/batch', { token, body: { marks: [{ id: randomUUID(), childId, date }] } });

// ---------- Вход ----------

test('вход по коду: новый пользователь без согласия не регистрируется', async () => {
  const app = createTestApp();
  await app.call('POST', '/auth/request-code', { body: { email: 'New@Mail.ru ' } });
  const code = app.mailer.sent.at(-1).subject.match(/\d{6}/)[0];
  const r = await app.call('POST', '/auth/verify', { body: { email: 'new@mail.ru', code, name: 'Ольга' } });
  assert.equal(r.status, 400);
  assert.equal(r.data.error.code, 'consent_required');
  const ok = await app.call('POST', '/auth/verify', { body: { email: 'new@mail.ru', code, name: 'Ольга', consent: true } });
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.data.user.roles, ['parent']);
});

test('вход: неверный код 5 раз блокирует код, повторная отправка — не чаще раза в минуту', async () => {
  const app = createTestApp();
  await app.call('POST', '/auth/request-code', { body: { email: 'a@b.ru' } });
  const again = await app.call('POST', '/auth/request-code', { body: { email: 'a@b.ru' } });
  assert.equal(again.status, 429);
  for (let i = 0; i < 5; i++) {
    const r = await app.call('POST', '/auth/verify', { body: { email: 'a@b.ru', code: '000000', name: 'X Y', consent: true } });
    assert.equal(r.data.error.code, 'code_wrong');
  }
  const code = app.mailer.sent.at(-1).subject.match(/\d{6}/)[0];
  const locked = await app.call('POST', '/auth/verify', { body: { email: 'a@b.ru', code, name: 'X Y', consent: true } });
  assert.equal(locked.status, 429);
});

test('вход: код живёт 10 минут; почта руководителя получает роль администратора', async () => {
  const app = createTestApp();
  await app.call('POST', '/auth/request-code', { body: { email: 'boss@club.ru' } });
  const code = app.mailer.sent.at(-1).subject.match(/\d{6}/)[0];
  app.advance(11 * 60 * 1000);
  const late = await app.call('POST', '/auth/verify', { body: { email: 'boss@club.ru', code, name: 'Босс', consent: true } });
  assert.equal(late.data.error.code, 'code_expired');
  const token = await app.login('boss@club.ru', 'Босс');
  const me = await app.call('GET', '/me', { token });
  assert.deepEqual(me.data.roles, ['parent', 'admin']);
});

test('без токена и с чужим токеном — 401', async () => {
  const app = createTestApp();
  assert.equal((await app.call('GET', '/children')).status, 401);
  assert.equal((await app.call('GET', '/children', { token: 'fake' })).status, 401);
});

// ---------- Оплата ----------

test('оплата СБП: зачисление после уведомления, повтор уведомления не задваивает', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const { providerId, payment } = await payOnline(app, s);
  assert.equal(payment.amount, 400000);
  assert.ok(payment.confirmationUrl.startsWith('https://'));

  let card = await balanceOf(app, s.parent, s.child.id);
  assert.equal(card.balance, 8);
  assert.equal(card.packages[0].validUntil, '2026-12-16'); // 45 дней, считая день покупки

  await app.call('POST', '/webhooks/yookassa', { body: { event: 'payment.succeeded', object: { id: providerId } } });
  await app.call('POST', '/webhooks/yookassa', { body: { event: 'payment.succeeded', object: { id: providerId } } });
  card = await balanceOf(app, s.parent, s.child.id);
  assert.equal(card.balance, 8);
  assert.equal(card.packages.length, 1);
});

test('оплата: поддельное уведомление «оплачено» не зачисляет, если в ЮKassa платёж не оплачен', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await app.call('POST', '/payments', { token: s.parent, body: { childId: s.child.id, planId: s.plan.id } });
  const [remote] = app.yookassa.payments.values();
  await app.call('POST', '/webhooks/yookassa', {
    body: { event: 'payment.succeeded', object: { id: remote.id, status: 'succeeded', amount: { value: '4000.00', currency: 'RUB' } } },
  });
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 0);
});

test('оплата: сумму задаёт сервер; при расхождении суммы платёж уходит на проверку', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const r = await app.call('POST', '/payments', { token: s.parent, body: { childId: s.child.id, planId: s.plan.id, amount: 1, priceRub: 1 } });
  assert.equal(r.data.amount, 400000);
  const [remote] = app.yookassa.payments.values();
  remote.amount.value = '1.00';
  app.yookassa.succeed(remote.id);
  await app.call('POST', '/webhooks/yookassa', { body: { event: 'payment.succeeded', object: { id: remote.id } } });
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 0);
  const p = await app.call('GET', `/payments/${r.data.id}`, { token: s.admin });
  assert.equal(p.data.status, 'review');
});

test('оплата: если уведомление потерялось, статус подтянется при открытии платежа', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const r = await app.call('POST', '/payments', { token: s.parent, body: { childId: s.child.id, planId: s.plan.id } });
  const [remote] = app.yookassa.payments.values();
  app.yookassa.succeed(remote.id);
  app.advance(10_000);
  const p = await app.call('GET', `/payments/${r.data.id}`, { token: s.parent });
  assert.equal(p.data.status, 'succeeded');
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 8);
});

test('оплата: повторное нажатие не создаёт второй платёж; отменённый платёж ничего не зачисляет', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const a = await app.call('POST', '/payments', { token: s.parent, body: { childId: s.child.id, planId: s.plan.id } });
  const b = await app.call('POST', '/payments', { token: s.parent, body: { childId: s.child.id, planId: s.plan.id } });
  assert.equal(a.data.id, b.data.id);
  assert.equal(app.yookassa.created, 1);
  const [remote] = app.yookassa.payments.values();
  remote.status = 'canceled';
  await app.call('POST', '/webhooks/yookassa', { body: { event: 'payment.canceled', object: { id: remote.id } } });
  const p = await app.call('GET', `/payments/${a.data.id}`, { token: s.parent });
  assert.equal(p.data.status, 'canceled');
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 0);
});

test('оплата: до подтверждения тренером нельзя; чужого ребёнка оплатить нельзя', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const pending = (await app.call('POST', '/children', { token: s.parent, body: { name: 'Оля Петрова', groupId: s.group.id } })).data;
  const r = await app.call('POST', '/payments', { token: s.parent, body: { childId: pending.id, planId: s.plan.id } });
  assert.equal(r.status, 409);
  const stranger = await app.login('stranger@mail.ru', 'Чужой Человек');
  const r2 = await app.call('POST', '/payments', { token: stranger, body: { childId: s.child.id, planId: s.plan.id } });
  assert.equal(r2.status, 404);
});

// ---------- Посещения ----------

test('посещение: списывает занятие, повторная отправка той же отметки не задваивает, отмена возвращает', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await payOnline(app, s);
  const id = randomUUID();
  const body = { marks: [{ id, childId: s.child.id, date: '2026-11-02' }] };
  const r1 = await app.call('POST', '/attendance/batch', { token: s.trainer, body });
  const r2 = await app.call('POST', '/attendance/batch', { token: s.trainer, body }); // офлайн-синхронизация повторила
  assert.equal(r1.data.results[0].status, 'ok');
  assert.equal(r2.data.results[0].status, 'ok');
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 7);

  const dup = await mark(app, s.trainer, s.child.id, '2026-11-02'); // второй телефон, тот же день
  assert.equal(dup.data.results[0].status, 'duplicate');
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 7);

  await app.call('POST', `/attendance/${id}/cancel`, { token: s.trainer });
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 8);
});

test('посещение без занятий уходит в долг, следующая покупка его гасит', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const r = await mark(app, s.trainer, s.child.id, '2026-11-02');
  assert.equal(r.data.results[0].debt, true);
  let card = await balanceOf(app, s.parent, s.child.id);
  assert.equal(card.balance, -1);
  await payOnline(app, s);
  card = await balanceOf(app, s.parent, s.child.id);
  assert.deepEqual([card.balance, card.debt, card.available], [7, 0, 7]);
  assert.equal(card.attendance[0].debt, false);
});

test('посещение: чужой тренер и родитель отметить не могут; будущая дата и дата старше месяца отклоняются', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await payOnline(app, s);
  const other = await mark(app, s.trainer2, s.child.id, '2026-11-02');
  assert.equal(other.data.results[0].code, 'forbidden');
  const parent = await mark(app, s.parent, s.child.id, '2026-11-02');
  assert.equal(parent.status, 403);
  const future = await mark(app, s.trainer, s.child.id, '2026-11-03');
  assert.equal(future.data.results[0].status, 'error');
  const old = await mark(app, s.trainer, s.child.id, '2026-09-01');
  assert.equal(old.data.results[0].status, 'error');
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 8);
});

test('ошибка в одной отметке пачки не мешает остальным', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await payOnline(app, s);
  const r = await app.call('POST', '/attendance/batch', {
    token: s.trainer,
    body: {
      marks: [
        { id: 'not-a-uuid', childId: s.child.id, date: '2026-11-01' },
        { id: randomUUID(), childId: s.child.id, date: '2026-11-02' },
      ],
    },
  });
  assert.deepEqual(r.data.results.map((x) => x.status), ['error', 'ok']);
});

test('абонемент сгорает по сроку', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await payOnline(app, s);
  app.setNow('2026-12-16T20:00:00Z'); // 23:00 МСК последнего дня — ещё действует
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 8);
  app.setNow('2026-12-16T21:30:00Z'); // 00:30 МСК следующего дня
  const card = await balanceOf(app, s.parent, s.child.id);
  assert.equal(card.balance, 0);
  assert.equal(card.packages[0].expired, true);
});

// ---------- Доступ и экраны ----------

test('экран тренера: своя группа с остатками и отметками за день; чужую группу не видно', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await payOnline(app, s);
  await mark(app, s.trainer, s.child.id, '2026-11-02');
  const r = await app.call('GET', `/groups/${s.group.id}/roster`, { token: s.trainer, query: { date: '2026-11-02' } });
  assert.equal(r.data.children.length, 1);
  assert.equal(r.data.children[0].balance, 7);
  assert.ok(r.data.children[0].mark);
  const foreign = await app.call('GET', `/groups/${s.group.id}/roster`, { token: s.trainer2 });
  assert.equal(foreign.status, 404);
  const list2 = await app.call('GET', '/children', { token: s.trainer2 });
  assert.equal(list2.data.length, 0);
});

test('родитель видит только своих детей; админ видит всех и родителя ребёнка', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const other = await app.login('papa@mail.ru', 'Олег Сидоров');
  await app.call('POST', '/children', { token: other, body: { name: 'Вася Сидоров', groupId: s.group.id } });
  assert.equal((await app.call('GET', '/children', { token: s.parent })).data.length, 1);
  assert.equal((await app.call('GET', `/children/${s.child.id}`, { token: other })).status, 404);
  assert.equal((await app.call('GET', '/children', { token: s.admin })).data.length, 2);
  const card = await app.call('GET', `/children/${s.child.id}`, { token: s.admin });
  assert.equal(card.data.parent.email, 'mama@mail.ru');
});

test('родитель не может назначать группы, абонементы и цены', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  assert.equal((await app.call('POST', '/plans', { token: s.parent, body: { title: 'x', lessons: 1, priceRub: 1, validDays: 1 } })).status, 403);
  assert.equal((await app.call('PATCH', `/children/${s.child.id}`, { token: s.parent, body: { groupId: s.group2.id } })).status, 403);
  assert.equal((await app.call('POST', '/payments/manual', { token: s.parent, body: { childId: s.child.id, planId: s.plan.id, method: 'cash' } })).status, 403);
  assert.equal((await app.call('POST', '/staff/invites', { token: s.trainer })).status, 403);
});

test('код приглашения тренера одноразовый', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const inv = await app.call('POST', '/staff/invites', { token: s.admin });
  const u1 = await app.login('t3@club.ru', 'Т Три');
  const u2 = await app.login('t4@club.ru', 'Т Четыре');
  assert.equal((await app.call('POST', '/me/redeem-invite', { token: u1, body: { code: inv.data.code.toLowerCase() } })).status, 200);
  assert.equal((await app.call('POST', '/me/redeem-invite', { token: u2, body: { code: inv.data.code } })).status, 400);
});

// ---------- Админ: ручная оплата, возврат, отчёт ----------

test('ручная оплата наличными зачисляет занятия сразу', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const r = await app.call('POST', '/payments/manual', { token: s.admin, body: { childId: s.child.id, planId: s.plan.id, method: 'cash', amountRub: 3500, note: 'семейная скидка' } });
  assert.equal(r.status, 200);
  assert.equal(r.data.amount, 350000);
  assert.equal((await balanceOf(app, s.parent, s.child.id)).balance, 8);
});

test('возврат: деньги за неиспользованные занятия, остаток обнуляется', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  const { payment, providerId } = await payOnline(app, s);
  await mark(app, s.trainer, s.child.id, '2026-11-01');
  await mark(app, s.trainer, s.child.id, '2026-11-02');
  const r = await app.call('POST', `/payments/${payment.id}/refund`, { token: s.admin, body: {} });
  assert.equal(r.data.status, 'refunded');
  assert.equal(r.data.refundedAmount, 300000); // 6 из 8 занятий
  assert.equal(app.yookassa.refunds[0].paymentId, providerId);
  const card = await balanceOf(app, s.parent, s.child.id);
  assert.equal(card.balance, 0);
  // отмена старой отметки после возврата не «воскрешает» занятия
  assert.equal(card.attendance.length, 2);
});

test('отчёт для Excel: CSV с BOM и строкой платежа', async () => {
  const app = createTestApp();
  const s = await seedClub(app);
  await payOnline(app, s);
  const r = await app.call('GET', '/reports/payments.csv', { token: s.admin, query: { month: '2026-11' } });
  assert.equal(r.status, 200);
  assert.ok(r.data.startsWith('﻿Дата;Спортсмен'));
  assert.match(r.data, /Миша Петров;Анна Петрова;mama@mail\.ru;8 занятий — Миша Петров;8;4000,00;;СБП;Оплачен/);
});

test('неизвестный адрес — 404, неверный метод — 405, кривой JSON — 400', async () => {
  const app = createTestApp();
  assert.equal((await app.call('GET', '/nope')).status, 404);
  assert.equal((await app.call('DELETE', '/health')).status, 405);
  const { createRouter } = await import('../src/http/router.js');
  const res = await createRouter(app.ctx)({ method: 'POST', path: '/auth/request-code', body: '{oops' });
  assert.equal(res.status, 400);
});
