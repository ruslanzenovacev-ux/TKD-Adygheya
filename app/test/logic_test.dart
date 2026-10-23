import 'package:flutter_test/flutter_test.dart';
import 'package:tkd_app/format.dart';
import 'package:tkd_app/offline_marks.dart';
import 'package:tkd_app/update/update_info.dart';

void main() {
  test('деньги и склонения', () {
    expect(money(400000), '4 000 ₽');
    expect(money(350050), '3 500,50 ₽');
    expect(money(99900), '999 ₽');
    expect(lessons(1), '1 занятие');
    expect(lessons(3), '3 занятия');
    expect(lessons(12), '12 занятий');
    expect(lessons(21), '21 занятие');
    expect(dateRu('2026-12-16'), '16.12.2026');
    expect(isoDate(DateTime(2026, 3, 5)), '2026-03-05');
  });

  test('UUID отметки — версия 4 и уникальный', () {
    final a = newUuid();
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(a), isTrue);
    expect(newUuid(), isNot(a));
  });

  test('обновление: новее / обязательное', () {
    final info = UpdateInfo.fromJson({'version': '1.0.42', 'build': 142, 'minBuild': 130, 'apkUrl': 'https://x/a.apk', 'sha256': 'AB'});
    expect(info.isNewerThan(141), isTrue);
    expect(info.isNewerThan(142), isFalse);
    expect(info.isRequiredFor(129), isTrue);
    expect(info.isRequiredFor(130), isFalse);
    expect(info.sha256, 'ab');
  });
}
