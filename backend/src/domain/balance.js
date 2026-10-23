// Правила абонементов. Чистые функции без доступа к базе — их легко проверить тестами.
//
// Абонемент (package) — это купленный пакет занятий: lessonsTotal, lessonsUsed, срок validFrom..validUntil.
// Остаток ребёнка = сумма неиспользованных занятий в несгоревших пакетах минус долг.
// Долг = посещения, которые тренер отметил, когда занятий не было (ребёнка не разворачиваем у двери).
// Следующая покупка сначала гасит долг.

export function remainingOf(pkg) {
  return Math.max(0, pkg.lessonsTotal - pkg.lessonsUsed);
}

function usable(pkg) {
  return !pkg.revoked && remainingOf(pkg) > 0;
}

export function isActiveOn(pkg, date) {
  return pkg.validFrom <= date && date <= pkg.validUntil;
}

const byExpiryThenCreated = (a, b) =>
  a.validUntil.localeCompare(b.validUntil) || String(a.createdAt).localeCompare(String(b.createdAt));

// Из какого пакета списать занятие за дату `date`.
// 1) пакет, действовавший в день занятия (сначала тот, что сгорает раньше);
// 2) иначе любой ещё не сгоревший на сегодня пакет (например, отметку синхронизировали позже, а
//    родитель тем временем уже купил новый абонемент).
// null — занятий нет, посещение запишется в долг.
export function pickPackage(packages, date, today) {
  const onDate = packages.filter((p) => usable(p) && isActiveOn(p, date)).sort(byExpiryThenCreated);
  if (onDate.length) return onDate[0];
  const alive = packages.filter((p) => usable(p) && p.validUntil >= today).sort(byExpiryThenCreated);
  return alive[0] ?? null;
}

// Распределить долги (посещения без пакета) по доступным пакетам.
// Возвращает список назначений { attendanceId, packageId } и мутирует lessonsUsed у переданных копий пакетов.
export function settleDebts(packages, debts, today) {
  const assignments = [];
  const ordered = [...debts].sort((a, b) => a.date.localeCompare(b.date) || String(a.createdAt).localeCompare(String(b.createdAt)));
  for (const debt of ordered) {
    const pkg = packages.filter((p) => usable(p) && p.validUntil >= today).sort(byExpiryThenCreated)[0];
    if (!pkg) break;
    pkg.lessonsUsed += 1;
    assignments.push({ attendanceId: debt.id, packageId: pkg.id });
  }
  return assignments;
}

export function summarize(packages, attendance, today) {
  const alive = packages.filter((p) => !p.revoked && p.validUntil >= today && remainingOf(p) > 0);
  const available = alive.reduce((sum, p) => sum + remainingOf(p), 0);
  const debt = attendance.filter((a) => a.status === 'present' && !a.packageId).length;
  const nextExpiry = alive.length ? [...alive].sort(byExpiryThenCreated)[0] : null;
  return {
    available,
    debt,
    balance: available - debt,
    nextExpiry: nextExpiry ? { date: nextExpiry.validUntil, lessons: remainingOf(nextExpiry) } : null,
  };
}
