// Печатает схему YDB для всех таблиц из src/repo/tables.js.
import { TABLES } from '../src/repo/tables.js';

let out = '-- Схема YDB. Генерируется из src/repo/tables.js: node scripts/gen-schema.js > schema/schema.yql\n';
out += '-- Каждая запись хранится целиком в doc (Json), поисковые поля продублированы в колонки с индексами.\n\n';
for (const [table, fields] of Object.entries(TABLES)) {
  out += `CREATE TABLE IF NOT EXISTS \`${table}\` (\n    id Utf8 NOT NULL,\n    doc Json,\n`;
  for (const f of fields) out += `    ${f} Utf8,\n`;
  for (const f of fields) out += `    INDEX idx_${f} GLOBAL SYNC ON (${f}),\n`;
  out += '    PRIMARY KEY (id)\n);\n\n';
}
process.stdout.write(out);
