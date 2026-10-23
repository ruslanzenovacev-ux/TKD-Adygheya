// Даты занятий и абонементов храним как 'YYYY-MM-DD' по московскому времени,
// чтобы «сегодня» у тренера в зале и на сервере совпадало.

const MSK_OFFSET_MS = 3 * 60 * 60 * 1000;

export function mskDate(date) {
  return new Date(date.getTime() + MSK_OFFSET_MS).toISOString().slice(0, 10);
}

export function addDays(isoDate, days) {
  const d = new Date(`${isoDate}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function isIsoDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

export function monthOf(isoDateOrTimestamp) {
  return String(isoDateOrTimestamp).slice(0, 7);
}
