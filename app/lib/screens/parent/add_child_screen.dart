import 'package:flutter/material.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';

class AddChildScreen extends StatefulWidget {
  const AddChildScreen({super.key});

  @override
  State<AddChildScreen> createState() => _AddChildScreenState();
}

class _AddChildScreenState extends State<AddChildScreen> {
  final _name = TextEditingController();
  DateTime? _birth;
  String? _groupId;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<List<Group>> _loadGroups() async {
    final list = await Api.instance.get('/groups') as List;
    return [for (final e in list) Group.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  Future<void> _pickBirth() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _birth ?? DateTime(now.year - 8),
      firstDate: DateTime(now.year - 60),
      lastDate: now,
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Дата рождения',
    );
    if (d != null) setState(() => _birth = d);
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) {
      showMessage(context, 'Укажите имя и фамилию ребёнка', error: true);
      return;
    }
    if (_groupId == null) {
      showMessage(context, 'Выберите группу', error: true);
      return;
    }
    setState(() => _busy = true);
    final res = await runAction(
      context,
      () => Api.instance.post('/children', {
        'name': _name.text.trim(),
        'groupId': _groupId,
        if (_birth != null) 'birthDate': isoDate(_birth!),
      }),
      success: 'Ребёнок добавлен. Тренер подтвердит его на ближайшей тренировке',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Новый спортсмен')),
      body: Loader<List<Group>>(
        load: _loadGroups,
        builder: (context, groups, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Имя и фамилия ребёнка', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickBirth,
              icon: const Icon(Icons.cake),
              label: Text(_birth == null ? 'Дата рождения (необязательно)' : 'Дата рождения: ${dateRu(isoDate(_birth!))}'),
            ),
            const SizedBox(height: 16),
            const Text('Группа'),
            const SizedBox(height: 4),
            if (groups.isEmpty) const Text('Группы ещё не созданы. Обратитесь к тренеру.'),
            RadioGroup<String>(
              groupValue: _groupId,
              onChanged: (v) => setState(() => _groupId = v),
              child: Column(children: [
                for (final g in groups)
                  RadioListTile<String>(
                    value: g.id,
                    title: Text(g.name),
                    subtitle: Text([
                      if (g.trainerName != null) 'Тренер: ${g.trainerName}',
                      if (g.schedule.isNotEmpty) g.schedule,
                      if (g.place.isNotEmpty) g.place,
                    ].join('\n')),
                  ),
              ]),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Padding(padding: EdgeInsets.all(12), child: Text('Добавить')),
            ),
          ],
        ),
      ),
    );
  }
}
