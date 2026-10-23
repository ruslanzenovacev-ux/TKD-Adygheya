import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../models.dart';
import '../../widgets/common.dart';
import 'roster_screen.dart';

/// Группы тренера (админ видит все). Список кэшируется, чтобы открываться без интернета.
class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key, required this.user});
  final UserInfo user;

  static const _cacheKey = 'groups_cache';

  Future<List<Group>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    List raw;
    try {
      raw = await Api.instance.get('/groups', query: user.isAdmin ? null : {'mine': '1'}) as List;
      await prefs.setString(_cacheKey, jsonEncode(raw));
    } on ApiException catch (e) {
      final cached = prefs.getString(_cacheKey);
      if (!e.isOffline || cached == null) rethrow;
      raw = jsonDecode(cached) as List;
    }
    return [for (final e in raw) Group.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Группы')),
      body: Loader<List<Group>>(
        load: _load,
        builder: (context, groups, _) {
          if (groups.isEmpty) {
            return const EmptyState(icon: Icons.groups, text: 'За вами пока не закреплено ни одной группы. Обратитесь к администратору.');
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            children: [
              for (final g in groups)
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: const CircleAvatar(child: Icon(Icons.sports_martial_arts)),
                    title: Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      if (g.schedule.isNotEmpty) g.schedule,
                      if (g.place.isNotEmpty) g.place,
                      if (user.isAdmin) 'Тренер: ${g.trainerName ?? 'не назначен'}',
                    ].join('\n')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RosterScreen(group: g, user: user))),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
