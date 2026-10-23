import 'package:flutter/material.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';

class PlansAdminScreen extends StatefulWidget {
  const PlansAdminScreen({super.key});

  @override
  State<PlansAdminScreen> createState() => _PlansAdminScreenState();
}

class _PlansAdminScreenState extends State<PlansAdminScreen> {
  final _loader = GlobalKey<LoaderState<List<Plan>>>();

  Future<List<Plan>> _load() async {
    final list = await Api.instance.get('/plans') as List;
    return [for (final e in list) Plan.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  Future<void> _edit([Plan? plan]) async {
    final title = TextEditingController(text: plan?.title ?? '');
    final count = TextEditingController(text: plan == null ? '' : '${plan.lessons}');
    final price = TextEditingController(text: plan == null ? '' : '${plan.price / 100}'.replaceAll(RegExp(r'\.0$'), ''));
    final days = TextEditingController(text: plan == null ? '30' : '${plan.validDays}');
    var active = plan?.active ?? true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          title: Text(plan == null ? 'Новый абонемент' : 'Абонемент'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Название, например «8 занятий»')),
              TextField(controller: count, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Количество занятий')),
              TextField(
                controller: price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Цена, ₽'),
              ),
              TextField(controller: days, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Срок действия, дней')),
              if (plan != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Продаётся'),
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                ),
              if (plan != null)
                const Text('Новая цена действует для новых покупок; купленные абонементы не меняются.', style: TextStyle(fontSize: 12)),
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
      'title': title.text.trim(),
      'lessons': int.tryParse(count.text.trim()),
      'priceRub': double.tryParse(price.text.trim().replaceAll(',', '.').replaceAll(' ', '')),
      'validDays': int.tryParse(days.text.trim()),
      if (plan != null) 'active': active,
    };
    final res = await runAction(
      context,
      () => plan == null ? Api.instance.post('/plans', body) : Api.instance.patch('/plans/${plan.id}', body),
      success: 'Сохранено',
    );
    if (res != null) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Абонементы и цены')),
      floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
      body: Loader<List<Plan>>(
        key: _loader,
        load: _load,
        builder: (context, plans, _) => plans.isEmpty
            ? const EmptyState(icon: Icons.confirmation_number, text: 'Добавьте виды абонементов, которые смогут покупать родители')
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  for (final p in plans)
                    ListTile(
                      title: Text(p.title),
                      subtitle: Text('${lessons(p.lessons)} · ${p.validDays} ${plural(p.validDays, 'день', 'дня', 'дней')}'
                          '${p.active ? '' : ' · не продаётся'}'),
                      trailing: Text(money(p.price), style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () => _edit(p),
                    ),
                ],
              ),
      ),
    );
  }
}
