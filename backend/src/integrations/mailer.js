// Отправка писем с кодом входа.
// В облаке — Yandex Cloud Postbox (2000 писем в месяц бесплатно), API совместим с Amazon SES v2,
// запрос подписывается AWS Signature V4 статическим ключом сервисного аккаунта.
// Локально — письма просто печатаются в консоль.

import { createHash, createHmac } from 'node:crypto';

export function createConsoleMailer() {
  const sent = [];
  return {
    sent,
    async send(msg) {
      sent.push(msg);
      console.log(`[mail] to=${msg.to} subject=${msg.subject}`);
    },
  };
}

const sha256hex = (data) => createHash('sha256').update(data).digest('hex');
const hmac = (key, data) => createHmac('sha256', key).update(data).digest();

export function createPostboxMailer({ accessKeyId, secretAccessKey, from, fetchImpl = fetch, region = 'ru-central1', host = 'postbox.cloud.yandex.net' }) {
  return {
    async send({ to, subject, text }) {
      const path = '/v2/email/outbound-emails';
      const body = JSON.stringify({
        FromEmailAddress: from,
        Destination: { ToAddresses: [to] },
        Content: { Simple: { Subject: { Data: subject, Charset: 'UTF-8' }, Body: { Text: { Data: text, Charset: 'UTF-8' } } } },
      });
      const now = new Date();
      const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, ''); // YYYYMMDDTHHMMSSZ
      const day = amzDate.slice(0, 8);
      const payloadHash = sha256hex(body);
      const canonicalHeaders = `content-type:application/json\nhost:${host}\nx-amz-content-sha256:${payloadHash}\nx-amz-date:${amzDate}\n`;
      const signedHeaders = 'content-type;host;x-amz-content-sha256;x-amz-date';
      const canonicalRequest = ['POST', path, '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
      const scope = `${day}/${region}/ses/aws4_request`;
      const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256hex(canonicalRequest)].join('\n');
      const kSigning = hmac(hmac(hmac(hmac(`AWS4${secretAccessKey}`, day), region), 'ses'), 'aws4_request');
      const signature = createHmac('sha256', kSigning).update(stringToSign).digest('hex');

      const res = await fetchImpl(`https://${host}${path}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Amz-Date': amzDate,
          'X-Amz-Content-Sha256': payloadHash,
          Authorization: `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
        },
        body,
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) {
        console.error('postbox error', res.status, await res.text().catch(() => ''));
        throw new Error('Не удалось отправить письмо');
      }
    },
  };
}
