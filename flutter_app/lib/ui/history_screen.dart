import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/month_picture.dart';
import 'common.dart';
import 'summary_screen.dart';

/// The saved months: the actual net against the estimate, and what was left at the end of each month —
/// port of HistoryView.swift.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final file = store.file;
      final history = file.history..sort((a, b) => b.sortKey.compareTo(a.sortKey));
      final theme = Theme.of(context);
      if (history.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.event_note, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('אין חודשים רשומים', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('כשמגיע התלוש — רשום כמה נטו נכנס בפועל. התחזית תתבסס על הממוצע של החודשים האחרונים.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => showSaveMonth(context), child: const Text('רשום חודש')),
            ]),
          ),
        );
      }
      final results = {for (final r in history) r.id: monthResult(file, r)};
      final actuals = history.map((r) => r.actualNet).whereType<double>().toList();
      Budget budgetOf(MonthRecord r) => Budget(JObj(r.json['budget'] as Json? ?? {}));
      final averageNet = actuals.isNotEmpty
          ? actuals.reduce((a, b) => a + b) / actuals.length
          : history.fold(0.0, (s, r) => s + budgetOf(r).net) / history.length;
      final averageRemaining = results.values.fold(0.0, (s, p) => s + p.remaining) / results.length;
      final chartRecords = history.take(12).toList().reversed.toList();
      final tiles = [
        _Tile(actuals.isEmpty ? 'נטו ממוצע (משוער)' : 'נטו ממוצע בפועל', Fmt.money(averageNet), Icons.payments_outlined),
        _Tile('נשאר בממוצע בסוף חודש', Fmt.money(averageRemaining), Icons.trending_up),
        _Tile('חודשים שמורים', '${history.length}', Icons.calendar_month),
      ];
      final chart = SectionCard(title: 'מגמה — 12 החודשים האחרונים', children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          child: _HistoryChart(
            records: chartRecords,
            net: (r) => r.actualNet ?? budgetOf(r).net,
            remaining: (r) => results[r.id]!.remaining,
          ),
        ),
      ]);
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'save-month',
          icon: const Icon(Icons.event_available),
          label: const Text('רשום חודש'),
          onPressed: () => showSaveMonth(context),
        ),
        body: PageList(children: [
          Text('הנטו שנכנס בפועל בכל חודש, מול ההערכה', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          if (isWide(context))
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: chart),
              const SizedBox(width: 12),
              SizedBox(width: 230, child: Column(children: tiles)),
            ])
          else ...[
            chart,
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final t in tiles) SizedBox(width: (MediaQuery.sizeOf(context).width - 42) / 2, child: t),
            ]),
            const SizedBox(height: 12),
          ],
          SectionCard(title: 'חודשים', children: [
            for (final r in history)
              () {
                final remaining = results[r.id]!.remaining;
                final b = budgetOf(r);
                return ListTile(
                  title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text([
                    'ברוטו ${Fmt.money(b.gross)}',
                    if (r.actualNet != null) 'בפועל ${Fmt.money(r.actualNet!)}',
                    'משוער ${Fmt.money(b.net)}',
                    if (r.note.isNotEmpty) r.note,
                  ].join(' · ')),
                  trailing: Text('נשאר ${Fmt.money(remaining)}',
                      textDirection: TextDirection.rtl,
                      style: TextStyle(color: remaining >= 0 ? Colors.green.shade700 : theme.colorScheme.error)),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RecordDetailScreen(recordId: r.id))),
                );
              }(),
            const EmptyHint('״נשאר״ = מה שנשאר בעו״ש בסוף החודש — אותו חישוב כמו ״נשאר בסוף החודש״ בסיכום: הנטו (בפועל אם '
                'נרשם, אחרת משוער), פחות הוצאות קבועות, רכישות תקופתיות, חיובי אשראי משתנים והעברות לחיסכון, ועם תנועות '
                'חד-פעמיות. לחיצה על חודש מציגה את הפירוט.'),
          ]),
        ]),
      );
    });
  }
}

extension on MonthRecord {
  String get title => Fmt.monthTitle(year, month);
  String get shortTitle => '$month/${year % 100}';
}

