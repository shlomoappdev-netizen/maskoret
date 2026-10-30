import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../data/card.dart';
import '../data/fmt.dart';
import '../data/forecast.dart';
import '../data/models.dart';
import 'common.dart';
import 'family_screen.dart';
import 'theme.dart';

/// The forecast — port of ForecastView.swift.
class ForecastScreen extends StatelessWidget {
  const ForecastScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final file = store.dashboard;
      final settings = ForecastSettings.of(store.file);
      final months = Forecaster.run(file, months: settings.months);
      final theme = Theme.of(context);
      final first = months.first, last = months.last;
      final change = last.liquid - first.liquid;
      final lowest = months.reduce((a, b) => b.checking < a.checking ? b : a);
      final expected = Forecaster.expectedNet(file.budget, file.history, settings);
      final next = months.length > 1 ? months[1] : null;
      final hasPension = file.money.accounts.any((a) => a.kind == AccountKind.pension);
      final hasCards = CardData(file.money).cardTransactions.isNotEmpty;

      final tiles = <(String, String, IconData)>[
        ('עו״ש + חיסכון בעוד ${last.index} חודשים', Fmt.money(last.liquid), Icons.trending_up),
        ('שינוי בתקופה', '${change >= 0 ? '+' : '−'}${Fmt.money(change.abs())}', change >= 0 ? Icons.north_east : Icons.south_east),
        ('עו״ש צפוי', Fmt.money(last.checking), Icons.credit_card),
        ('חיסכון ופיקדונות צפויים', Fmt.money(last.savings), Icons.lock_outline),
        (
          'נקודת השפל בעו״ש',
          '${Fmt.money(lowest.checking)}${lowest.index == 0 ? ' (היום)' : ' · ${lowest.shortLabel}'}',
          lowest.checking < 0 ? Icons.warning_amber : Icons.vertical_align_bottom
        ),
        ('פנסיה צפויה', Fmt.money(last.pension), Icons.beach_access_outlined),
      ];

      return PageList(children: [
        const FamilyContextLine(),
        Text('לאן הכסף שלך הולך בחודשים הקרובים', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 3, label: Text('3 חודשים')),
            ButtonSegment(value: 6, label: Text('6 חודשים')),
            ButtonSegment(value: 12, label: Text('12 חודשים')),
            ButtonSegment(value: 24, label: Text('24 חודשים')),
          ],
          selected: {settings.months},
          onSelectionChanged: (s) => store.edit((f) => ForecastSettings.of(f).months = s.first),
        ),
        const SizedBox(height: 12),
        TileGrid(minWidth: 130, children: [
          for (final (title, value, icon) in tiles) StatTile(title: title, value: value, icon: icon),
        ]),
        const SizedBox(height: 12),
        if (lowest.checking < 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'לפי התחזית העו״ש ייכנס למינוס ב${lowest.label}. כדאי לבדוק הוצאות גדולות מתוכננות או להעביר כסף מהחיסכון.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        SectionCard(title: 'התחזית חודש אחרי חודש', children: [
          Padding(padding: const EdgeInsets.fromLTRB(8, 8, 16, 8), child: _Chart(months: months, hasPension: hasPension)),
        ]),
        SectionCard(
          title: 'על מה התחזית מבוססת',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Text('בסיס ההכנסה: '),
                DropdownButton<IncomeBasis>(
                  value: settings.basis,
                  items: [for (final b in IncomeBasis.values) DropdownMenuItem(value: b, child: Text(b.title))],
                  onChanged: (v) => store.edit((f) => ForecastSettings.of(f).basis = v!),
                ),
              ]),
            ),
            if (settings.basis == IncomeBasis.manual)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: NumberField(
                  label: 'נטו חודשי צפוי',
                  suffix: '₪',
                  value: settings.manualNet,
                  onChanged: (v) => store.edit((f) => ForecastSettings.of(f).manualNet = v),
                ),
              ),
            _Line('הכנסה נטו בחודש', '${Fmt.money(expected.amount)} — ${expected.source}'),
            _Line('הוצאות קבועות ורכישות תקופתיות', '−${Fmt.money((next?.spending ?? 0) - (next?.card ?? 0))}'),
            if (last.card > 0)
              _Line('כרטיס אשראי — הוצאות משתנות',
                  '−${Fmt.money(last.card)}${hasCards ? ' — ממוצע 3 החיובים האחרונים (חודש עם חיוב מיובא — לפי הקובץ)' : ''}'),
            _Line('העברות קבועות לחיסכון', Fmt.money(next?.toSavings ?? 0)),
            _Line('נשאר בעו״ש בכל חודש', Fmt.money(expected.amount - (next?.spending ?? 0) - (next?.toSavings ?? 0))),
            const EmptyHint('ריבית בפיקדונות מחושבת לפי התנאים שהזנת, פיקדון שמגיע לפירעון חוזר לעו״ש (אחרי מס), ותנועות מתוכננות '
                'נכנסות בחודש שלהן. כדי שהוצאה קבועה (למשל ״חיסכון״) תיכנס לחשבון חיסכון במקום להיעלם — בחר לה חשבון יעד בעריכת ההוצאה.'),
          ],
        ),
        SectionCard(title: 'פירוט לפי חודש', children: [
          for (final m in months)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(m.index == 0 ? 'היום' : m.label, style: const TextStyle(fontWeight: FontWeight.w500))),
                  Text(Fmt.money(m.liquid), textDirection: TextDirection.rtl, style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                Text.rich(
                  TextSpan(style: theme.textTheme.bodySmall, children: [
                    const TextSpan(text: 'עו״ש '),
                    TextSpan(text: Fmt.money(m.checking), style: TextStyle(color: m.checking < 0 ? theme.colorScheme.error : null)),
                    TextSpan(text: ' · חיסכון ${Fmt.money(m.savings)}'),
                  ]),
                ),
                if (m.events.isNotEmpty) Text(m.events.join(' · '), style: theme.textTheme.bodySmall),
              ]),
            ),
        ]),
      ]);
    });
  }
}

