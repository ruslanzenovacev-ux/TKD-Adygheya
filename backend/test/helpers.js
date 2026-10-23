import { randomUUID } from 'node:crypto';
import { createMemoryRepo } from '../src/repo/memory.js';
import { createRouter } from '../src/http/router.js';
import { createConsoleMailer } from '../src/integrations/mailer.js';
import { formatAmount } from '../src/integrations/yookassa.js';

// Поддельная ЮKassa: хранит платежи в памяти, статус меняет тест.
export function createFakeYookassa() {
  const payments = new Map();
  const refunds = [];
  return {
    payments,
    refunds,
    created: 0,
    async createPayment({ amount, metadata, idempotenceKey }) {
      this.created += 1;
      const id = `2f${randomUUID().replace(/-/g, '').slice(0, 22)}`;
      payments.set(id, { id, status: 'pending', paid: false, amount: { value: formatAmount(amount), currency: 'RUB' }, metadata, idempotenceKey });
      return { id, status: 'pending', confirmationUrl: `https://yoomoney.example/checkout?orderId=${id}` };
    },
    async getPayment(id) {
      const p = payments.get(id);
      if (!p) throw new Error('not found');
      return structuredClone(p);
    },
    async createRefund(args) {
      refunds.push(args);
      return { id: randomUUID(), status: 'succeeded' };
    },
    succeed(id) {
      Object.assign(payments.get(id), { status: 'succeeded', paid: true });
    },
  };
}

export function createTestApp({ adminEmails = ['boss@club.ru'], start = '2026-11-02T09:00:00Z' } = {}) {
  let now = new Date(start);
  const mailer = createConsoleMailer();
  const yookassa = createFakeYookassa();
  const ctx = {
    config: { secret: 'test-secret-test-secret-test-secret', adminEmails, returnUrl: 'https://club.example/paid', corsOrigin: '*' },
    repo: createMemoryRepo(),
    clock: { now: () => now },
    ids: { uuid: randomUUID },
    mailer,
    yookassa,
  };
  const handle = createRouter(ctx);

  async function call(method, path, { token, body, query } = {}) {
    const res = await handle({
      method,
      path,
      query: query ?? {},
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      body: body === undefined ? '' : JSON.stringify(body),
    });
    const data = res.headers['Content-Type']?.startsWith('application/json') ? JSON.parse(res.body) : res.body;
    return { status: res.status, data, headers: res.headers };
  }

  async function login(email, name = 'Тест Тестов') {
    await call('POST', '/auth/request-code', { body: { email } });
    const code = mailer.sent.at(-1).subject.match(/\d{6}/)[0];
    const res = await call('POST', '/auth/verify', { body: { email, code, name, consent: true } });
    if (res.status !== 200) throw new Error(`login failed: ${JSON.stringify(res.data)}`);
    now = new Date(now.getTime() + 61_000); // обойти паузу перед повторной отправкой кода
    return res.data.token;
  }

  return {
    ctx,
    call,
    login,
    mailer,
    yookassa,
    advance(ms) {
      now = new Date(now.getTime() + ms);
    },
    setNow(iso) {
      now = new Date(iso);
    },
  };
}

// Типовая секция: админ, тренер с группой, второй тренер, абонемент на 8 занятий, родитель с подтверждённым ребёнком.
export async function seedClub(app) {
  const admin = await app.login('boss@club.ru', 'Руководитель');
  const trainer = await app.login('coach@club.ru', 'Тренер Иван');
  const trainer2 = await app.login('coach2@club.ru', 'Тренер Пётр');
  for (const tok of [trainer, trainer2]) {
    const inv = await app.call('POST', '/staff/invites', { token: admin });
    await app.call('POST', '/me/redeem-invite', { token: tok, body: { code: inv.data.code } });
  }
  const me = (tok) => app.call('GET', '/me', { token: tok }).then((r) => r.data);
  const coach = await me(trainer);
  const coach2 = await me(trainer2);
  const group = (await app.call('POST', '/groups', { token: admin, body: { name: 'Младшие', schedule: 'Пн, Ср 17:30', trainerId: coach.id } })).data;
  const group2 = (await app.call('POST', '/groups', { token: admin, body: { name: 'Старшие', trainerId: coach2.id } })).data;
  const plan = (await app.call('POST', '/plans', { token: admin, body: { title: '8 занятий', lessons: 8, priceRub: 4000, validDays: 45 } })).data;
  const parent = await app.login('mama@mail.ru', 'Анна Петрова');
  const child = (await app.call('POST', '/children', { token: parent, body: { name: 'Миша Петров', birthDate: '2016-05-10', groupId: group.id } })).data;
  await app.call('POST', `/children/${child.id}/approve`, { token: trainer });
  return { admin, trainer, trainer2, coach, coach2, group, group2, plan, parent, child };
}

export async function payOnline(app, { parent, child, plan }) {
  const res = await app.call('POST', '/payments', { token: parent, body: { childId: child.id, planId: plan.id } });
  if (res.status !== 200) throw new Error(JSON.stringify(res.data));
  const providerId = [...app.yookassa.payments.values()].find((p) => p.metadata.paymentId === res.data.id).id;
  app.yookassa.succeed(providerId);
  await app.call('POST', '/webhooks/yookassa', { body: { type: 'notification', event: 'payment.succeeded', object: { id: providerId } } });
  return { payment: res.data, providerId };
}

export const balanceOf = async (app, token, childId) => (await app.call('GET', `/children/${childId}`, { token })).data;
