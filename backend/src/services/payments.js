// Оплата абонементов.
//
// Онлайн (СБП через ЮKassa):
//   1. Родитель выбирает ребёнка и абонемент. Сумму берём из таблицы абонементов на сервере — клиент её не передаёт.
//   2. Создаём платёж у себя (pending) и в ЮKassa, отдаём ссылку на оплату.
//   3. ЮKassa присылает уведомление. Мы НЕ доверяем телу уведомления: по id запрашиваем платёж в ЮKassa
//      своими ключами и проверяем статус, сумму и наш paymentId в metadata.
//   4. В одной транзакции: платёж → succeeded, создаём пакет занятий, гасим долг. Повтор уведомления ничего не меняет.
//   Если уведомление потерялось, приложение при открытии платежа само спросит статус у ЮKassa.
//
// Вручную (наличные / перевод): админ вносит оплату, пакет создаётся сразу.

import { badRequest, conflict, forbidden, notFound } from '../domain/errors.js';
import { remainingOf } from '../domain/balance.js';
import { addDays, monthOf } from '../domain/time.js';
import { formatAmount } from '../integrations/yookassa.js';
import { isAdmin, loadChild, nowIso, rebalance, today } from './common.js';
import { CHILD_STATUS } from './children.js';

const REUSE_PENDING_MS = 15 * 60 * 1000;
const POLL_AFTER_MS = 5 * 1000;

const paymentView = (p) => ({
  id: p.id,
  childId: p.childId,
  title: p.title,
  amount: p.amount,
  lessons: p.lessons,
  status: p.status,
  method: p.method,
  createdAt: p.createdAt,
  paidAt: p.paidAt ?? null,
  confirmationUrl: p.status === 'pending' ? (p.confirmationUrl ?? null) : null,
  refundedAmount: p.refundedAmount ?? 0,
});

export async function createOnlinePayment(ctx, user, { childId, planId }) {
  if (!ctx.yookassa) throw conflict('Онлайн-оплата ещё не подключена');
  const nowMs = ctx.clock.now().getTime();

  const prepared = await ctx.repo.tx(async (t) => {
    const child = await loadChild(t, childId);
    if (child.parentId !== user.id) throw notFound('Спортсмен не найден');
    if (child.status !== CHILD_STATUS.active) throw conflict('Оплата станет доступна после подтверждения тренером');
    const plan = planId ? await t.get('plans', String(planId)) : null;
    if (!plan || !plan.active) throw badRequest('Выберите абонемент');

    // Повторное нажатие «Оплатить» не создаёт второй платёж — возвращаем незавершённый.
    const recent = (await t.find('payments', 'childId', child.id)).find(
      (p) => p.status === 'pending' && p.planId === plan.id && p.parentId === user.id && p.confirmationUrl && nowMs - Date.parse(p.createdAt) < REUSE_PENDING_MS,
    );
    if (recent) return { payment: recent, reused: true };

    const payment = {
      id: ctx.ids.uuid(),
      childId: child.id,
      parentId: user.id,
      planId: plan.id,
      title: `${plan.title} — ${child.name}`,
      amount: plan.price,
      lessons: plan.lessons,
      validDays: plan.validDays,
      method: 'sbp',
      provider: 'yookassa',
      providerId: null,
      status: 'pending',
      createdAt: nowIso(ctx),
      month: monthOf(nowIso(ctx)),
    };
    await t.put('payments', payment);
    return { payment, reused: false };
  });
  if (prepared.reused) return paymentView(prepared.payment);

  const payment = prepared.payment;
  let remote;
  try {
    remote = await ctx.yookassa.createPayment({
      amount: payment.amount,
      description: `Абонемент: ${payment.title}`,
      returnUrl: `${ctx.config.returnUrl}?payment=${payment.id}`,
      metadata: { paymentId: payment.id },
      email: user.email,
      idempotenceKey: payment.id,
    });
  } catch (e) {
    await ctx.repo.tx(async (t) => {
      const p = await t.get('payments', payment.id);
      p.status = 'failed';
      await t.put('payments', p);
    });
    throw e;
  }

  return ctx.repo.tx(async (t) => {
    const p = await t.get('payments', payment.id);
    p.providerId = remote.id;
    p.confirmationUrl = remote.confirmationUrl;
    await t.put('payments', p);
    return paymentView(p);
  });
}

