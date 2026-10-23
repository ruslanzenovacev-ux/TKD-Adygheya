// Таблицы и поля, по которым нужен поиск (в YDB для каждого поля создаётся вторичный индекс).
// Сами записи хранятся целиком в JSON-колонке `doc`, поэтому новые поля не требуют миграций.

export const TABLES = {
  users: ['email'],
  sessions: [],
  loginCodes: [],
  invites: [],
  groups: ['trainerId'],
  plans: [],
  children: ['parentId', 'groupId'],
  packages: ['childId'],
  attendance: ['childId', 'groupDate'],
  payments: ['childId', 'providerId', 'month'],
};

export function assertTable(table) {
  if (!Object.hasOwn(TABLES, table)) throw new Error(`Unknown table: ${table}`);
}

export function assertField(table, field) {
  assertTable(table);
  if (field !== undefined && !TABLES[table].includes(field)) {
    throw new Error(`Field ${field} is not indexed in ${table}`);
  }
}
