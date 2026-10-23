import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pickPackage, settleDebts, summarize } from '../src/domain/balance.js';

const pkg = (id, from, until, total, used = 0, extra = {}) => ({ id, validFrom: from, validUntil: until, lessonsTotal: total, lessonsUsed: used, createdAt: from, ...extra });

test('списывается сначала абонемент, который сгорает раньше', () => {
  const a = pkg('a', '2026-11-01', '2026-12-15', 8);
  const b = pkg('b', '2026-11-05', '2026-11-30', 8);
  assert.equal(pickPackage([a, b], '2026-11-10', '2026-11-10').id, 'b');
});

test('сгоревший абонемент не используется, пустой — тоже', () => {
  const old = pkg('old', '2026-09-01', '2026-10-15', 8, 2);
  const empty = pkg('empty', '2026-10-01', '2026-11-30', 4, 4);
  assert.equal(pickPackage([old, empty], '2026-11-10', '2026-11-10'), null);
});

test('отметка задним числом списывает абонемент, действовавший в тот день', () => {
  const nov = pkg('nov', '2026-11-01', '2026-11-30', 8);
  const dec = pkg('dec', '2026-12-01', '2026-12-31', 8);
  assert.equal(pickPackage([dec, nov], '2026-11-29', '2026-12-02').id, 'nov');
});

test('если в день занятия абонемента не было, берётся текущий (купили позже)', () => {
  const fresh = pkg('fresh', '2026-11-12', '2026-12-26', 8);
  assert.equal(pickPackage([fresh], '2026-11-10', '2026-11-12').id, 'fresh');
});

test('отозванный (возвращённый) абонемент не используется', () => {
  const r = pkg('r', '2026-11-01', '2026-12-15', 8, 2, { revoked: true });
  assert.equal(pickPackage([r], '2026-11-10', '2026-11-10'), null);
});

test('долги гасятся по порядку, пока есть занятия', () => {
  const p = pkg('p', '2026-11-12', '2026-12-26', 2);
  const debts = [
    { id: 'd3', date: '2026-11-11' },
    { id: 'd1', date: '2026-11-04' },
    { id: 'd2', date: '2026-11-06' },
  ];
  const res = settleDebts([p], debts, '2026-11-12');
  assert.deepEqual(res.map((x) => x.attendanceId), ['d1', 'd2']);
  assert.equal(p.lessonsUsed, 2);
});

test('сводка: остаток, долг, ближайшее сгорание', () => {
  const s = summarize(
    [pkg('a', '2026-11-01', '2026-11-30', 8, 3), pkg('b', '2026-11-05', '2026-12-20', 4), pkg('x', '2026-09-01', '2026-10-01', 8)],
    [{ status: 'present', packageId: null }, { status: 'cancelled', packageId: null }],
    '2026-11-10',
  );
  assert.deepEqual(s, { available: 9, debt: 1, balance: 8, nextExpiry: { date: '2026-11-30', lessons: 5 } });
});
