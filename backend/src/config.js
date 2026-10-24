// Настройки из переменных окружения облачной функции.

export function loadConfig(env = process.env) {
  const required = (name) => {
    const v = env[name];
    if (!v) throw new Error(`Не задана переменная окружения ${name}`);
    return v;
  };
  return {
    // Случайная строка ≥ 32 символов: «соль» для кодов входа. Сгенерировать: openssl rand -hex 32
    secret: required('APP_SECRET'),
    // Почта руководителя секции: при первом входе получает роль администратора. Несколько — через «;».
    adminEmails: (env.ADMIN_EMAILS ?? '').split(/[,;\s]+/).map((s) => s.trim().toLowerCase()).filter(Boolean),
    // Куда ЮKassa вернёт родителя после оплаты (страница, которая открывает приложение).
    returnUrl: env.RETURN_URL ?? 'https://example.ru/paid',
    corsOrigin: env.CORS_ORIGIN ?? '*',
    yookassa: env.YOOKASSA_SHOP_ID
      ? {
          shopId: env.YOOKASSA_SHOP_ID,
          secretKey: required('YOOKASSA_SECRET_KEY'),
          allowCards: env.YOOKASSA_ALLOW_CARDS === '1',
          // Чеки 54-ФЗ через ЮKassa. RECEIPT_VAT_CODE: 1 = без НДС. TAX_SYSTEM_CODE — если у магазина несколько СНО.
          receipt: env.RECEIPTS_ENABLED === '1' ? { vatCode: Number(env.RECEIPT_VAT_CODE ?? 1), taxSystemCode: env.TAX_SYSTEM_CODE ? Number(env.TAX_SYSTEM_CODE) : null } : null,
        }
      : null,
    postbox: env.POSTBOX_ACCESS_KEY_ID
      ? { accessKeyId: env.POSTBOX_ACCESS_KEY_ID, secretAccessKey: required('POSTBOX_SECRET_ACCESS_KEY'), from: required('MAIL_FROM') }
      : null,
  };
}