class _Tile extends StatelessWidget {
  const _Tile(this.title, this.value, this.icon);
  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.labelSmall),
              Text(value, textDirection: TextDirection.rtl, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _HistoryChart extends StatelessWidget {
  const _HistoryChart({required this.records, required this.net, required this.remaining});
  final List<MonthRecord> records;
  final double Function(MonthRecord) net;
  final double Function(MonthRecord) remaining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var minY = 0.0, maxY = 0.0;
    for (final r in records) {
      minY = math.min(minY, math.min(net(r), remaining(r)));
      maxY = math.max(maxY, math.max(net(r), remaining(r)));
    }
    return Column(children: [
      Wrap(spacing: 12, children: [
        for (final (label, color) in [('נטו', Colors.blue), ('נשאר בסוף החודש', Colors.green)])
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, color: color),
            const SizedBox(width: 4),
            Text(label, style: theme.textTheme.labelSmall),
          ]),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 220,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BarChart(BarChartData(
            minY: minY,
            maxY: maxY == minY ? minY + 1 : maxY * 1.1,
            gridData: const FlGridData(drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 48,
                  getTitlesWidget: (v, _) => Text(v.abs() >= 1000 ? '${(v / 1000).toStringAsFixed(1)}K' : '${v.round()}',
                      style: theme.textTheme.labelSmall),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (v, _) {
                    final i = v.round();
                    return i < 0 || i >= records.length
                        ? const SizedBox.shrink()
                        : Text(records[i].shortTitle, style: theme.textTheme.labelSmall);
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, rod, rodIndex) => BarTooltipItem(
                  '${rodIndex == 0 ? 'נטו' : 'נשאר'}: ${Fmt.money(rod.toY)}',
                  const TextStyle(color: Colors.white, fontSize: 12),
                  textDirection: TextDirection.rtl,
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < records.length; i++)
                BarChartGroupData(x: i, barsSpace: 3, barRods: [
                  BarChartRodData(toY: net(records[i]), color: Colors.blue, width: 9),
                  BarChartRodData(toY: remaining(records[i]), color: Colors.green, width: 9),
                ]),
            ],
          )),
        ),
      ),
    ]);
  }
}

/// One saved month: what was left, the payslip, and "load as current" / delete — RecordDetailView in Swift.
class RecordDetailScreen extends StatelessWidget {
  const RecordDetailScreen({super.key, required this.recordId});
  final String recordId;

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final record = store.file.history.where((r) => r.id == recordId).firstOrNull;
      if (record == null) return const Scaffold(body: Center(child: Text('החודש נמחק')));
      final MonthPicture pic = monthResult(store.file, record);
      final budget = Budget(JObj(record.json['budget'] as Json? ?? {}));
      return Scaffold(
        appBar: AppBar(title: Text(record.title)),
        body: PageList(children: [
          if (record.note.isNotEmpty) SectionCard(title: 'הערה', children: [EmptyHint(record.note)]),
          SectionCard(
            title: 'מה נשאר בסוף החודש',
            subtitle: 'אותו חישוב כמו בסיכום, עם ההכנסות, הניכויים וההוצאות הקבועות של החודש הזה, וחיובי האשראי והתנועות שלו.',
            children: monthBreakdown(context, pic),
          ),
          SectionCard(title: 'מהברוטו לנטו (לפי התלוש של החודש)', children: payslipBreakdown(context, budget)),
          SectionCard(children: [
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('טען כנתונים הנוכחיים'),
              subtitle: const Text('מחליף את ההכנסות, הניכויים וההוצאות הנוכחיים בנתונים של החודש הזה.'),
              onTap: () async {
                if (await confirm(context, 'להחליף את הנתונים הנוכחיים?', 'ההכנסות, הניכויים וההוצאות יוחלפו בנתונים של ${record.title}.',
                        ok: 'טען', danger: false) &&
                    context.mounted) {
                  store.edit((f) => loadIntoCurrent(f, record));
                  Navigator.pop(context);
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('מחק חודש', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                if (await confirm(context, 'למחוק את החודש?', 'אי אפשר לבטל את זה.', ok: 'מחק') && context.mounted) {
                  store.edit((f) => JObj(f.json).removeWhere('history', (r) => r['id'] == record.id));
                  Navigator.pop(context);
                }
              },
            ),
          ]),
        ]),
      );
    });
  }
}

/// Port of `Store.loadIntoCurrent`: the month's incomes, deductions and expenses become the current ones,
/// keeping today's purchase tracking and tax rates.
void loadIntoCurrent(SaveFile f, MonthRecord record) {
  final restored = deepCopy(record.json['budget']) as Json;
  final current = f.json['budget'] as Json? ?? {};
  for (final k in ['trackedItems', 'rates']) {
    if (current.containsKey(k)) {
      restored[k] = current[k];
    } else {
      restored.remove(k);
    }
  }
  f.json['budget'] = restored;
}
