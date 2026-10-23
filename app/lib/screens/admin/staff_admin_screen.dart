import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api.dart';
import '../../models.dart';
import '../../widgets/common.dart';

class StaffAdminScreen extends StatefulWidget {
  const StaffAdminScreen({super.key, required this.user});
  final UserInfo user;

  @override
  State<StaffAdminScreen> createState() => _StaffAdminScreenState();
}

class _StaffAdminScreenState extends State<StaffAdminScreen> {
  final _loader = GlobalKey<LoaderState<List<UserInfo>>>();

  Future<List<UserInfo>> _load() async {
    final list = await Api.instance.get('/staff') as List;
    return [for (final e in list) UserInfo.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  Future<void> _invite() async {
    final res = await runAction(context, () => Api.instance.post('/staff/invites'));
    if (res == null || !mounted) return;
    final code = '${(res as Map)['code']}';
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Код для тренера'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(code, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 4)),
          const SizedBox(height: 12),
          const Text('Тренер устанавливает приложение, входит по своей почте и в «Профиле» вводит этот код. '
              'Код одноразовый и действует 7 дней.'),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              Navigator.pop(c);
              showMessage(context, 'Код скопирован');
            },
            child: const Text('Скопировать'),
          ),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Готово')),
        ],
      ),
    );
  }

  Future<void> _removeTrainer(UserInfo u) async {
    if (!await confirm(context, 'Убрать роль тренера?', text: '${u.name} больше не сможет отмечать посещения. Его группы останутся без тренера, пока вы не назначите нового.')) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(context, () => Api.instance.post('/staff/${u.id}/trainer', {'enabled': false}), success: 'Роль снята');
    if (ok != null) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Тренеры')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _invite,
        icon: const Icon(Icons.person_add),
        label: const Text('Пригласить тренера'),
      ),
      body: Loader<List<UserInfo>>(
        key: _loader,
        load: _load,
        builder: (context, staff, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            for (final u in staff)
              ListTile(
                leading: CircleAvatar(child: Icon(u.isAdmin ? Icons.admin_panel_settings : Icons.sports_martial_arts)),
                title: Text(u.name),
                subtitle: Text([u.email, if (u.phone != null) u.phone!, [if (u.isAdmin) 'админ', if (u.isTrainer) 'тренер'].join(', ')].join('\n')),
                isThreeLine: true,
                trailing: u.isTrainer && u.id != widget.user.id
                    ? IconButton(tooltip: 'Убрать роль тренера', onPressed: () => _removeTrainer(u), icon: const Icon(Icons.person_remove))
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
