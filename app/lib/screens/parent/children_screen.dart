import 'package:flutter/material.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';
import 'add_child_screen.dart';
import 'child_screen.dart';

/// «Мои дети»: остаток занятий у каждого ребёнка.
class ChildrenScreen extends StatefulWidget {
  const ChildrenScreen({super.key, required this.user});
  final UserInfo user;

  @override
  State<ChildrenScreen> createState() => _ChildrenScreenState();
}

class _ChildrenScreenState extends State<ChildrenScreen> {
  final _loader = GlobalKey<LoaderState<List<Child>>>();

  Future<List<Child>> _load() async {
    final list = await Api.instance.get('/children') as List;
    // Тренер/админ видят здесь только своих детей как родитель.
    return [
      for (final e in list) Child.fromJson(Map<String, dynamic>.from(e as Map)),
    ].where((c) => c.parentId == widget.user.id).toList();
  }

  Future<void> _add() async {
    final added = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const AddChildScreen()));
    if (added == true) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Мои дети')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Добавить ребёнка'),
      ),
      body: Loader<List<Child>>(
        key: _loader,
        load: _load,
        builder: (context, children, reload) {
          if (children.isEmpty) {
            return const EmptyState(
              icon: Icons.child_care,
              text: 'Добавьте ребёнка и выберите его группу. После подтверждения тренером можно будет купить абонемент.',
            );
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            children: [
              for (final c in children)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: BalanceBadge(balance: c.balance),
                    title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(_subtitle(c)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ChildScreen(childId: c.id, user: widget.user)),
                      );
                      reload();
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _subtitle(Child c) {
    final parts = <String>[c.groupName ?? 'Без группы'];
    if (c.isPending) {
      parts.add('Ждёт подтверждения тренером');
    } else if (c.debt > 0 && c.available == 0) {
      parts.add('Долг: ${lessons(c.debt)}');
    } else if (c.balance <= 0) {
      parts.add('Занятия закончились');
    } else {
      parts.add('Осталось ${lessons(c.balance)}');
      if (c.nextExpiryDate != null) parts.add('действует до ${dateRu(c.nextExpiryDate)}');
    }
    return parts.join(' · ');
  }
}
