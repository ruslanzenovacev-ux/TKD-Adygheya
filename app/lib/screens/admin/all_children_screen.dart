import 'package:flutter/material.dart';

import '../../api.dart';
import '../../format.dart';
import '../../models.dart';
import '../../widgets/common.dart';
import '../parent/child_screen.dart';

/// Все спортсмены секции с поиском и фильтрами.
class AllChildrenScreen extends StatefulWidget {
  const AllChildrenScreen({super.key, required this.user});
  final UserInfo user;

  @override
  State<AllChildrenScreen> createState() => _AllChildrenScreenState();
}

enum _Filter { all, low, pending, archived }

class _AllChildrenScreenState extends State<AllChildrenScreen> {
  final _loader = GlobalKey<LoaderState<List<Child>>>();
  String _query = '';
  _Filter _filter = _Filter.all;

  Future<List<Child>> _load() async {
    final list = await Api.instance.get('/children', query: _filter == _Filter.archived ? {'status': 'archived'} : null) as List;
    return [for (final e in list) Child.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  List<Child> _apply(List<Child> all) {
    final q = _query.trim().toLowerCase();
    return all.where((c) {
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q) && !(c.groupName ?? '').toLowerCase().contains(q)) return false;
      return switch (_filter) {
        _Filter.low => !c.isPending && c.balance <= 1,
        _Filter.pending => c.isPending,
        _Filter.all || _Filter.archived => true,
      };
    }).toList();
  }

  void _setFilter(_Filter f) {
    final reload = (f == _Filter.archived) != (_filter == _Filter.archived);
    setState(() => _filter = f);
    if (reload) _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Все спортсмены')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Имя или группа', border: OutlineInputBorder(), isDense: true),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            for (final (f, label) in [
              (_Filter.all, 'Все'),
              (_Filter.low, 'Заканчиваются'),
              (_Filter.pending, 'Новички'),
              (_Filter.archived, 'Архив'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(label), selected: _filter == f, onSelected: (_) => _setFilter(f)),
              ),
          ]),
        ),
        Expanded(
          child: Loader<List<Child>>(
            key: _loader,
            load: _load,
            builder: (context, all, reload) {
              final list = _apply(all);
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Найдено: ${list.length}', style: Theme.of(context).textTheme.bodySmall),
                  ),
                  for (final c in list)
                    ListTile(
                      leading: BalanceBadge(balance: c.balance),
                      title: Text(c.name),
                      subtitle: Text('${c.groupName ?? 'Без группы'}${c.isPending ? ' · ждёт подтверждения' : ''}'
                          '${c.nextExpiryDate != null ? ' · до ${dateRu(c.nextExpiryDate)}' : ''}'),
                      onTap: () async {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => ChildScreen(childId: c.id, user: widget.user)));
                        reload();
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ]),
    );
  }
}
