// Хранилище в Yandex Database (serverless). Тот же интерфейс, что и memory.js: tx(fn), где fn получает
// get / find / put / del. Чтения идут в YDB внутри транзакции, записи копятся и отправляются одним
// запросом вместе с коммитом (YDB не разрешает читать таблицу после записи в неё в той же транзакции).
// При конфликте YDB транзакция повторяется целиком, поэтому fn не должна делать внешних вызовов.
//
// ВАЖНО: этот модуль нельзя проверить без облака — он проверяется при первом развёртывании
// (scripts/smoke-ydb.js). Вся бизнес-логика тестируется на memory.js.

import { Driver, getCredentialsFromEnv, TypedData, TypedValues, Types } from 'ydb-sdk';
import { TABLES, assertField, assertTable } from './tables.js';

const SERIALIZABLE = { serializableReadWrite: {} };

function rowsToDocs(result) {
  const rs = result?.resultSets?.[0];
  if (!rs) return [];
  return TypedData.createNativeObjects(rs).map((row) => JSON.parse(row.doc));
}

const utf8Opt = (v) => (v === undefined || v === null ? TypedValues.optionalNull(Types.UTF8) : TypedValues.optional(TypedValues.utf8(String(v))));

function upsertStatement(table, doc, n) {
  const fields = TABLES[table];
  const declares = [`DECLARE $id${n} AS Utf8;`, `DECLARE $doc${n} AS Json;`, ...fields.map((f) => `DECLARE $${f}${n} AS Utf8?;`)];
  const cols = ['id', 'doc', ...fields].join(', ');
  const vals = [`$id${n}`, `$doc${n}`, ...fields.map((f) => `$${f}${n}`)].join(', ');
  const params = {
    [`$id${n}`]: TypedValues.utf8(doc.id),
    [`$doc${n}`]: TypedValues.json(JSON.stringify(doc)),
  };
  for (const f of fields) params[`$${f}${n}`] = utf8Opt(doc[f]);
  return { declares, sql: `UPSERT INTO \`${table}\` (${cols}) VALUES (${vals});`, params };
}

function deleteStatement(table, id, n) {
  return {
    declares: [`DECLARE $del${n} AS Utf8;`],
    sql: `DELETE FROM \`${table}\` WHERE id = $del${n};`,
    params: { [`$del${n}`]: TypedValues.utf8(id) },
  };
}

export async function createYdbRepo({ endpoint = process.env.YDB_ENDPOINT, database = process.env.YDB_DATABASE } = {}) {
  const driver = new Driver({ endpoint, database, authService: getCredentialsFromEnv() });
  if (!(await driver.ready(10000))) throw new Error('YDB driver is not ready');

  async function tx(fn) {
    return driver.tableClient.withSessionRetry(async (session) => {
      let txId = null;
      const staged = new Map();
      const stagedFor = (table) => {
        if (!staged.has(table)) staged.set(table, new Map());
        return staged.get(table);
      };

      async function read(query, params) {
        const control = txId ? { txId } : { beginTx: SERIALIZABLE, commitTx: false };
        const result = await session.executeQuery(query, params, control);
        if (!txId) txId = result.txMeta?.id ?? null;
        return result;
      }

      const t = {
        async get(table, id) {
          assertTable(table);
          const s = staged.get(table);
          if (s?.has(id)) return structuredClone(s.get(id));
          const res = await read(`DECLARE $id AS Utf8; SELECT doc FROM \`${table}\` WHERE id = $id;`, { $id: TypedValues.utf8(id) });
          return rowsToDocs(res)[0] ?? null;
        },
        async find(table, field, value) {
          assertField(table, field);
          const res =
            field === undefined
              ? await read(`SELECT doc FROM \`${table}\`;`, {})
              : await read(
                  `DECLARE $v AS Utf8; SELECT doc FROM \`${table}\` VIEW idx_${field} WHERE ${field} = $v;`,
                  { $v: TypedValues.utf8(String(value)) },
                );
          const merged = new Map(rowsToDocs(res).map((d) => [d.id, d]));
          for (const [id, doc] of staged.get(table) ?? []) {
            if (doc === null) merged.delete(id);
            else if (field === undefined || String(doc[field]) === String(value)) merged.set(id, doc);
            else merged.delete(id);
          }
          return structuredClone([...merged.values()]);
        },
        async put(table, doc) {
          assertTable(table);
          if (!doc?.id) throw new Error('doc.id is required');
          stagedFor(table).set(doc.id, structuredClone(doc));
        },
        async del(table, id) {
          assertTable(table);
          stagedFor(table).set(id, null);
        },
      };

      const result = await fn(t);

      const statements = [];
      let n = 0;
      for (const [table, rows] of staged) {
        for (const [id, doc] of rows) {
          statements.push(doc === null ? deleteStatement(table, id, n++) : upsertStatement(table, doc, n++));
        }
      }
      if (statements.length) {
        const query = [...statements.flatMap((s) => s.declares), ...statements.map((s) => s.sql)].join('\n');
        const params = Object.assign({}, ...statements.map((s) => s.params));
        await session.executeQuery(query, params, txId ? { txId, commitTx: true } : { beginTx: SERIALIZABLE, commitTx: true });
      } else if (txId) {
        await session.commitTransaction({ txId });
      }
      return result;
    });
  }

  return { tx, close: () => driver.destroy() };
}