// Применить статус платежа из ЮKassa к нашему платежу. Идемпотентно.
async function applyRemote(ctx, paymentId, remote) {
  return ctx.repo.tx(async (t) => {
    const p = await t.get('payments', paymentId);
    if (!p) return null;
    if (p.status !== 'pending') return p;
    if (remote.id !== p.providerId && remote.metadata?.paymentId !== p.id) return p;

    if (remote.status === 'succeeded' && remote.paid !== false) {
      const amountOk = remote.amount?.currency === 'RUB' && remote.amount?.value === formatAmount(p.amount);
      if (!amountOk || remote.metadata?.paymentId !== p.id) {
        // Не зачисляем автоматически — пусть посмотрит админ.
        p.status = 'review';
        p.reviewReason = `amount=${remote.amount?.value} ${remote.amount?.currency}, metadata=${remote.metadata?.paymentId}`;
        console.error('payment needs review', p.id, p.reviewReason);
        await t.put('payments', p);
        return p;
      }
      p.providerId = remote.id;
      await creditPackage(t, ctx, p);
      return p;
    }
    if (remote.status === 'canceled') {
      p.status = 'canceled';
      p.cancelReason = remote.cancellation_details?.reason ?? null;
      await t.put('payments', p);
    }
    return p;
  });
}

// Внутри транзакции: отметить платёж оплаченным и создать пакет занятий.
async function creditPackage(t, ctx, p) {
  const date = today(ctx);
  const pkg = {
    id: ctx.ids.uuid(),
    childId: p.childId,
    paymentId: p.id,
    title: p.title,
    lessonsTotal: p.lessons,
    lessonsUsed: 0,
    validFrom: date,
    validUntil: addDays(date, p.validDays - 1),
    source: p.provider === 'manual' ? 'manual' : 'online',
    createdAt: nowIso(ctx),
  };
  await t.put('packages', pkg);
  p.status = 'succeeded';
  p.paidAt = nowIso(ctx);
  p.packageId = pkg.id;
  await t.put('payments', p);
  await rebalance(t, ctx, p.childId);
}

// Уведомление от ЮKassa (без авторизации). Тело используем только как подсказку, какой платёж проверить.
export async function handleYookassaWebhook(ctx, body) {
  if (!ctx.yookassa) return { ok: true };
  const remoteId = body?.object?.id;
  if (typeof remoteId !== 'string' || !body?.event?.startsWith('payment.')) return { ok: true };

  const remote = await ctx.yookassa.getPayment(remoteId);
  let paymentId = remote.metadata?.paymentId;
  if (!paymentId) {
    const [found] = await ctx.repo.tx((t) => t.find('payments', 'providerId', remoteId));
    paymentId = found?.id;
  }
  if (!paymentId) return { ok: true };
  await applyRemote(ctx, paymentId, remote);
  return { ok: true };
}

export async function getPayment(ctx, user, paymentId) {
  let p = await ctx.repo.tx((t) => t.get('payments', String(paymentId)));
  if (!p || (p.parentId !== user.id && !isAdmin(user))) throw notFound('Платёж не найден');
  // Если уведомление ещё не пришло — спросим ЮKassa сами (родитель вернулся из банка и ждёт).
  const age = ctx.clock.now().getTime() - Date.parse(p.createdAt);
  if (p.status === 'pending' && p.providerId && ctx.yookassa && age > POLL_AFTER_MS) {
    const remote = await ctx.yookassa.getPayment(p.providerId);
    p = (await applyRemote(ctx, p.id, remote)) ?? p;
  }
  return paymentView(p);
}

export async function listPayments(ctx, admin, { month }) {
  if (!isAdmin(admin)) throw forbidden();
  if (!/^\d{4}-\d{2}$/.test(String(month ?? ''))) throw badRequest('Укажите месяц в формате ГГГГ-ММ');
  const rows = await ctx.repo.tx((t) => t.find('payments', 'month', month));
  return rows.filter((p) => p.status !== 'failed').sort((a, b) => a.createdAt.localeCompare(b.createdAt)).map(paymentView);
}

