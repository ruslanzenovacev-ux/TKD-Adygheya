// Хранилище в памяти: для тестов и локального запуска без облака.
// Повторяет поведение YDB-хранилища: транзакции выполняются по одной, изменения применяются
// только если вся функция завершилась без ошибки.

import { TABLES, assertField, assertTable } from './tables.js';

const clone = (v) => (v == null ? v : structuredClone(v));

export function createMemoryRepo() {
  const data = Object.fromEntries(Object.keys(TABLES).map((t) => [t, new Map()]));
  let chain = Promise.resolve();

  function tx(fn) {
    const run = async () => {
      const staged = new Map(); // table -> Map(id -> doc | null)
      const stagedFor = (table) => {
        if (!staged.has(table)) staged.set(table, new Map());
        return staged.get(table);
      };
      const t = {
        async get(table, id) {
          assertTable(table);
          const s = staged.get(table);
          if (s?.has(id)) return clone(s.get(id));
          return clone(data[table].get(id) ?? null);
        },
        async find(table, field, value) {
          assertField(table, field);
          const merged = new Map(data[table]);
          for (const [id, doc] of staged.get(table) ?? []) {
            if (doc === null) merged.delete(id);
            else merged.set(id, doc);
          }
          const rows = [...merged.values()];
          return clone(field === undefined ? rows : rows.filter((r) => String(r[field]) === String(value)));
        },
        async put(table, doc) {
          assertTable(table);
          if (!doc?.id) throw new Error('doc.id is required');
          stagedFor(table).set(doc.id, clone(doc));
        },
        async del(table, id) {
          assertTable(table);
          stagedFor(table).set(id, null);
        },
      };
      const result = await fn(t);
      for (const [table, rows] of staged) {
        for (const [id, doc] of rows) {
          if (doc === null) data[table].delete(id);
          else data[table].set(id, doc);
        }
      }
      return result;
    };
    const p = chain.then(run, run);
    chain = p.catch(() => {});
    return p;
  }

  return { tx, _data: data };
}