class _Line extends StatelessWidget {
  const _Line(this.title, this.value);
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 2, child: Text(title)),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: Text(value, textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodyMedium)),
        ]),
      );
}

class _Chart extends StatelessWidget {
  const _Chart({required this.months, required this.hasPension});
  final List<ForecastMonth> months;
  final bool hasPension;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final series = <(String, Color, double Function(ForecastMonth), bool)>[
      ('עו״ש', Colors.blue, (m) => m.checking, false),
      ('חיסכון ופיקדונות', Colors.green, (m) => m.savings, false),
      ('סה״כ', theme.colorScheme.primary, (m) => m.liquid, false),
      if (hasPension) ('פנסיה', Colors.purple, (m) => m.pension, true),
    ];
    var minY = 0.0, maxY = 0.0;
    for (final m in months) {
      for (final s in series) {
        minY = math.min(minY, s.$3(m));
        maxY = math.max(maxY, s.$3(m));
      }
    }
    final step = (months.length / 6).ceil().clamp(1, 12);
    return Column(children: [
      Wrap(spacing: 12, children: [
        for (final s in series)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 12, height: 3, color: s.$2),
            const SizedBox(width: 4),
            Text(s.$1, style: theme.textTheme.labelSmall),
          ]),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 260,
        // The chart's x axis reads left to right (time), also in Hebrew.
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: LineChart(LineChartData(
            minY: minY,
            maxY: maxY == minY ? minY + 1 : maxY * 1.05,
            gridData: const FlGridData(drawVerticalLine: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 52,
                  getTitlesWidget: (v, meta) => Text(_compact(v), style: theme.textTheme.labelSmall),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: step.toDouble(),
                  getTitlesWidget: (v, meta) {
                    final i = v.round();
                    if (i < 0 || i >= months.length || i % step != 0) return const SizedBox.shrink();
                    return Text(i == 0 ? 'היום' : months[i].shortLabel, style: theme.textTheme.labelSmall);
                  },
                ),
              ),
            ),
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem('${series[s.barIndex].$1}: ${Fmt.money(s.y)}',
                        TextStyle(color: series[s.barIndex].$2, fontSize: 12), textDirection: TextDirection.rtl),
                ],
              ),
            ),
            lineBarsData: [
              for (final s in series)
                LineChartBarData(
                  spots: [for (final m in months) FlSpot(m.index.toDouble(), s.$3(m))],
                  color: s.$2,
                  barWidth: s.$1 == 'סה״כ' ? 3 : 2,
                  isCurved: true,
                  preventCurveOverShooting: true,
                  dashArray: s.$4 ? [4, 4] : null,
                  dotData: FlDotData(show: months.length <= 13),
                ),
            ],
          )),
        ),
      ),
    ]);
  }

  static String _compact(double v) {
    final a = v.abs();
    final sign = v < 0 ? '−' : '';
    if (a >= 1000000) return '$sign${(a / 1000000).toStringAsFixed(1)}M';
    if (a >= 1000) return '$sign${(a / 1000).toStringAsFixed(a >= 10000 ? 0 : 1)}K';
    return '$sign${a.round()}';
  }
}