// Оплата наличными или переводом. Для наличных ИП должен пробить чек на своей кассе — это вне приложения.
export async function addManualPayment(ctx, admin, body) {
  if (!isAdmin(admin)) throw forbidden();
  const method = body.method;
  if (!['cash', 'transfer'].includes(method)) throw badRequest('Способ: наличные или перевод');
  return ctx.repo.tx(async (t) => {
    const child = await loadChild(t, body.childId);
    if (child.status === CHILD_STATUS.archived) throw conflict('Спортсмен в архиве');
    let lessons;
    let validDays;
    let amount;
    let title;
    if (body.planId) {
      const plan = await t.get('plans', String(body.planId));
      if (!plan) throw badRequest('Абонемент не найден');
      ({ lessons, validDays } = plan);
      amount = body.amountRub !== undefined ? Math.round(Number(body.amountRub) * 100) : plan.price;
      title = `${plan.title} — ${child.name}`;
    } else {
      lessons = Number(body.lessons);
      validDays = Number(body.validDays);
      amount = Math.round(Number(body.amountRub) * 100);
      title = `${lessons} зан. — ${child.name}`;
    }
    if (!Number.isInteger(lessons) || lessons < 1 || lessons > 200) throw badRequest('Проверьте количество занятий');
    if (!Number.isInteger(validDays) || validDays < 1 || validDays > 366) throw badRequest('Проверьте срок действия');
    if (!Number.isFinite(amount) || amount < 0) throw badRequest('Проверьте сумму');

    const p = {
      id: ctx.ids.uuid(),
      childId: child.id,
      parentId: child.parentId,
      planId: body.planId ?? null,
      title,
      amount,
      lessons,
      validDays,
      method,
      provider: 'manual',
      providerId: null,
      status: 'pending',
      note: body.note ? String(body.note).slice(0, 300) : null,
      createdBy: admin.id,
      createdAt: nowIso(ctx),
      month: monthOf(nowIso(ctx)),
    };
    // Оплата от админа заодно подтверждает ребёнка (родитель пришёл и заплатил в зале).
    if (child.status === CHILD_STATUS.pending) {
      child.status = CHILD_STATUS.active;
      child.approvedBy = admin.id;
      child.approvedAt = nowIso(ctx);
      await t.put('children', child);
    }
    await creditPackage(t, ctx, p);
    return paymentView(p);
  });
}

// Возврат: неиспользованные занятия списываются, деньги (онлайн) возвращаются через ЮKassa.
// Сумма по умолчанию — пропорционально неиспользованным занятиям; админ может указать свою.
export async function refundPayment(ctx, admin, paymentId, body = {}) {
  if (!isAdmin(admin)) throw forbidden();
  const { p, pkg, parent } = await ctx.repo.tx(async (t) => {
    const p = await t.get('payments', String(paymentId));
    if (!p) throw notFound('Платёж не найден');
    if (p.status !== 'succeeded') throw conflict('Вернуть можно только оплаченный платёж');
    const pkg = p.packageId ? await t.get('packages', p.packageId) : null;
    const parent = await t.get('users', p.parentId);
    return { p, pkg, parent };
  });

  const unused = pkg ? remainingOf(pkg) : 0;
  const amount = body.amountRub !== undefined ? Math.round(Number(body.amountRub) * 100) : Math.floor((p.amount * unused) / p.lessons);
  if (!Number.isInteger(amount) || amount < 0 || amount > p.amount) throw badRequest('Проверьте сумму возврата');

  if (p.provider === 'yookassa' && amount > 0) {
    await ctx.yookassa.createRefund({
      paymentId: p.providerId,
      amount,
      description: `Возврат: ${p.title}`,
      email: parent?.email,
      idempotenceKey: `refund-${p.id}`,
    });
  }

  return ctx.repo.tx(async (t) => {
    const cur = await t.get('payments', p.id);
    if (cur.status !== 'succeeded') return paymentView(cur);
    if (cur.packageId) {
      const k = await t.get('packages', cur.packageId);
      k.lessonsTotal = k.lessonsUsed; // неиспользованные занятия сгорают
      k.revoked = true;
      await t.put('packages', k);
    }
    cur.status = 'refunded';
    cur.refundedAmount = amount;
    cur.refundedAt = nowIso(ctx);
    cur.refundedBy = admin.id;
    await t.put('payments', cur);
    await rebalance(t, ctx, cur.childId);
    return paymentView(cur);
  });
}
