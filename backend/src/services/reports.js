// Выгрузка для бухгалтерии: CSV, который Excel открывает «как есть» (UTF-8 с BOM, разделитель «;»).

import { forbidden, badRequest } from '../domain/errors.js';
import { isAdmin } from './common.js';

const STATUS = { succeeded: 'Оплачен', refunded: 'Возврат', pending: 'Ожидает', canceled: 'Отменён', review: 'Проверить' };
const METHOD = { sbp: 'СБП', cash: 'Наличные', transfer: 'Перевод' };

const cell = (v) => {
  const s = v === null || v === undefined ? '' : String(v);
  // Защита от формул в Excel и экранирование кавычек.
  const safe = /^[=+\-@]/.test(s) ? `'${s}` : s;
  return /[;"\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
};
const rub = (kopecks) => (kopecks / 100).toFixed(2).replace('.', ',');

export async function paymentsCsv(ctx, admin, { month }) {
  if (!isAdmin(admin)) throw forbidden();
  if (!/^\d{4}-\d{2}$/.test(String(month ?? ''))) throw badRequest('Укажите месяц в формате ГГГГ-ММ');
  const { payments, children, users } = await ctx.repo.tx(async (t) => ({
    payments: await t.find('payments', 'month', month),
    children: await t.find('children'),
    users: await t.find('users'),
  }));
  const childById = new Map(children.map((c) => [c.id, c]));
  const userById = new Map(users.map((u) => [u.id, u]));
  const header = ['Дата', 'Спортсмен', 'Родитель', 'Почта', 'Абонемент', 'Занятий', 'Сумма, ₽', 'Возврат, ₽', 'Способ', 'Статус', 'ID ЮKassa'];
  const lines = [header.map(cell).join(';')];
  for (const p of payments.filter((x) => x.status !== 'failed').sort((a, b) => a.createdAt.localeCompare(b.createdAt))) {
    const child = childById.get(p.childId);
    const parent = userById.get(p.parentId);
    lines.push(
      [
        new Date(p.paidAt ?? p.createdAt).toLocaleString('ru-RU', { timeZone: 'Europe/Moscow' }),
        child?.name,
        parent?.name,
        parent?.email,
        p.title,
        p.lessons,
        rub(p.amount),
        p.refundedAmount ? rub(p.refundedAmount) : '',
        METHOD[p.method] ?? p.method,
        STATUS[p.status] ?? p.status,
        p.providerId,
      ]
        .map(cell)
        .join(';'),
    );
  }
  return '﻿' + lines.join('\r\n') + '\r\n';
}
