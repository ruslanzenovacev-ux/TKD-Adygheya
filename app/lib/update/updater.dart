import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../widgets/common.dart';
import 'installer_stub.dart' if (dart.library.io) 'installer_io.dart' if (dart.library.js_interop) 'installer_web.dart';
import 'update_info.dart';

/// Автообновление.
/// Android: скачиваем новый APK, проверяем контрольную сумму и открываем установщик.
/// Веб-версия (iPhone): перезагружаем страницу — браузер подтянет новую версию.
class Updater {
  static const _lastCheckKey = 'update_last_check';
  static const _autoCheckEvery = Duration(hours: 6);
  static bool _busy = false;

  static Future<void> check(BuildContext context, {bool manual = false}) async {
    if (_busy) return;
    if (AppConfig.updateUrl.isEmpty || !Installer.supported) {
      if (manual) showMessage(context, 'Обновления устанавливаются через магазин приложений');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!manual && now - last < _autoCheckEvery.inMilliseconds) return;

    _busy = true;
    try {
      final info = await _fetch();
      await prefs.setInt(_lastCheckKey, now);
      if (!context.mounted) return;
      if (info == null || !info.isNewerThan(AppConfig.build)) {
        if (manual) showMessage(context, 'У вас последняя версия (${AppConfig.version})');
        return;
      }
      await _offer(context, info);
    } catch (_) {
      if (manual && context.mounted) showMessage(context, 'Не удалось проверить обновления. Проверьте интернет', error: true);
    } finally {
      _busy = false;
    }
  }

  static Future<UpdateInfo?> _fetch() async {
    final uri = Uri.parse(AppConfig.updateUrl).replace(queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'});
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    return UpdateInfo.fromJson(Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)) as Map));
  }

  static Future<void> _offer(BuildContext context, UpdateInfo info) async {
    final mandatory = info.isRequiredFor(AppConfig.build);
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: !mandatory,
      builder: (c) => PopScope(
        canPop: !mandatory,
        child: AlertDialog(
          title: Text('Доступна версия ${info.version}'),
          content: SingleChildScrollView(
            child: Text([
              if (mandatory) 'Это обязательное обновление: без него приложение может работать неправильно.',
              if (info.notes.isNotEmpty) 'Что нового:\n${info.notes}',
              if (!mandatory && info.notes.isEmpty) 'Рекомендуем обновиться.',
            ].join('\n\n')),
          ),
          actions: [
            if (!mandatory) TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Позже')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Обновить')),
          ],
        ),
      ),
    );
    if (go != true || !context.mounted) return;
    await Installer.apply(context, info);
    // Если обязательное обновление не поставили — спросим снова.
    if (mandatory && context.mounted) await _offer(context, info);
  }
}
