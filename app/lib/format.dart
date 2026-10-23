// Форматирование для русского интерфейса.

/// 400000 копеек → «4 000 ₽», 350050 → «3 500,50 ₽».
String money(int kopecks) {
  final rub = kopecks ~/ 100;
  final kop = kopecks % 100;
  final digits = rub.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  if (kop != 0) buf.write(',${kop.toString().padLeft(2, '0')}');
  return '$buf ₽';
}

/// Склонение: plural(5, 'занятие', 'занятия', 'занятий') → «занятий».
String plural(int n, String one, String few, String many) {
  final a = n.abs() % 100;
  final b = a % 10;
  if (a > 10 && a < 20) return many;
  if (b == 1) return one;
  if (b >= 2 && b <= 4) return few;
  return many;
}

String lessons(int n) => '$n ${plural(n, 'занятие', 'занятия', 'занятий')}';

/// '2026-12-16' → '16.12.2026'
String dateRu(String? iso) {
  if (iso == null || iso.length < 10) return '';
  return '${iso.substring(8, 10)}.${iso.substring(5, 7)}.${iso.substring(0, 4)}';
}

/// ISO-время с сервера → '16.12.2026 14:05' по времени телефона.
String dateTimeRu(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Дата телефона в формате сервера.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const _weekdays = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
String weekdayRu(DateTime d) => _weekdays[d.weekday - 1];

const paymentStatusRu = {
  'pending': 'Ожидает оплаты',
  'succeeded': 'Оплачен',
  'canceled': 'Отменён',
  'refunded': 'Возврат',
  'review': 'На проверке',
  'failed': 'Ошибка',
};

const paymentMethodRu = {'sbp': 'СБП', 'cash': 'Наличные', 'transfer': 'Перевод'};
