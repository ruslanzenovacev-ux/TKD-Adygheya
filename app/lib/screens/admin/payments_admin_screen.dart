import 'package:flutter/material.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';
import '../../update/download.dart';

/// Платежи за месяц и выручка. Выгрузка в Excel — в веб-версии (на телефоне файл открыть неудобно).
class PaymentsAdminScreen extends StatefulWidget {
  const PaymentsAdminScreen({super.key});

  @override
  State<PaymentsAdminScreen> createState() => _PaymentsAdminScreenState();
}

class _PaymentsAdminScreenState extends State<PaymentsAdminScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  final _loader = GlobalKey<LoaderState<List<Payment>>>();

  String get _monthKey => '${_month.year}-${_month.month.toString().padLeft(2, '0')}';

  static const _monthsRu = ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'];

  Future<List<Payment>> _load() async {
    final list = await Api.instance.get('/payments', query: {'month': _monthKey}) as List;
    return [for (final e in list) Payment.fromJson(Map<String, dynamic>.from(e as Map))].reversed.toList();
  }

  void _shift(int m) {
    final next = DateTime(_month.year, _month.month + m);
    if (next.isAfter(DateTime.now())) return;
    setState(() => _month = next);
    _loader.currentState?.reload();
  }

  Future<void> _exportCsv() async {
    if (!canDownloadFiles) {
      showMessage(context, 'Выгрузка в Excel доступна в веб-версии приложения на компьютере');
      return;
    }
    final csv = await runAction(context, () => Api.instance.get('/reports/payments.csv', query: {'month': _monthKey}));
    if (csv is String) downloadText('payments-$_monthKey.csv', csv, 'text/csv;charset=utf-8');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Оплаты'),
        actions: [IconButton(tooltip: 'Выгрузить в Excel', onPressed: _exportCsv, icon: const Icon(Icons.download))],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
            Text('${_monthsRu[_month.month - 1]} ${_month.year}', style: Theme.of(context).textTheme.titleMedium),
            IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right)),
          ]),
        ),
      ),
      body: Loader<List<Payment>>(
        key: _loader,
        load: _load,
        builder: (context, payments, _) {
          final paid = payments.where((p) => p.status == 'succeeded' || p.status == 'refunded');
          final total = paid.fold<int>(0, (s, p) => s + p.amount - p.refundedAmount);
          final online = paid.where((p) => p.method == 'sbp').fold<int>(0, (s, p) => s + p.amount - p.refundedAmount);
          final review = payments.where((p) => p.status == 'review').length;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Выручка: ${money(total)}', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text('Онлайн (СБП): ${money(online)} · вручную: ${money(total - online)}'),
                    Text('Оплат: ${paid.length}'),
                    if (review > 0)
                      Text('Требуют проверки: $review', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ]),
                ),
              ),
              if (payments.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Оплат в этом месяце нет', textAlign: TextAlign.center)),
              for (final p in payments)
                ListTile(
                  title: Text(p.title),
                  subtitle: Text('${dateTimeRu(p.createdAt)} · ${paymentMethodRu[p.method] ?? ''} · ${paymentStatusRu[p.status] ?? p.status}'
                      '${p.refundedAmount > 0 ? ' · возвращено ${money(p.refundedAmount)}' : ''}'),
                  trailing: Text(money(p.amount), style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: p.status == 'succeeded' ? null : Theme.of(context).colorScheme.outline,
                  )),
                ),
            ],
          );
        },
      ),
    );
  }
}
