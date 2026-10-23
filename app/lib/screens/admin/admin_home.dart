import 'package:flutter/material.dart';

import '../../models.dart';
import 'all_children_screen.dart';
import 'groups_admin_screen.dart';
import 'payments_admin_screen.dart';
import 'plans_admin_screen.dart';
import 'staff_admin_screen.dart';

class AdminHome extends StatelessWidget {
  const AdminHome({super.key, required this.user});
  final UserInfo user;

  @override
  Widget build(BuildContext context) {
    void open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    return Scaffold(
      appBar: AppBar(title: const Text('Управление')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.people),
          title: const Text('Все спортсмены'),
          subtitle: const Text('Поиск, остатки, перевод в группу, ручная оплата'),
          onTap: () => open(AllChildrenScreen(user: user)),
        ),
        ListTile(
          leading: const Icon(Icons.payments),
          title: const Text('Оплаты'),
          subtitle: const Text('Платежи за месяц, выручка, возвраты'),
          onTap: () => open(const PaymentsAdminScreen()),
        ),
        ListTile(
          leading: const Icon(Icons.confirmation_number),
          title: const Text('Абонементы и цены'),
          onTap: () => open(const PlansAdminScreen()),
        ),
        ListTile(
          leading: const Icon(Icons.groups),
          title: const Text('Группы и расписание'),
          onTap: () => open(const GroupsAdminScreen()),
        ),
        ListTile(
          leading: const Icon(Icons.badge),
          title: const Text('Тренеры'),
          subtitle: const Text('Приглашения и доступ'),
          onTap: () => open(StaffAdminScreen(user: user)),
        ),
      ]),
    );
  }
}
