import 'package:flutter/widgets.dart';

import 'update_info.dart';

/// Платформа без автообновления.
class Installer {
  static bool get supported => false;
  static Future<void> apply(BuildContext context, UpdateInfo info) async {}
}
