// HTTP API. Один обработчик на все маршруты: так нужна одна облачная функция и один маршрут в API Gateway.
// Запрос: { method, path, query, headers, body(string) } → ответ: { status, headers, body(string) }.

import { AppError, badRequest, notFound } from '../domain/errors.js';
import * as auth from '../services/auth.js';
import * as catalog from '../services/catalog.js';
import * as children from '../services/children.js';
import * as attendance from '../services/attendance.js';
import * as payments from '../services/payments.js';
import * as reports from '../services/reports.js';
import { publicUser } from '../services/common.js';

const MAX_BODY = 256 * 1024;

// [метод, шаблон пути, нужна ли авторизация, обработчик(ctx, req, user, params)]
const routes = [
  ['GET', '/health', false, () => ({ ok: true })],

  // Вход и профиль
  ['POST', '/auth/request-code', false, (ctx, r) => auth.requestCode(ctx, r.json)],
  ['POST', '/auth/verify', false, (ctx, r) => auth.verifyCode(ctx, r.json)],
  ['POST', '/auth/logout', true, (ctx, r) => auth.logout(ctx, r.token)],
  ['GET', '/me', true, (ctx, r, u) => publicUser(u)],
  ['PATCH', '/me', true, (ctx, r, u) => auth.updateProfile(ctx, u, r.json)],
  ['POST', '/me/redeem-invite', true, (ctx, r, u) => auth.redeemInvite(ctx, u, r.json)],

  // Персонал (админ)
  ['GET', '/staff', true, (ctx, r, u) => auth.listStaff(ctx, u)],
  ['POST', '/staff/invites', true, (ctx, r, u) => auth.createTrainerInvite(ctx, u)],
  ['POST', '/staff/:id/trainer', true, (ctx, r, u, p) => auth.setTrainerRole(ctx, u, p.id, Boolean(r.json.enabled))],

  // Абонементы и группы
  ['GET', '/plans', true, (ctx, r, u) => catalog.listPlans(ctx, u)],
  ['POST', '/plans', true, (ctx, r, u) => catalog.createPlan(ctx, u, r.json)],
  ['PATCH', '/plans/:id', true, (ctx, r, u, p) => catalog.updatePlan(ctx, u, p.id, r.json)],
  ['GET', '/groups', true, (ctx, r, u) => catalog.listGroups(ctx, u, { mine: r.query.mine === '1' })],
  ['POST', '/groups', true, (ctx, r, u) => catalog.createGroup(ctx, u, r.json)],
  ['PATCH', '/groups/:id', true, (ctx, r, u, p) => catalog.updateGroup(ctx, u, p.id, r.json)],
  ['GET', '/groups/:id/roster', true, (ctx, r, u, p) => attendance.roster(ctx, u, p.id, { date: r.query.date })],

  // Спортсмены
  ['GET', '/children', true, (ctx, r, u) => children.listChildren(ctx, u, { groupId: r.query.groupId, status: r.query.status })],
  ['POST', '/children', true, (ctx, r, u) => children.addChild(ctx, u, r.json)],
  ['GET', '/children/:id', true, (ctx, r, u, p) => children.getChild(ctx, u, p.id)],
  ['PATCH', '/children/:id', true, (ctx, r, u, p) => children.updateChild(ctx, u, p.id, r.json)],
  ['POST', '/children/:id/approve', true, (ctx, r, u, p) => children.approveChild(ctx, u, p.id)],

  // Посещения
  ['POST', '/attendance/batch', true, (ctx, r, u) => attendance.markBatch(ctx, u, r.json)],
  ['POST', '/attendance/:id/cancel', true, (ctx, r, u, p) => attendance.cancelMark(ctx, u, p.id)],

  // Оплаты
  ['POST', '/payments', true, (ctx, r, u) => payments.createOnlinePayment(ctx, u, r.json)],
  ['GET', '/payments', true, (ctx, r, u) => payments.listPayments(ctx, u, { month: r.query.month })],
  ['POST', '/payments/manual', true, (ctx, r, u) => payments.addManualPayment(ctx, u, r.json)],
  ['GET', '/payments/:id', true, (ctx, r, u, p) => payments.getPayment(ctx, u, p.id)],
  ['POST', '/payments/:id/refund', true, (ctx, r, u, p) => payments.refundPayment(ctx, u, p.id, r.json)],
  ['POST', '/webhooks/yookassa', false, (ctx, r) => payments.handleYookassaWebhook(ctx, r.json)],

  // Отчёты
  [
    'GET',
    '/reports/payments.csv',
    true,
    async (ctx, r, u) => ({
      __raw: true,
      contentType: 'text/csv; charset=utf-8',
      filename: `payments-${r.query.month}.csv`,
      body: await reports.paymentsCsv(ctx, u, { month: r.query.month }),
    }),
  ],
].map(([method, pattern, needsAuth, handler]) => {
  const names = [];
  const re = new RegExp('^' + pattern.replace(/:(\w+)/g, (_, n) => (names.push(n), '([^/]+)')).replace(/\./g, '\\.') + '/?$');
  return { method, re, names, needsAuth, handler };
});

function match(method, path) {
  let pathMatched = false;
  for (const r of routes) {
    const m = r.re.exec(path);
    if (!m) continue;
    pathMatched = true;
    if (r.method !== method) continue;
    const params = Object.fromEntries(r.names.map((n, i) => [n, decodeURIComponent(m[i + 1])]));
    return { route: r, params };
  }
  return { route: null, pathMatched };
}

export function createRouter(ctx) {
  const cors = {
    'Access-Control-Allow-Origin': ctx.config.corsOrigin,
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS',
    'Access-Control-Max-Age': '86400',
  };
  const json = (status, data) => ({ status, headers: { ...cors, 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify(data) });

  return async function handle({ method, path, query = {}, headers = {}, body = '' }) {
    method = String(method || 'GET').toUpperCase();
    if (method === 'OPTIONS') return { status: 204, headers: cors, body: '' };
    try {
      const { route, params, pathMatched } = match(method, path || '/');
      if (!route) throw pathMatched ? new AppError(405, 'method_not_allowed', 'Метод не поддерживается') : notFound('Нет такого адреса');

      if (body && body.length > MAX_BODY) throw badRequest('Слишком большой запрос');
      let parsed = {};
      if (body) {
        try {
          parsed = JSON.parse(body);
        } catch {
          throw badRequest('Некорректный JSON');
        }
      }
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw badRequest('Ожидается JSON-объект');

      const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
      const token = /^Bearer\s+(.+)$/i.exec(h.authorization ?? '')?.[1]?.trim();
      const req = { json: parsed, query, token };
      const user = route.needsAuth ? await auth.authenticate(ctx, token) : null;

      const result = await route.handler(ctx, req, user, params);
      if (result?.__raw) {
        return {
          status: 200,
          headers: { ...cors, 'Content-Type': result.contentType, 'Content-Disposition': `attachment; filename="${result.filename}"` },
          body: result.body,
        };
      }
      return json(200, result ?? { ok: true });
    } catch (e) {
      if (e instanceof AppError) return json(e.status, { error: { code: e.code, message: e.message } });
      console.error('unhandled error', method, path, e);
      return json(500, { error: { code: 'internal', message: 'Ошибка сервера, попробуйте позже' } });
    }
  };
}
