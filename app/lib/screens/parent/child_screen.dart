import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';
import '../admin/manual_payment_screen.dart';

/// Карточка спортсмена: остаток, покупка абонемента, история.
/// Её же видят тренер и админ (с дополнительными действиями).
class ChildScreen extends StatefulWidget {
  const ChildScreen({super.key, required this.childId, required this.user});

  final String childId;
  final UserInfo user;

  @override
  State<ChildScreen> createState() => _ChildScreenState();
}

class _ChildScreenState extends State<ChildScreen> with WidgetsBindingObserver {
  final _loader = GlobalKey<LoaderState<Child>>();
  String? _awaitingPaymentId;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Родитель вернулся из банковского приложения — проверяем оплату.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingPaymentId != null) _checkPayment();
  }

  Future<Child> _load() async =>
      Child.fromJson(Map<String, dynamic>.from(await Api.instance.get('/children/${widget.childId}') as Map));

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _buy(Child child) async {
    final plans = await runAction(context, () async {
      final list = await Api.instance.get('/plans') as List;
      return [for (final e in list) Plan.fromJson(Map<String, dynamic>.from(e as Map))];
    });
    if (plans == null || !mounted) return;
    final plan = await showModalBottomSheet<Plan>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Абонемент для ${child.name}', style: Theme.of(c).textTheme.titleMedium),
          ),
          for (final p in plans)
            ListTile(
              title: Text(p.title),
              subtitle: Text('${lessons(p.lessons)} · действует ${p.validDays} ${plural(p.validDays, 'день', 'дня', 'дней')}'),
              trailing: Text(money(p.price), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              onTap: () => Navigator.pop(c, p),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Оплата через СБП: откроется приложение вашего банка. Чек придёт на почту.'),
          ),
        ]),
      ),
    );
    if (plan == null || !mounted) return;

    final res = await runAction(context, () => Api.instance.post('/payments', {'childId': child.id, 'planId': plan.id}));
    if (res == null || !mounted) return;
    final payment = Payment.fromJson(Map<String, dynamic>.from(res as Map));
    if (payment.confirmationUrl == null) {
      showMessage(context, 'Не удалось получить ссылку на оплату', error: true);
      return;
    }
    _awaitingPaymentId = payment.id;
    final opened = await launchUrl(Uri.parse(payment.confirmationUrl!), mode: LaunchMode.externalApplication);
    if (!opened && mounted) showMessage(context, 'Не удалось открыть страницу оплаты', error: true);
  }

  Future<void> _checkPayment() async {
    final id = _awaitingPaymentId;
    if (id == null || _checking) return;
    setState(() => _checking = true);
    try {
      // Банк может подтверждать оплату несколько секунд — спрашиваем до ~30 секунд.
      for (var i = 0; i < 10 && mounted; i++) {
        final p = Payment.fromJson(Map<String, dynamic>.from(await Api.instance.get('/payments/$id') as Map));
        if (p.status == 'succeeded') {
          _awaitingPaymentId = null;
          if (mounted) showMessage(context, 'Оплата прошла, занятия зачислены 🎉');
          await _reload();
          return;
        }
        if (p.status == 'canceled' || p.status == 'failed') {
          _awaitingPaymentId = null;
          if (mounted) showMessage(context, 'Оплата не прошла или была отменена', error: true);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (mounted) showMessage(context, 'Оплата ещё обрабатывается. Остаток обновится автоматически');
    } catch (e) {
      if (mounted) showMessage(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _approve(Child child) async {
    final ok = await runAction(context, () => Api.instance.post('/children/${child.id}/approve'), success: 'Спортсмен подтверждён');
    if (ok != null) _reload();
  }

  Future<void> _changeGroup(Child child) async {
    final groups = await runAction(context, () async {
      final list = await Api.instance.get('/groups') as List;
      return [for (final e in list) Group.fromJson(Map<String, dynamic>.from(e as Map))];
    });
    if (groups == null || !mounted) return;
    final g = await showDialog<Group>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Перевести в группу'),
        children: [
          for (final g in groups.where((g) => g.active))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, g),
              child: Text(g.id == child.groupId ? '${g.name} (сейчас)' : g.name),
            ),
        ],
      ),
    );
    if (g == null || g.id == child.groupId || !mounted) return;
    final ok = await runAction(context, () => Api.instance.patch('/children/${child.id}', {'groupId': g.id}), success: 'Переведён в «${g.name}»');
    if (ok != null) _reload();
  }

  Future<void> _setArchived(Child child, bool archived) async {
    if (!await confirm(context, archived ? 'Отправить в архив?' : 'Вернуть из архива?',
        text: archived ? 'Спортсмен пропадёт из списков группы. Данные сохранятся.' : null)) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(context, () => Api.instance.patch('/children/${child.id}', {'status': archived ? 'archived' : 'active'}));
    if (ok != null) _reload();
  }

  Future<void> _manualPayment(Child child) async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => ManualPaymentScreen(child: child)));
    if (ok == true) _reload();
  }

  Future<void> _refund(Map<String, dynamic> p) async {
    if (!await confirm(context, 'Оформить возврат?',
        text: 'Неиспользованные занятия этого абонемента будут списаны, деньги за них вернутся родителю.', ok: 'Вернуть')) {
      return;
    }
    if (!mounted) return;
    final res = await runAction(context, () => Api.instance.post('/payments/${p['id']}/refund', {}));
    if (res != null && mounted) {
      showMessage(context, 'Возврат оформлен: ${money((res as Map)['refundedAmount'] as int)}');
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<Child>(
      key: _loader,
      load: _load,
      builder: (context, child, reload) {
        final u = widget.user;
        final isParent = child.parentId == u.id;
        final canManage = u.isAdmin;
        final canApprove = child.isPending && (u.isTrainer || u.isAdmin);
        return Scaffold(
          appBar: AppBar(
            title: Text(child.name),
            actions: [
              if (canManage)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'manual':
                        _manualPayment(child);
                      case 'group':
                        _changeGroup(child);
                      case 'archive':
                        _setArchived(child, !child.isArchived);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'manual', child: Text('Внести оплату (наличные/перевод)')),
                    const PopupMenuItem(value: 'group', child: Text('Перевести в другую группу')),
                    PopupMenuItem(value: 'archive', child: Text(child.isArchived ? 'Вернуть из архива' : 'В архив')),
                  ],
                ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _header(context, child),
                if (child.isPending)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: ListTile(
                      leading: const Icon(Icons.hourglass_top),
                      title: const Text('Ждёт подтверждения тренером'),
                      subtitle: const Text('После подтверждения можно будет купить абонемент'),
                      trailing: canApprove ? FilledButton(onPressed: () => _approve(child), child: const Text('Подтвердить')) : null,
                    ),
                  ),
                if (isParent && child.status == 'active')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: FilledButton.icon(
                      onPressed: _checking ? null : () => _buy(child),
                      icon: _checking
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.qr_code_2),
                      label: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_checking ? 'Проверяем оплату…' : 'Купить абонемент (СБП)'),
                      ),
                    ),
                  ),
                if (child.parentId != u.id && child.raw['parent'] is Map) _parentTile(Map<String, dynamic>.from(child.raw['parent'] as Map)),
                ..._packages(child),
                ..._attendance(child),
                ..._payments(child, canManage),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, Child c) {
    final t = Theme.of(context).textTheme;
    String line;
    if (c.debt > 0 && c.available == 0) {
      line = 'Долг: ${lessons(c.debt)}. Он спишется из следующего абонемента';
    } else if (c.balance <= 0) {
      line = 'Занятия закончились';
    } else {
      line = 'Осталось ${lessons(c.balance)}';
      if (c.nextExpiryDate != null) {
        line += '\n${lessons(c.nextExpiryLessons)} действуют до ${dateRu(c.nextExpiryDate)}';
      }
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        BalanceBadge(balance: c.balance, large: true),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.groupName ?? 'Без группы', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(line, style: t.bodyMedium),
          ]),
        ),
      ]),
    );
  }

  Widget _parentTile(Map<String, dynamic> p) => ListTile(
        leading: const Icon(Icons.family_restroom),
        title: Text('${p['name']}'),
        subtitle: Text([p['email'], if (p['phone'] != null) p['phone']].join(' · ')),
      );

  List<Widget> _packages(Child c) {
    final list = c.listOf('packages');
    if (list.isEmpty) return const [];
    return [
      const SectionTitle('Абонементы'),
      for (final p in list)
        ListTile(
          dense: true,
          leading: Icon(
            p['revoked'] == true || p['expired'] == true ? Icons.history : Icons.confirmation_number,
            color: p['revoked'] == true || p['expired'] == true ? Theme.of(context).colorScheme.outline : null,
          ),
          title: Text('${p['title'] ?? lessons(p['lessonsTotal'] as int)}'),
          subtitle: Text('${dateRu('${p['validFrom']}')} – ${dateRu('${p['validUntil']}')} · '
              'использовано ${p['lessonsUsed']} из ${p['lessonsTotal']}'
              '${p['revoked'] == true ? ' · возврат' : p['expired'] == true ? ' · срок истёк' : ''}'),
          trailing: Text('${p['remaining']}', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
    ];
  }

  List<Widget> _attendance(Child c) {
    final list = c.listOf('attendance');
    return [
      SectionTitle('Посещения (${list.length})'),
      if (list.isEmpty) const ListTile(dense: true, title: Text('Пока нет')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final a in list)
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text(dateRu('${a['date']}').substring(0, 5)),
              avatar: a['debt'] == true ? const Icon(Icons.priority_high, size: 16) : null,
            ),
        ]),
      ),
    ];
  }

  List<Widget> _payments(Child c, bool canManage) {
    final list = c.listOf('payments');
    if (list.isEmpty) return const [];
    return [
      const SectionTitle('Платежи'),
      for (final p in list)
        ListTile(
          dense: true,
          title: Text('${p['title']}'),
          subtitle: Text('${dateTimeRu('${p['createdAt']}')} · ${paymentMethodRu[p['method']] ?? ''} · ${paymentStatusRu[p['status']] ?? p['status']}'),
          trailing: Text(money(p['amount'] as int)),
          onLongPress: canManage && p['status'] == 'succeeded' ? () => _refund(p) : null,
        ),
      if (canManage)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Чтобы оформить возврат, нажмите и удерживайте оплаченный платёж.', style: TextStyle(fontSize: 12)),
        ),
    ];
  }
}
