import 'package:flutter/material.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';

/// Оплата наличными или переводом: занятия зачисляются сразу.
class ManualPaymentScreen extends StatefulWidget {
  const ManualPaymentScreen({super.key, required this.child});
  final Child child;

  @override
  State<ManualPaymentScreen> createState() => _ManualPaymentScreenState();
}

class _ManualPaymentScreenState extends State<ManualPaymentScreen> {
  String? _planId;
  String _method = 'cash';
  final _amount = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<List<Plan>> _load() async {
    final list = await Api.instance.get('/plans') as List;
    return [for (final e in list) Plan.fromJson(Map<String, dynamic>.from(e as Map))].where((p) => p.active).toList();
  }

  Future<void> _save() async {
    if (_planId == null) {
      showMessage(context, 'Выберите абонемент', error: true);
      return;
    }
    final amount = _amount.text.trim().isEmpty ? null : double.tryParse(_amount.text.trim().replaceAll(',', '.').replaceAll(' ', ''));
    if (_amount.text.trim().isNotEmpty && amount == null) {
      showMessage(context, 'Проверьте сумму', error: true);
      return;
    }
    setState(() => _busy = true);
    final res = await runAction(
      context,
      () => Api.instance.post('/payments/manual', {
        'childId': widget.child.id,
        'planId': _planId,
        'method': _method,
        if (amount != null) 'amountRub': amount,
        if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
      }),
      success: 'Оплата внесена, занятия зачислены',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res != null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Оплата: ${widget.child.name}')),
      body: Loader<List<Plan>>(
        load: _load,
        builder: (context, plans, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Абонемент'),
            RadioGroup<String>(
              groupValue: _planId,
              onChanged: (v) => setState(() => _planId = v),
              child: Column(children: [
                for (final p in plans)
                  RadioListTile<String>(value: p.id, title: Text(p.title), subtitle: Text('${lessons(p.lessons)} · ${money(p.price)}')),
              ]),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'cash', label: Text('Наличные'), icon: Icon(Icons.payments)),
                ButtonSegment(value: 'transfer', label: Text('Перевод'), icon: Icon(Icons.account_balance)),
              ],
              selected: {_method},
              onSelectionChanged: (s) => setState(() => _method = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Сумма, ₽ (если отличается от цены — скидка)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Комментарий', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            if (_method == 'cash')
              const Text('Не забудьте пробить чек на кассе — оплату наличными приложение не фискализирует.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Padding(padding: EdgeInsets.all(12), child: Text('Внести оплату')),
            ),
          ],
        ),
      ),
    );
  }
}
