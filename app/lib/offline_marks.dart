import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// UUID v4 для отметки: создаётся в телефоне, поэтому повторная отправка не задваивает посещение.
String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class PendingMark {
  PendingMark({required this.id, required this.childId, required this.groupId, required this.date});

  factory PendingMark.fromJson(Map<String, dynamic> j) =>
      PendingMark(id: '${j['id']}', childId: '${j['childId']}', groupId: '${j['groupId']}', date: '${j['date']}');

  final String id;
  final String childId;
  final String groupId;
  final String date;

  Map<String, dynamic> toJson() => {'id': id, 'childId': childId, 'groupId': groupId, 'date': date};
}

class SyncReport {
  SyncReport({this.sent = 0, this.errors = const [], this.offline = false});
  final int sent;
  final List<String> errors;
  final bool offline;
}

/// Очередь отметок, которые ещё не дошли до сервера. Хранится в телефоне и переживает перезапуск.
class OfflineMarks {
  OfflineMarks._();
  static final OfflineMarks instance = OfflineMarks._();

  static const _key = 'pending_marks';
  final List<PendingMark> _items = [];
  bool _loaded = false;
  Future<SyncReport>? _syncing;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      for (final e in jsonDecode(raw) as List) {
        _items.add(PendingMark.fromJson(Map<String, dynamic>.from(e as Map)));
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final m in _items) m.toJson()]));
  }

  Future<List<PendingMark>> all() async {
    await _ensureLoaded();
    return List.unmodifiable(_items);
  }

  Future<List<PendingMark>> forGroupDate(String groupId, String date) async {
    await _ensureLoaded();
    return _items.where((m) => m.groupId == groupId && m.date == date).toList();
  }

  Future<PendingMark> add({required String childId, required String groupId, required String date}) async {
    await _ensureLoaded();
    final existing = _items.where((m) => m.childId == childId && m.date == date);
    if (existing.isNotEmpty) return existing.first;
    final m = PendingMark(id: newUuid(), childId: childId, groupId: groupId, date: date);
    _items.add(m);
    await _save();
    return m;
  }

  /// Снять отметку, которая ещё не ушла на сервер.
  Future<bool> remove(String childId, String date) async {
    await _ensureLoaded();
    final before = _items.length;
    _items.removeWhere((m) => m.childId == childId && m.date == date);
    if (_items.length != before) await _save();
    return _items.length != before;
  }

  /// Отправить всё накопленное. Одновременно идёт только одна отправка.
  Future<SyncReport> sync() => _syncing ??= _doSync().whenComplete(() => _syncing = null);

  Future<SyncReport> _doSync() async {
    await _ensureLoaded();
    if (_items.isEmpty) return SyncReport();
    final batch = _items.take(100).toList();
    try {
      final res = await Api.instance.post('/attendance/batch', {'marks': [for (final m in batch) m.toJson()]});
      final results = (res['results'] as List).cast<Map>();
      final errors = <String>[];
      var sent = 0;
      for (var i = 0; i < batch.length && i < results.length; i++) {
        final r = results[i];
        // Отметка обработана (или отклонена по правилам) — убираем из очереди, чтобы не застряла навсегда.
        _items.removeWhere((m) => m.id == batch[i].id);
        if (r['status'] == 'error') {
          errors.add('${r['message']}');
        } else {
          sent++;
        }
      }
      await _save();
      if (_items.isNotEmpty && sent + errors.length == batch.length) {
        final more = await _doSync();
        return SyncReport(sent: sent + more.sent, errors: [...errors, ...more.errors], offline: more.offline);
      }
      return SyncReport(sent: sent, errors: errors);
    } on ApiException catch (e) {
      if (e.isOffline || e.status >= 500) return SyncReport(offline: true);
      rethrow;
    }
  }
}
