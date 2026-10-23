import 'package:flutter/material.dart';

import '../api.dart';
import '../config.dart';
import '../models.dart';
import '../update/updater.dart';
import '../widgets/common.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.user, required this.onLogout, required this.onUserChanged});

  final UserInfo user;
  final Future<void> Function() onLogout;
  final Future<void> Function(UserInfo) onUserChanged;

  String get _roles => [
        if (user.isAdmin) 'администратор',
        if (user.isTrainer) 'тренер',
        'родитель',
      ].join(', ');

  Future<void> _editName(BuildContext context) async {
    final name = TextEditingController(text: user.name);
    final phone = TextEditingController(text: user.phone ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Мои данные'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Имя и фамилия')),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Телефон')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final res = await runAction(context, () => Api.instance.patch('/me', {'name': name.text, 'phone': phone.text}), success: 'Сохранено');
    if (res != null) await onUserChanged(UserInfo.fromJson(Map<String, dynamic>.from(res as Map)));
  }

  Future<void> _redeem(BuildContext context) async {
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Код тренера'),
        content: TextField(
          controller: code,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Код приглашения от администратора'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Применить')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final res = await runAction(context, () => Api.instance.post('/me/redeem-invite', {'code': code.text}), success: 'Теперь вы тренер');
    if (res != null) await onUserChanged(UserInfo.fromJson(Map<String, dynamic>.from(res as Map)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(children: [
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(user.name),
          subtitle: Text('${user.email}\n$_roles'),
          isThreeLine: true,
          trailing: const Icon(Icons.edit),
          onTap: () => _editName(context),
        ),
        const Divider(),
        if (!user.isTrainer)
          ListTile(
            leading: const Icon(Icons.badge),
            title: const Text('Я тренер — ввести код приглашения'),
            onTap: () => _redeem(context),
          ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('Проверить обновления'),
          subtitle: Text('Версия ${AppConfig.version}'),
          onTap: () => Updater.check(context, manual: true),
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Выйти'),
          onTap: () async {
            if (await confirm(context, 'Выйти из аккаунта?')) await onLogout();
          },
        ),
      ]),
    );
  }
}
