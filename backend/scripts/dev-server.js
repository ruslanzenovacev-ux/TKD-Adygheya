// Локальный сервер для разработки приложения: данные в памяти, письма в консоль,
// вместо ЮKassa — тестовая страница «Оплатить», которая имитирует успешную оплату.
// Запуск: npm run dev   (порт 8787, демо-данные создаются автоматически)
//
// Демо-входы (код входа печатается в консоли):
//   boss@demo.ru  — администратор
//   coach@demo.ru — тренер группы «Младшие»
//   mama@demo.ru  — родитель (ребёнок подтверждён, абонемент не куплен)

import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { createMemoryRepo } from '../src/repo/memory.js';
import { createRouter } from '../src/http/router.js';
import { createConsoleMailer } from '../src/integrations/mailer.js';
import { formatAmount } from '../src/integrations/yookassa.js';
import { ROLES } from '../src/services/common.js';

const PORT = Number(process.env.PORT ?? 8787);
const BASE = `http://localhost:${PORT}`;

const fakePayments = new Map();
const fakeYookassa = {
  async createPayment({ amount, metadata, returnUrl }) {
    const id = `2f${randomUUID().replace(/-/g, '').slice(0, 22)}`;
    fakePayments.set(id, { id, status: 'pending', paid: false, amount: { value: formatAmount(amount), currency: 'RUB' }, metadata, returnUrl });
    return { id, status: 'pending', confirmationUrl: `${BASE}/dev/pay/${id}` };
  },
  async getPayment(id) {
    return structuredClone(fakePayments.get(id));
  },
  async createRefund() {
    return { id: randomUUID(), status: 'succeeded' };
  },
};

const mailer = createConsoleMailer();
const origSend = mailer.send;
mailer.send = async (msg) => {
  await origSend(msg);
  console.log(`      >>> ${msg.subject}`);
};

const ctx = {
  config: { secret: 'dev-secret', adminEmails: ['boss@demo.ru'], returnUrl: `${BASE}/dev/paid`, corsOrigin: '*' },
  repo: createMemoryRepo(),
  clock: { now: () => new Date() },
  ids: { uuid: randomUUID },
  mailer,
  yookassa: fakeYookassa,
};
const handle = createRouter(ctx);

async function seed() {
  const now = new Date().toISOString();
  const users = [
    { id: randomUUID(), email: 'boss@demo.ru', name: 'Руководитель Секции', roles: [ROLES.parent, ROLES.admin] },
    { id: randomUUID(), email: 'coach@demo.ru', name: 'Иван Тренеров', roles: [ROLES.parent, ROLES.trainer] },
    { id: randomUUID(), email: 'mama@demo.ru', name: 'Анна Петрова', roles: [ROLES.parent] },
  ];
  const [, coach, mama] = users;
  const group = { id: randomUUID(), name: 'Младшие', schedule: 'Пн, Ср, Пт 17:30', place: 'Зал на Ленина', trainerId: coach.id, active: true, createdAt: now };
  const plans = [
    { id: randomUUID(), title: '8 занятий', lessons: 8, price: 400000, validDays: 45, active: true, createdAt: now },
    { id: randomUUID(), title: '12 занятий', lessons: 12, price: 540000, validDays: 60, active: true, createdAt: now },
  ];
  const kids = ['Миша Петров', 'Алиса Смирнова', 'Тимур Ахметов', 'Соня Иванова'].map((name, i) => ({
    id: randomUUID(),
    parentId: i === 0 ? mama.id : coach.id,
    name,
    groupId: group.id,
    status: 'active',
    ledger: { pkgs: [], debt: 0 },
    createdAt: now,
  }));
  await ctx.repo.tx(async (t) => {
    for (const u of users) await t.put('users', { ...u, consentAt: now, createdAt: now });
    await t.put('groups', group);
    for (const p of plans) await t.put('plans', p);
    for (const k of kids) await t.put('children', k);
  });
}

const page = (title, body) =>
  `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>` +
  `<body style="font-family:system-ui;max-width:420px;margin:40px auto;padding:0 16px">${body}</body>`;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, BASE);
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks).toString('utf8');

  // Тестовая «страница банка»
  const payMatch = url.pathname.match(/^\/dev\/pay\/([\w-]+)$/);
  if (payMatch) {
    const p = fakePayments.get(payMatch[1]);
    if (!p) return res.writeHead(404).end('нет платежа');
    if (req.method === 'POST') {
      p.status = 'succeeded';
      p.paid = true;
      await handle({ method: 'POST', path: '/webhooks/yookassa', body: JSON.stringify({ event: 'payment.succeeded', object: { id: p.id } }) });
      res.writeHead(303, { Location: p.returnUrl }).end();
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(page('Оплата', `<h2>Тестовая оплата СБП</h2><p>Сумма: <b>${p.amount.value} ₽</b></p><form method="post"><button style="font-size:18px;padding:12px 24px">Оплатить</button></form>`));
  }
  if (url.pathname === '/dev/paid') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(page('Оплачено', '<h2>Оплата прошла ✅</h2><p>Вернитесь в приложение.</p>'));
  }

  const out = await handle({ method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), headers: req.headers, body });
  res.writeHead(out.status, out.headers);
  res.end(out.body);
});

await seed();
server.listen(PORT, () => {
  console.log(`API: ${BASE}`);
  console.log('Демо-входы: boss@demo.ru (админ), coach@demo.ru (тренер), mama@demo.ru (родитель). Код входа появится здесь.');
});
