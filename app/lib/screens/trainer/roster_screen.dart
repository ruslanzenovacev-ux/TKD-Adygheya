import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../offline_marks.dart';
import '../../widgets/common.dart';
import '../parent/child_screen.dart';

/// Занятие: список группы за день, тап по ребёнку — отметить/снять отметку.
/// Работает без интернета: отметки копятся в телефоне и отправляются, когда появится связь.
class RosterScreen extends StatefulWidget {
  const RosterScreen({super.key, required this.group, required this.user});

  final Group group;
  final UserInfo user;

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> with WidgetsBindingObserver {
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  List<Child> _children = [];
  List<PendingMark> _pending = [];
  bool _loading = true;
  bool _fromCache = false;
  String? _error;
  Timer? _retry;

  String get _date => isoDate(_day);
  String get _cacheKey => 'roster:${widget.group.id}:$_date';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Пока экран открыт, раз в 30 секунд пробуем отправить накопленные отметки.
    _retry = Timer.periodic(const Duration(seconds: 30), (_) => _syncSilently());
  }

  @override
  void dispose() {
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncSilently();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _children.isEmpty;
      _error = null;
    });
    await _sync(showResult: false);
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic>? data;
    var fromCache = false;
    try {
      data = Map<String, dynamic>.from(
        await Api.instance.get('/groups/${widget.group.id}/roster', query: {'date': _date}) as Map,
      );
      await prefs.setString(_cacheKey, jsonEncode(data));
    } on ApiException catch (e) {
      final cached = prefs.getString(_cacheKey) ?? prefs.getString('roster:${widget.group.id}:last');
      if (e.isOffline && cached != null) {
        data = Map<String, dynamic>.from(jsonDecode(cached) as Map);
        fromCache = true;
      } else {
        _error = e.message;
      }
    }
    if (data != null) {
      // Последний загруженный список — на случай, если завтра в зале не будет связи.
      await prefs.setString('roster:${widget.group.id}:last', jsonEncode({...data, 'children': [for (final c in data['children'] as List) {...Map<String, dynamic>.from(c as Map), 'mark': null}]}));
    }
    final pending = await OfflineMarks.instance.forGroupDate(widget.group.id, _date);
    if (!mounted) return;
    setState(() {
      if (data != null) {
        _children = [for (final e in data['children'] as List) Child.fromJson(Map<String, dynamic>.from(e as Map))];
      }
      _pending = pending;
      _fromCache = fromCache;
      _loading = false;
    });
  }

  Future<void> _syncSilently() => _sync(showResult: false).then((sent) {
        if (sent > 0) _load();
      });

  /// Возвращает число отправленных отметок.
  Future<int> _sync({bool showResult = true}) async {
    try {
      final r = await OfflineMarks.instance.sync();
      if (mounted) {
        if (r.errors.isNotEmpty) showMessage(context, r.errors.toSet().join('\n'), error: true);
        if (showResult && r.offline) showMessage(context, 'Нет связи. Отметки сохранены и уйдут позже');
        final pending = await OfflineMarks.instance.forGroupDate(widget.group.id, _date);
        if (mounted) setState(() => _pending = pending);
      }
      return r.sent;
    } catch (e) {
      if (mounted && showResult) showMessage(context, errorText(e), error: true);
      return 0;
    }
  }

  bool _isPending(Child c) => _pending.any((m) => m.childId == c.id);

  Future<void> _toggle(Child c) async {
    if (c.isPending) {
      showMessage(context, 'Сначала подтвердите спортсмена', error: true);
      return;
    }
    if (_isPending(c)) {
      await OfflineMarks.instance.remove(c.id, _date);
      final pending = await OfflineMarks.instance.forGroupDate(widget.group.id, _date);
      setState(() => _pending = pending);
      return;
    }
    if (c.markId != null) {
      if (!await confirm(context, 'Снять отметку?', text: '${c.name}, ${dateRu(_date)}. Занятие вернётся на баланс.', ok: 'Снять')) return;
      if (!mounted) return;
      final ok = await runAction(context, () => Api.instance.post('/attendance/${c.markId}/cancel'));
      if (ok != null) _load();
      return;
    }
    await OfflineMarks.instance.add(childId: c.id, groupId: widget.group.id, date: _date);
    final pending = await OfflineMarks.instance.forGroupDate(widget.group.id, _date);
    setState(() => _pending = pending);
    final sent = await _sync(showResult: false);
    if (sent > 0) _load();
  }

  Future<void> _approve(Child c) async {
    final ok = await runAction(context, () => Api.instance.post('/children/${c.id}/approve'), success: '${c.name} подтверждён');
    if (ok != null) _load();
  }

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateUtils.dateOnly(DateTime.now()))) return;
    setState(() {
      _day = next;
      _children = [];
    });
    _load();
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: now.subtract(const Duration(days: 31)),
      lastDate: now,
    );
    if (d == null) return;
    setState(() {
      _day = DateUtils.dateOnly(d);
      _children = [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.isSameDay(_day, DateTime.now());
    final marked = _children.where((c) => c.markId != null || _isPending(c)).length;
    final active = _children.where((c) => !c.isPending).toList();
    final pendingApproval = _children.where((c) => c.isPending).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _shiftDay(-1), icon: const Icon(Icons.chevron_left)),
            TextButton.icon(
              onPressed: _pickDay,
              icon: const Icon(Icons.event),
              label: Text('${today ? 'Сегодня, ' : ''}${weekdayRu(_day)} ${dateRu(_date)}'),
            ),
            IconButton(onPressed: today ? null : () => _shiftDay(1), icon: const Icon(Icons.chevron_right)),
          ]),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  if (_error != null && _children.isEmpty)
                    Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
                  if (_fromCache)
                    const _Banner(icon: Icons.cloud_off, text: 'Нет связи: показан сохранённый список. Отметки отправятся автоматически'),
                  if (_pending.isNotEmpty)
                    _Banner(
                      icon: Icons.schedule_send,
                      text: 'Не отправлено: ${_pending.length}',
                      action: TextButton(onPressed: () => _sync().then((s) => s > 0 ? _load() : null), child: const Text('Отправить')),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Отмечено: $marked из ${active.length}. Нажмите на спортсмена, чтобы отметить.'),
                  ),
                  for (final c in active) _row(c),
                  if (pendingApproval.isNotEmpty) ...[
                    const SectionTitle('Новички — ждут подтверждения'),
                    for (final c in pendingApproval)
                      ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person_add)),
                        title: Text(c.name),
                        subtitle: Text(c.birthDate == null ? 'Добавлен родителем' : 'Дата рождения: ${dateRu(c.birthDate)}'),
                        trailing: FilledButton.tonal(onPressed: () => _approve(c), child: const Text('Подтвердить')),
                      ),
                  ],
                  if (_children.isEmpty && _error == null)
                    const Padding(padding: EdgeInsets.all(24), child: Text('В группе пока нет спортсменов', textAlign: TextAlign.center)),
                ],
              ),
            ),
    );
  }

  Widget _row(Child c) {
    final pending = _isPending(c);
    final present = c.markId != null || pending;
    final scheme = Theme.of(context).colorScheme;
    // Остаток с учётом ещё не отправленной отметки.
    final balance = pending ? c.balance - 1 : c.balance;
    String sub;
    if (pending) {
      sub = 'Отмечен · ждёт отправки';
    } else if (c.markId != null) {
      sub = c.markDebt ? 'Отмечен · в долг' : 'Отмечен';
    } else if (balance <= 0) {
      sub = balance < 0 ? 'Долг: ${lessons(-balance)}' : 'Занятия закончились';
    } else {
      sub = 'Осталось ${lessons(balance)}';
    }
    return ListTile(
      onTap: () => _toggle(c),
      onLongPress: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChildScreen(childId: c.id, user: widget.user))),
      leading: Icon(
        present ? Icons.check_circle : Icons.radio_button_unchecked,
        color: present ? (pending ? scheme.tertiary : scheme.primary) : scheme.outline,
        size: 32,
      ),
      title: Text(c.name),
      subtitle: Text(sub),
      trailing: BalanceBadge(balance: balance),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
          if (action != null) action!,
        ]),
      );
}
