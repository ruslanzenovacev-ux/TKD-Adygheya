// Точка входа облачной функции Yandex Cloud (Node.js 22).
// Функция вызывается через API Gateway с одним маршрутом /{path+} — см. deploy/api-gateway.yaml.

import { randomUUID } from 'node:crypto';
import { loadConfig } from './config.js';
import { createRouter } from './http/router.js';
import { createYdbRepo } from './repo/ydb.js';
import { createYookassa } from './integrations/yookassa.js';
import { createConsoleMailer, createPostboxMailer } from './integrations/mailer.js';

let routerPromise = null;

async function init() {
  const config = loadConfig();
  const ctx = {
    config,
    repo: await createYdbRepo(),
    clock: { now: () => new Date() },
    ids: { uuid: randomUUID },
    mailer: config.postbox ? createPostboxMailer(config.postbox) : createConsoleMailer(),
    yookassa: config.yookassa ? createYookassa(config.yookassa) : null,
  };
  return createRouter(ctx);
}

// Путь берём из API Gateway (event.path / event.params.path), запасной вариант — event.url.
function pathOf(event) {
  if (event.params?.path !== undefined) return '/' + String(event.params.path).replace(/^\/+/, '');
  if (event.path) return event.path;
  if (event.url) return new URL(event.url, 'http://x').pathname;
  return '/';
}

export async function handler(event) {
  routerPromise ??= init().catch((e) => {
    routerPromise = null;
    throw e;
  });
  const handle = await routerPromise;
  const body = event.body ? (event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body) : '';
  const res = await handle({
    method: event.httpMethod,
    path: pathOf(event),
    query: event.queryStringParameters ?? {},
    headers: event.headers ?? {},
    body,
  });
  return { statusCode: res.status, headers: res.headers, body: res.body, isBase64Encoded: false };
}
