import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'update_info.dart';

/// Веб-версия: новая версия уже лежит на сервере, достаточно перезагрузить страницу.
class Installer {
  static bool get supported => true;

  static Future<void> apply(BuildContext context, UpdateInfo info) async {
    web.window.location.reload();
  }
}
