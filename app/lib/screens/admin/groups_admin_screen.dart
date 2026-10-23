import 'package:flutter/material.dart';

import '../../api.dart';
import '../../models.dart';
import '../../widgets/common.dart';

class GroupsAdminScreen extends StatefulWidget {
  const GroupsAdminScreen({super.key});

  @override
  State<GroupsAdminScreen> createState() => _GroupsAdminScreenState();
}

class _GroupsAdminScreenState extends State<GroupsAdminScreen> {
  final _loader = GlobalKey<LoaderState<List<Group>>>();

  Future<List<Group>> _load() async {
    final list = await Api.instance.get('/groups') as List;
    return [for (final e in list) Group.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  Future<void> _edit([Group? group]) async {
    final staff = await runAction(context, () async {
      final list = await Api.instance.get('/staff') as List;
      return [for (final e in list) UserInfo.fromJson(Map<String, dynamic>.from(e as Map))].where((u) => u.isTrainer).toList();
    });
    if (staff == null || !mounted) return;

    final name = TextEditingController(text: group?.name ?? '');
    final schedule = TextEditingController(text: group?.schedule ?? '');
    final place = TextEditingController(text: group?.place ?? '');
    String? trainerId = group?.trainerId;
    var active = group?.active ?? true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(group == null ? 'Новая группа' : 'Группа'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Название, например «Младшие 6–9 лет»')),
              TextField(controller: schedule, decoration: const InputDecoration(labelText: 'Расписание, например «Пн, Ср, Пт 17:30»')),
              TextField(controller: place, decoration: const InputDecoration(labelText: 'Зал / адрес')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: staff.any((u) => u.id == trainerId) ? trainerId : null,
                decoration: const InputDecoration(labelText: 'Тренер'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Не назначен')),
                  for (final u in staff) DropdownMenuItem<String?>(value: u.id, child: Text(u.name)),
                ],
                onChanged: (v) => setLocal(() => trainerId = v),
              ),
              if (group != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Группа работает'),
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                ),
              if (staff.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Тренеров пока нет — пригласите их в разделе «Тренеры».', style: TextStyle(fontSize: 12)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final body = {
      'name': name.text.trim(),
      'schedule': schedule.text.trim(),
      'place': place.text.trim(),
      'trainerId': trainerId,
      if (group != null) 'active': active,
    };
    final res = await runAction(
      context,
      () => group == null ? Api.instance.post('/groups', body) : Api.instance.patch('/groups/${group.id}', body),
      success: 'Сохранено',
    );
    if (res != null) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Группы и расписание')),
      floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
      body: Loader<List<Group>>(
        key: _loader,
        load: _load,
        builder: (context, groups, _) => groups.isEmpty
            ? const EmptyState(icon: Icons.groups, text: 'Создайте группы, чтобы родители могли записывать детей')
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  for (final g in groups)
                    ListTile(
                      title: Text(g.active ? g.name : '${g.name} (закрыта)'),
                      subtitle: Text([
                        'Тренер: ${g.trainerName ?? 'не назначен'}',
                        if (g.schedule.isNotEmpty) g.schedule,
                        if (g.place.isNotEmpty) g.place,
                      ].join('\n')),
                      isThreeLine: g.schedule.isNotEmpty || g.place.isNotEmpty,
                      onTap: () => _edit(g),
                    ),
                ],
              ),
      ),
    );
  }
}
