import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../widgets/common.dart';
import 'update_info.dart';

/// Android: скачать APK → проверить SHA-256 → открыть системный установщик.
/// Нативная часть — android/app/src/main/kotlin/.../MainActivity.kt (канал ru.tkdclub/updater).
class Installer {
  static const _channel = MethodChannel('ru.tkdclub/updater');

  static bool get supported => Platform.isAndroid;

  static Future<void> apply(BuildContext context, UpdateInfo info) async {
    if (!Platform.isAndroid) return;

    // Android 8+: приложению нужно разрешение «Установка неизвестных приложений».
    final canInstall = await _channel.invokeMethod<bool>('canInstall') ?? false;
    if (!canInstall) {
      if (!context.mounted) return;
      final ok = await confirm(
        context,
        'Нужно разрешение',
        text: 'Чтобы установить обновление, разрешите этому приложению устанавливать приложения. '
            'Откроются настройки — включите переключатель и вернитесь назад.',
        ok: 'Открыть настройки',
      );
      if (!ok) return;
      // Ждём, пока пользователь вернётся из настроек, и проверяем разрешение ещё раз.
      final resumed = Completer<void>();
      final listener = AppLifecycleListener(onResume: () {
        if (!resumed.isCompleted) resumed.complete();
      });
      await _channel.invokeMethod<void>('openInstallSettings');
      await resumed.future.timeout(const Duration(minutes: 5), onTimeout: () {});
      listener.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!(await _channel.invokeMethod<bool>('canInstall') ?? false)) {
        if (context.mounted) showMessage(context, 'Разрешение не выдано. Нажмите «Обновить» ещё раз после настройки', error: true);
        return;
      }
    }
    if (!context.mounted) return;

    final progress = ValueNotifier<double?>(null);
    final cancel = Completer<void>();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('Загрузка версии ${info.version}'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v),
              const SizedBox(height: 8),
              Text(v == null ? 'Подготовка…' : '${(v * 100).round()}%'),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (!cancel.isCompleted) cancel.complete();
              },
              child: const Text('Отмена'),
            ),
          ],
        ),
      ),
    );

    String? error;
    File? apk;
    try {
      apk = await _download(info, progress, cancel.future);
    } on _Cancelled {
      error = null;
    } catch (e) {
      error = e is _UpdateError ? e.message : 'Не удалось скачать обновление. Проверьте интернет';
    }
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();

    if (error != null) {
      if (context.mounted) showMessage(context, error, error: true);
      return;
    }
    if (apk == null) return;
    try {
      await _channel.invokeMethod<bool>('install', {'path': apk.path});
    } on PlatformException catch (_) {
      if (context.mounted) showMessage(context, 'Не удалось открыть установщик', error: true);
    }
  }

  static Future<File> _download(UpdateInfo info, ValueNotifier<double?> progress, Future<void> cancelled) async {
    if (!info.apkUrl.startsWith('https://')) throw _UpdateError('Некорректная ссылка на обновление');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(info.sha256)) throw _UpdateError('Нет контрольной суммы обновления');

    final cacheDir = await _channel.invokeMethod<String>('cacheDir');
    final dir = Directory('$cacheDir/updates');
    if (dir.existsSync()) dir.deleteSync(recursive: true); // старые APK больше не нужны
    dir.createSync(recursive: true);
    final file = File('${dir.path}/tkd-${info.build}.apk');

    final client = http.Client();
    var isCancelled = false;
    unawaited(cancelled.then((_) {
      isCancelled = true;
      client.close();
    }));
    try {
      final res = await client.send(http.Request('GET', Uri.parse(info.apkUrl))).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw _UpdateError('Сервер обновлений недоступен (${res.statusCode})');
      final total = res.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) progress.value = received / total;
        }
      } finally {
        await sink.close();
      }
    } catch (e) {
      if (isCancelled) throw _Cancelled();
      rethrow;
    } finally {
      client.close();
    }
    if (isCancelled) throw _Cancelled();

    // Проверка целостности: скачалось ровно то, что собрал GitHub Actions.
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != info.sha256) {
      file.deleteSync();
      throw _UpdateError('Файл обновления повреждён. Попробуйте ещё раз');
    }
    return file;
  }
}

class _UpdateError implements Exception {
  _UpdateError(this.message);
  final String message;
}

class _Cancelled implements Exception {}
