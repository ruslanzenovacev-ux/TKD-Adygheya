// Клиент API ЮKassa v3 (https://yookassa.ru/developers/api). Без SDK — обычный fetch.
// Ключ магазина живёт только на сервере (переменные окружения функции), в приложение не попадает.

import { upstream } from '../domain/errors.js';

const API = 'https://api.yookassa.ru/v3';

export const formatAmount = (kopecks) => (kopecks / 100).toFixed(2);

export function createYookassa({ shopId, secretKey, fetchImpl = fetch, receipt = null, allowCards = false }) {
  const auth = 'Basic ' + Buffer.from(`${shopId}:${secretKey}`).toString('base64');

  async function call(method, path, body, idempotenceKey) {
    const headers = { Authorization: auth, 'Content-Type': 'application/json' };
    if (idempotenceKey) headers['Idempotence-Key'] = idempotenceKey;
    let res;
    try {
      res = await fetchImpl(`${API}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15000) });
    } catch (e) {
      throw upstream('Платёжная система не отвечает, попробуйте ещё раз');
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      console.error('yookassa error', res.status, data?.code, data?.description);
      throw upstream('Платёжная система вернула ошибку, попробуйте позже');
    }
    return data;
  }

  // Чек (54-ФЗ): одна позиция «услуга», полная предоплата. vat_code 1 = «без НДС».
  function receiptFor({ email, description, amount }) {
    if (!receipt) return undefined;
    const r = {
      customer: { email },
      items: [
        {
          description: description.slice(0, 128),
          quantity: '1.00',
          amount: { value: formatAmount(amount), currency: 'RUB' },
          vat_code: receipt.vatCode,
          payment_mode: 'full_prepayment',
          payment_subject: 'service',
        },
      ],
    };
    if (receipt.taxSystemCode) r.tax_system_code = receipt.taxSystemCode;
    return r;
  }

  return {
    async createPayment({ amount, description, returnUrl, metadata, email, idempotenceKey }) {
      const body = {
        amount: { value: formatAmount(amount), currency: 'RUB' },
        capture: true,
        confirmation: { type: 'redirect', return_url: returnUrl },
        description: description.slice(0, 128),
        metadata,
        receipt: receiptFor({ email, description, amount }),
      };
      // По умолчанию — только СБП (самая низкая комиссия). Если включить карты, ЮKassa покажет выбор способа.
      if (!allowCards) body.payment_method_data = { type: 'sbp' };
      const p = await call('POST', '/payments', body, idempotenceKey);
      return { id: p.id, status: p.status, confirmationUrl: p.confirmation?.confirmation_url ?? null };
    },

    async getPayment(id) {
      if (!/^[0-9a-f-]{20,64}$/i.test(String(id))) throw upstream('Некорректный id платежа');
      return call('GET', `/payments/${encodeURIComponent(id)}`);
    },

    async createRefund({ paymentId, amount, description, email, idempotenceKey }) {
      const body = {
        payment_id: paymentId,
        amount: { value: formatAmount(amount), currency: 'RUB' },
        description: description?.slice(0, 250),
        receipt: receiptFor({ email, description: description ?? 'Возврат за абонемент', amount }),
      };
      const r = await call('POST', '/refunds', body, idempotenceKey);
      return { id: r.id, status: r.status };
    },
  };
}
