import 'package:flutter/material.dart';

import '../models.dart';
import '../update/updater.dart';
import 'admin/admin_home.dart';
import 'parent/children_screen.dart';
import 'profile.dart';
import 'trainer/groups_screen.dart';

/// Главный экран: вкладки зависят от ролей пользователя.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.user, required this.onLogout, required this.onUserChanged});

  final UserInfo user;
  final Future<void> Function() onLogout;
  final Future<void> Function(UserInfo) onUserChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Tab {
  const _Tab(this.label, this.icon, this.builder);
  final String label;
  final IconData icon;
  final Widget Function() builder;
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Updater.check(context);
    });
  }

  List<_Tab> get _tabs {
    final u = widget.user;
    return [
      if (u.isTrainer || u.isAdmin) _Tab('Группы', Icons.groups, () => GroupsScreen(user: u)),
      _Tab('Мои дети', Icons.child_care, () => ChildrenScreen(user: u)),
      if (u.isAdmin) _Tab('Управление', Icons.tune, () => AdminHome(user: u)),
      _Tab('Профиль', Icons.person, () => ProfileScreen(user: u, onLogout: widget.onLogout, onUserChanged: widget.onUserChanged)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final index = _index.clamp(0, tabs.length - 1);
    return Scaffold(
      body: IndexedStack(index: index, children: [for (final t in tabs) t.builder()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.icon), label: t.label)],
      ),
    );
  }
}
