import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../data/fmt.dart';
import '../data/forecast.dart';
import '../data/json.dart';
import '../data/card.dart';
import '../data/maaser.dart';
import '../data/max_import.dart';
import '../data/receivables.dart';
import '../data/models.dart';
import '../data/money_calc.dart';
import '../data/month_picture.dart';
import '../data/payslip.dart';
import '../data/trends.dart';
import '../state/store.dart';
import '../support/app_log.dart';
import '../support/payslip_pdf.dart';
import 'app_prompts.dart';
import 'common.dart';
import 'family_screen.dart';
import 'home_shell.dart';
import 'theme.dart';

/// The current month: what's left, where the net goes, the money now — the same layout as SummaryView.swift.
class SummaryScreen extends StatelessWidget {
  const SummaryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MonthPicture.hideCardEstimate,
      builder: (context, _) => StoreBuilder(builder: _build),
    );
  }

  Widget _build(BuildContext context, AppStore store) {
    {
      final d = store.dashboard;
      final b = d.budget;
      final money = d.money;
      final calc = MoneyCalc(money.primeRate);
      final now = DateTime.now();
      // The same number as "נשאר מההכנסה האחרונה" in the iPhone/Mac app.
      final pic = MonthPicture.current(d);
      final members = store.members;
      final wide = isWide(context);
      final checking = calc.total(money, {AccountKind.checking}, budget: b, history: d.history);
      final savings = calc.total(money, {AccountKind.savings, AccountKind.deposit}, budget: b, history: d.history);
      final forecast = Forecaster.run(d, months: ForecastSettings.of(store.file).months);
      final last = forecast.last;

      final hide = MonthPicture.hideCardEstimate.value;
      // The switch shows only when there's an estimate to hide (or it's already hidden).
      final hero = _Hero(pic: pic, hideEstimate: hide, showSwitch: hide || MonthPicture.currentFull(d).cardEstimated);
      final donut = pic.net > 0 ? _NetDonut(pic: pic, money: d.money) : null;
      final breakdown = SectionCard(title: 'החודש — מהנטו ועד מה שנשאר', children: monthBreakdown(context, pic));
      final payslip = b.gross > 0
          ? SectionCard(title: 'מהברוטו לנטו (הערכה לפי התלוש)', children: payslipBreakdown(context, b))
          : null;
      final stats = _StatsGrid(pic: pic, budget: b);

      return PageList(lazy: false, children: [
        const AnnouncementCard(),
        const FamilyContextLine(),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('בית — ${pic.periodTitle}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            icon: const Icon(Icons.event_available, size: 18),
            label: Text(pic.isActual ? 'עדכן נטו בפועל' : 'רשום נטו בפועל'),
            onPressed: () => showSaveMonth(context),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('העתק סיכום'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _shareText(pic, checking, savings)));
              showMessage(context, 'הסיכום הועתק');
            },
          ),
        ]),
        const SizedBox(height: 14),
        // One under the other (4.17.0): the bar of "לאן הולך הנטו" needs the width.
        hero,
        if (donut != null) ...[const SizedBox(height: 14), donut],
        const SizedBox(height: 14),
        _Todos(pic: pic, money: money),
        const SizedBox(height: 14),
        TileGrid(minWidth: 130, children: [
          StatTile(title: 'עו״ש עכשיו (משוער)', value: Fmt.money(checking), icon: Icons.credit_card),
          StatTile(title: 'חיסכון ופיקדונות', value: Fmt.money(savings), icon: Icons.lock_outline),
          StatTile(title: 'בעוד ${last.index} חודשים (עו״ש + חיסכון)', value: Fmt.money(last.liquid), icon: Icons.trending_up),
          StatTile(title: 'פנסיה', value: Fmt.money(calc.total(money, {AccountKind.pension}, budget: b, history: d.history)), icon: Icons.beach_access_outlined),
        ]),
        const SizedBox(height: 14),
        // Everything else, folded by default (the choice is remembered).
        _Details(children: [
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Column(children: [breakdown, ?payslip])),
              const SizedBox(width: 14),
              SizedBox(width: 340, child: stats),
            ])
          else ...[
            breakdown,
            ?payslip,
            stats,
          ],
          if (members.length > 1)
            SectionCard(title: 'נטו לפי בן משפחה', subtitle: 'כל אחד לפי התלוש שלו', children: [
              for (final m in members) AmountRow(m.title, store.family.file(m.id)?.budget.net ?? 0),
            ]),
        ]),
      ]);
    }
  }

  static String _shareText(MonthPicture p, double checking, double savings) {
    String m(double v) => Fmt.money((v * 100).round() / 100);
    final lines = ['סיכום ${p.title} — מחשבון שכר', ''];
    lines.add('${p.isActual ? 'נטו בפועל: ' : 'נטו (משוער): '}${m(p.net)}');
    for (final l in p.spending) {
      lines.add('  − ${l.title}: ${Fmt.money(l.amount)}');
    }
    if (p.periodic > 0) lines.add('  − רכישות תקופתיות: ${m(p.periodic)}');
    for (final l in p.card) {
      lines.add('  − 💳 ${l.title}: ${m(l.amount)}');
    }
    for (final l in p.installments) {
      lines.add('  − 🗓 ${l.title}: ${m(l.amount)} (${l.detail})');
    }
    for (final l in p.toSavings) {
      lines.add('  → ${l.title}: ${Fmt.money(l.amount)}');
    }
    for (final l in p.oneOffs) {
      lines.add('  ± ${l.title}: ${Fmt.money(l.amount)}');
    }
    lines
      ..add('')
      ..add('נשאר בפועל מההכנסה האחרונה: ${m(p.remainingActual)}')
      ..add('צפוי להישאר אחרי חיוב האשראי (לפי ממוצע): ${m(p.remaining)}')
      ..add('עו״ש עכשיו (משוער): ${Fmt.money(checking)}')
      ..add('חיסכון ופיקדונות: ${Fmt.money(savings)}');
    return lines.join('\n');
  }
}

/// "מה מחכה לך": what's left to do this month, each line opens where it's done (todos in SummaryView.swift).
class _Todos extends StatelessWidget {
  const _Todos({required this.pic, required this.money});
  final MonthPicture pic;
  final MoneyData money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final todos = <(IconData, String, VoidCallback)>[
      if (CardData(money).importDue())
        (Icons.file_download_outlined, 'לייבא את קובץ האשראי של החודש', () => openDest(context, Dest.card)),
      if (!pic.isActual)
        (Icons.document_scanner_outlined, 'לרשום כמה נכנס בפועל החודש (אפשר מקובץ התלוש)', () => showSaveMonth(context)),
      ...() {
        final last = money.checking?.latestBalance;
        if (last == null) {
          return [(Icons.account_balance_outlined, 'להקליד את יתרת העו״ש — ממנה הכול מחושב', () => openDest(context, Dest.accounts))];
        }
        final days = DateTime.now().difference(last.date).inSeconds ~/ 86400;
        return [
          if (days > 30)
            (Icons.account_balance_outlined, 'לעדכן את יתרת העו״ש — עברו $days ימים מהעדכון האחרון',
                () => openDest(context, Dest.accounts)),
        ];
      }(),
      if (pic.fixedInCardSuspects.isNotEmpty)
        (Icons.warning_amber_rounded, 'ייתכן שנספר פעמיים: ${pic.fixedInCardSuspects.join(', ')}', () => openDest(context, Dest.card)),
    ];
    if (todos.isEmpty) {
      return Glass(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          const Icon(Icons.check_circle, color: AppColors.green),
          const SizedBox(width: 8),
          Expanded(child: Text('הכול מעודכן — אין מה לעשות כרגע', style: TextStyle(color: AppColors.positive(context)))),
        ]),
      );
    }
    return SectionCard(title: 'מה מחכה לך', children: [
      for (final (icon, text, action) in todos)
        ListTile(
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(text),
          trailing: Icon(Icons.chevron_left, color: theme.colorScheme.onSurfaceVariant),
          onTap: action,
        ),
    ]);
  }
}

/// "פרטים נוספים — מהנטו ועד מה שנשאר, ומספרים על החודש", folded by default; open or closed is remembered.
class _Details extends StatefulWidget {
  const _Details({required this.children});
  final List<Widget> children;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  static const _key = 'summaryShowDetails';

  @override
  Widget build(BuildContext context) {
    final prefs = context.scope.prefs;
    final open = prefs.getBool(_key) ?? false;
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => prefs.setBool(_key, !open)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(children: [
            Icon(open ? Icons.expand_more : Icons.chevron_left, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('פרטים נוספים — מהנטו ועד מה שנשאר, ומספרים על החודש',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
      if (open) ...[const SizedBox(height: 6), ...widget.children],
    ]);
  }
}

/// "נשאר לך מההכנסה האחרונה" on the teal → blue gradient (red when negative), with three small numbers under it.
class _Hero extends StatelessWidget {
  const _Hero({required this.pic, required this.hideEstimate, required this.showSwitch});
  final MonthPicture pic;

  /// "כולל הערכת הוצאות באשראי" switched off: only what actually went out.
  final bool hideEstimate;
  final bool showSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positive = pic.remaining >= 0;
    Widget mini(String title, double value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.75))),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(Fmt.money(value),
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: tabular)),
            ),
          ]),
        );
    // Both big numbers side by side and the same size: what's left now, and what's expected after the card.
    // One font size for both, shrunk so the longer one fits.
    TextStyle bigStyle(double size) => theme.textTheme.displayMedium!
        .copyWith(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size, fontFeatures: tabular, height: 1.1);
    Widget big(String title, String value, double size, {String? note}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                maxLines: 2,
                style: theme.textTheme.titleSmall?.copyWith(color: Colors.white.withValues(alpha: 0.85), fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(value, textDirection: TextDirection.rtl, maxLines: 1, softWrap: false, style: bigStyle(size)),
            if (note != null)
              Text(note, style: theme.textTheme.labelSmall?.copyWith(color: Colors.white.withValues(alpha: 0.75))),
          ]),
        );
    final actual = Fmt.money(pic.remainingActual), expected = Fmt.money(pic.remaining);
    final numbers = LayoutBuilder(builder: (context, c) {
      const gap = 16.0, full = 46.0;
      double width(String v) =>
          (TextPainter(text: TextSpan(text: v, style: bigStyle(full)), textDirection: TextDirection.rtl, maxLines: 1)
                ..layout())
              .width;
      final room = hideEstimate ? c.maxWidth : (c.maxWidth - gap) / 2;
      final size = full * min(1.0, room / max(width(actual), hideEstimate ? 0 : width(expected)));
      // With the estimate switched off, only what actually went out.
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        big('נשאר בפועל מהמשכורת האחרונה', actual, size,
            note: hideEstimate ? 'רק מה שכבר ירד — בלי הערכת אשראי' : 'מה שכבר ירד עד עכשיו'),
        if (!hideEstimate) ...[
          const SizedBox(width: gap),
          big('צפוי להישאר אחרי חיוב האשראי', expected, size, note: 'לפי ממוצע החודשים הקודמים'),
        ],
      ]);
    });
    return Container(
      constraints: BoxConstraints(minHeight: isWide(context) ? 262 : 230),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: positive ? const [AppColors.teal, AppColors.blue] : const [AppColors.red1, AppColors.red2],
        ),
        boxShadow: [
          BoxShadow(
            color: (positive ? AppColors.teal : AppColors.red1).withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        numbers,
        const SizedBox(height: 26),
        Row(children: [
          mini(pic.isActual ? 'נטו בפועל' : 'נטו (משוער)', pic.net),
          const SizedBox(width: 12),
          mini('הוצאות', pic.spendingTotal + pic.periodic + pic.cardWithInstallments),
          const SizedBox(width: 12),
          mini('לחיסכון', pic.toSavingsTotal),
        ]),
        if (showSwitch) ...[
          const SizedBox(height: 16),
          Align(alignment: AlignmentDirectional.centerStart, child: _EstimateSwitch(on: !hideEstimate)),
        ],
      ]),
    );
  }
}

/// "כולל הערכת הוצאות באשראי": shows or hides the card estimate everywhere the month is shown (estimateSwitch).
/// Kept on this device only.
class _EstimateSwitch extends StatelessWidget {
  const _EstimateSwitch({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void set(bool v) {
      context.scope.prefs.setBool(MonthPicture.hideCardEstimateKey, !v);
      MonthPicture.hideCardEstimate.value = !v;
    }

    return Material(
      color: Colors.white.withValues(alpha: 0.12),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => set(!on),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 6, 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.auto_fix_high, size: 18, color: Colors.white.withValues(alpha: 0.9)),
            const SizedBox(width: 6),
            Text('כולל הערכת הוצאות באשראי',
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9), fontWeight: FontWeight.w500)),
            const SizedBox(width: 6),
            Switch(
              value: on,
              onChanged: set,
              activeThumbColor: Colors.white,
              activeTrackColor: Colors.white.withValues(alpha: 0.35),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ]),
        ),
      ),
    );
  }
}

/// The slices of "לאן הולך הנטו" (name, amount, color).
List<(String, double, Color)> netSlices(MonthPicture pic, MoneyData money) => _NetDonut._slices(pic, money);

/// "לאן הולך הנטו": one long bar split by where the net goes, and the legend under it; tapping a part (or a legend
/// line) shows what it is (chartCard and SliceBar in SummaryView.swift).
class _NetDonut extends StatefulWidget {
  const _NetDonut({required this.pic, required this.money});
  final MonthPicture pic;
  final MoneyData money;

  /// What the user's trends got in this period, biggest first (only card charges and transactions, not entries typed
  /// by hand), with how much of it came from the card and from transactions — trendSlices in SummaryView.swift.
  static ({List<(String, double, Color)> slices, double fromCard, double fromOneOffs}) _trendSlices(MonthPicture p, MoneyData money) {
    final start = p.periodStart, end = p.periodEnd;
    if (start == null || end == null) return (slices: const [], fromCard: 0, fromOneOffs: 0);
    var fromCard = 0.0, fromOneOffs = 0.0;
    final result = <(String, double)>[];
    for (final trend in JObj(money.raw).objects('trends').map(Trend.new)) {
      var total = 0.0;
      for (final item in TrendCalc.items(money, trend)) {
        if (item.date.isBefore(start) || !item.date.isBefore(end)) continue;
        switch (item.source) {
          case TrendSource.card:
            total += item.amount;
            fromCard += item.amount;
          case TrendSource.transaction:
            total += item.amount;
            fromOneOffs += item.amount;
          case TrendSource.manual:
            break;
        }
      }
      if (total > 0.005) result.add(('${trend.emoji} ${trend.name}', total));
    }
    result.sort((a, b) => b.$2.compareTo(a.$2));
    const colors = AppColors.cardCategories;
    final shown = result.take(colors.length - 1).toList();
    final slices = [for (var i = 0; i < shown.length; i++) (shown[i].$1, shown[i].$2, colors[i])];
    final rest = result.skip(shown.length).fold(0.0, (s, e) => s + e.$2);
    if (rest > 0) slices.add(('מגמות אחרות', rest, colors.last));
    return (slices: slices, fromCard: fromCard, fromOneOffs: fromOneOffs);
  }

  /// The donut's slices (slices in SummaryView.swift): the user's trends, then what's left of the card and the
  /// one-off spending outside them.
  static List<(String, double, Color)> _slices(MonthPicture pic, MoneyData money) {
    final trends = _trendSlices(pic, money);
    final cardKnown = pic.cardTotal - pic.cardEstimate;
    double atLeast0(double v) => v > 0 ? v : 0;
    return [
      ('הוצאות קבועות', pic.spendingTotal, AppColors.pink),
      ('רכישות תקופתיות', pic.periodic, AppColors.purple),
      ...trends.slices,
      (trends.slices.isEmpty ? 'כרטיס אשראי (משתנות)' : '💳 אשראי — בלי מגמה', atLeast0(cardKnown - trends.fromCard),
          AppColors.tealChart.withValues(alpha: 0.55)),
      ('💳 עוד צפוי באשראי (הערכה)', pic.cardEstimate, AppColors.gray),
      ('תשלומים (החלק של החודש)', pic.installmentsTotal, AppColors.indigo),
      ('לחיסכון', pic.toSavingsTotal, AppColors.sky),
      ('הוצאות חריגות', atLeast0(-pic.oneOffTotal - trends.fromOneOffs), AppColors.orange),
      ('נשאר', atLeast0(pic.remaining), AppColors.green),
    ].where((i) => i.$2 > 0.005).toList();
  }

  @override
  State<_NetDonut> createState() => _NetDonutState();
}

class _NetDonutState extends State<_NetDonut> {
  /// The tapped slice (its name).
  String? selected;

  void toggle(String name) => setState(() => selected = selected == name ? null : name);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pic = widget.pic, money = widget.money;
    final items = _NetDonut._slices(pic, money);
    final total = items.fold(0.0, (s, i) => s + i.$2).clamp(1.0, double.infinity);
    if (selected != null && !items.any((i) => i.$1 == selected)) selected = null;
    String pct(double v) => Fmt.percent((v / total * 100).roundToDouble());
    final chosen = items.where((i) => i.$1 == selected).firstOrNull;
    final legend = Column(mainAxisSize: MainAxisSize.min, children: [
      for (final i in items)
        Opacity(
          opacity: selected == null || selected == i.$1 ? 1 : 0.45,
          child: InkWell(
            onTap: () => toggle(i.$1),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Container(width: 9, height: 9, decoration: BoxDecoration(color: i.$3, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(i.$1, style: theme.textTheme.bodyMedium)),
                Text(Fmt.money(i.$2),
                    textDirection: TextDirection.rtl, style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
                SizedBox(
                  width: 44,
                  child: Text(pct(i.$2),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontFeatures: tabular)),
                ),
              ]),
            ),
          ),
        ),
    ]);
    return Glass(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('לאן הולך הנטו', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (JObj(money.raw).objects('trends').isNotEmpty)
          Text('המגמות שיצרת — מה ששייך להן בתקופה הזו',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        Row(children: [
          Text(pic.isActual ? 'נטו בפועל ' : 'נטו ',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text(Fmt.money(pic.net),
              textDirection: TextDirection.rtl,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular)),
        ]),
        const SizedBox(height: 8),
        SliceBar(parts: [for (final i in items) (id: i.$1, value: i.$2, color: i.$3)], selected: selected, onTap: toggle),
        if (chosen != null)
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: chosen.$3.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: chosen.$3, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(chosen.$1, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
              Text('${Fmt.money(chosen.$2)} · ${pct(chosen.$2)}',
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabular)),
            ]),
          ),
        const SizedBox(height: 12),
        legend,
      ]),
    );
  }
}

/// A horizontal bar made of parts by size (right to left in Hebrew), 2 apart; tapping a part selects it and the others
/// fade (SliceBar in SummaryView.swift).
class SliceBar extends StatelessWidget {
  const SliceBar({super.key, required this.parts, required this.selected, required this.onTap, this.height = 30});
  final List<({String id, double value, Color color})> parts;
  final String? selected;
  final ValueChanged<String> onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = max(parts.fold(0.0, (s, p) => s + p.value), 0.01);
    final outline = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8);
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Row(children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            // Each part by its share (a sliver of at least one ten-thousandth stays visible and tappable).
            Expanded(
              flex: max(1, (parts[i].value / total * 10000).round()),
              child: GestureDetector(
                onTap: () => onTap(parts[i].id),
                child: Tooltip(
                  message: parts[i].id,
                  child: Opacity(
                    opacity: selected == null || selected == parts[i].id ? 1 : 0.35,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: parts[i].color,
                        border: selected == parts[i].id ? Border.all(color: outline, width: 2) : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// The small numbers beside the breakdown (statsGrid in SummaryView.swift).
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.pic, required this.budget});
  final MonthPicture pic;
  final Budget budget;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final dash = store.dashboard;
    final owed = CardData(dash.money).totalOwedToMe(dash.money.transactions);
    // Everyone in view with their own maaser fund (familyMaaser in Swift).
    final funds = [
      for (final m in store.viewedMembers)
        if (store.family.file(m.id) case final f? when MaaserSettings(JObj((f.money.raw['maaser'] as Json?) ?? {})).enabled)
          MaaserCalc.status(f)
    ];
    final maaser = funds.isEmpty ? null : (MaaserStatus()..balance = funds.fold(0.0, (s, x) => s + x.balance));
    final now = DateTime.now();
    final daysLeft = pic.daysLeft;
    String pct(double v) => Fmt.percent((v * 1000).roundToDouble() / 10);
    final spent = pic.spendingTotal + pic.periodic + pic.cardWithInstallments;
    final diff = pic.net - pic.estimatedNet;
    final tiles = [
      StatTile(title: 'תקציב יומי ($daysLeft ימים נשארו)', value: Fmt.money(pic.remaining / daysLeft), icon: Icons.wb_sunny_outlined),
      StatTile(title: 'חיסכון מהנטו', value: pic.net > 0 ? pct(pic.toSavingsTotal / pic.net) : '—', icon: Icons.savings_outlined),
      StatTile(title: 'הוצאות מהנטו', value: pic.net > 0 ? pct(spent / pic.net) : '—', icon: Icons.bar_chart),
      if (pic.installmentsAfterThisMonth > 0.005)
        StatTile(title: 'תשלומים לחודשים הבאים', value: Fmt.money(pic.installmentsAfterThisMonth), icon: Icons.event_repeat),
      if (owed > 0.005) StatTile(title: 'חייבים לך', value: Fmt.money(owed), icon: Icons.assignment_return_outlined),
      if (maaser != null)
        StatTile(
          title: maaser.balance >= 0 ? 'חוב למעשרות' : 'זכות במעשרות',
          value: Fmt.money(maaser.balance.abs()),
          icon: Icons.volunteer_activism,
        ),
      StatTile(title: 'נשאר בשנה (בקצב הזה)', value: Fmt.money(pic.remaining * 12), icon: Icons.calendar_today),
      if (pic.isActual)
        StatTile(title: 'בפועל מול הערכה', value: '${diff >= 0 ? '+' : '−'}${Fmt.money(diff.abs())}', icon: Icons.exposure),
      if (budget.gross > 0)
        StatTile(title: 'ניכויים מהברוטו', value: pct(budget.totalDeductions / budget.gross), icon: Icons.percent),
      if (budget.totalHours > 0)
        StatTile(title: 'נטו לשעת עבודה', value: Fmt.money((pic.net / budget.totalHours * 100).roundToDouble() / 100), icon: Icons.schedule),
    ];
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: TileGrid(minWidth: 130, children: tiles));
  }
}

/// The lines of "מה נשאר מההכנסה" (MonthBreakdown in SummaryView.swift) — the summary and the months screen.
List<Widget> monthBreakdown(BuildContext context, MonthPicture pic) {
  final error = Theme.of(context).colorScheme.error;
  return [
    AmountRow(pic.isActual ? 'נטו שנכנס בפועל' : 'נטו (משוער)', pic.net, bold: true),
    if (pic.spending.isNotEmpty) ...[
      _Header('הוצאות קבועות', pic.spendingTotal),
      for (final l in pic.spending) AmountRow(l.title, l.amount, negative: true),
    ],
    if (pic.periodic > 0) AmountRow('קניות חוזרות (ממוצע לחודש)', pic.periodic, negative: true),
    if (pic.toSavings.isNotEmpty) ...[
      _Header('לחיסכון', pic.toSavingsTotal),
      for (final l in pic.toSavings) AmountRow(l.title, l.amount, negative: true),
    ],
    if (pic.card.isNotEmpty) ...[
      _Header(pic.cardEstimated ? 'כרטיס אשראי — משתנות (כולל הערכה)' : 'כרטיס אשראי — משתנות', pic.cardTotal),
      for (final l in pic.card) AmountRow(l.title, l.amount, negative: true),
    ],
    if (pic.installments.isNotEmpty) ...[
      _Header('תשלומים באשראי', pic.installmentsTotal),
      for (final l in pic.installments) AmountRow(l.title, l.amount, negative: true, detail: l.detail),
    ],
    if (pic.oneOffs.isNotEmpty) ...[
      _Header('תנועות החודש', pic.oneOffTotal),
      for (final l in pic.oneOffs) AmountRow(l.title, l.amount.abs(), negative: l.amount < 0),
    ],
    if (pic.fixedInCardSuspects.isNotEmpty)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber, size: 16, color: Colors.orange.shade700),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'ייתכן שנספר פעמיים: ${pic.fixedInCardSuspects.join(', ')} — הסכום דומה להוצאה קבועה. כדי שלא ייספר שוב, קשר את החיוב להוצאה במסך ״אשראי״.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.orange.shade800),
            ),
          ),
        ]),
      ),
    const Divider(indent: 16, endIndent: 16),
    AmountRow('נשאר מההכנסה האחרונה', pic.remaining, bold: true, color: pic.remaining >= 0 ? null : error),
    if (pic.installmentsAfterThisMonth > 0)
      AmountRow('תשלומים שנשארו לחודשים הבאים', pic.installmentsAfterThisMonth, detail: 'לא יורד החודש — מוצג לידיעה'),
  ];
}

/// "מהברוטו לנטו" of a budget (the payslip part of BudgetBreakdown).
List<Widget> payslipBreakdown(BuildContext context, Budget b) => [
      AmountRow('ברוטו', b.gross),
      for (final d in b.deductions.where((d) => d.isActive && b.deductionAmount(d) != 0))
        AmountRow(d.name, b.deductionAmount(d), negative: true, color: Theme.of(context).colorScheme.error),
      if (b.netIncomes != 0) AmountRow('הכנסות נטו (ללא ניכויים)', b.netIncomes),
      const Divider(indent: 16, endIndent: 16),
      AmountRow('נטו', b.net, bold: true),
    ];

/// What was left of a saved month's income — like Store.monthResult (the current period uses today's budget).
MonthPicture monthResult(SaveFile file, MonthRecord r) {
  final (y, m) = file.money.period(DateTime.now());
  if (r.year == y && r.month == m) return MonthPicture.of(file, r.year, r.month);
  final budget = r.json['budget'];
  return MonthPicture.of(file, r.year, r.month, budgetOverride: budget is Json ? Budget(JObj(budget)) : null);
}

/// Saving a month in the history — port of SaveMonthSheet / Store.saveMonth: a copy of the budget, the actual
/// net from the payslip, and optionally the salary into the checking account.
Future<void> showSaveMonth(BuildContext context) async {
  final store = context.store;
  final now = DateTime.now();
  var (year, month) = store.money.period(now);
  MonthRecord? existing() => store.file.history.where((r) => r.year == year && r.month == month).firstOrNull;
  var note = existing()?.note ?? '';
  double actual = existing()?.actualNet ?? 0;
  var addToChecking = true;
  var version = 0; // rebuilds the fields when another month is chosen
  PayslipReading? payslip;
  String? payslipError;
  var reading = false;
  await showEditor(
    context,
    title: 'שמירת חודש בהיסטוריה${store.members.length > 1 ? ' — ${store.activeMember?.title ?? ''}' : ''}',
    builder: (ctx, setState) {
      void pick(int y, int m) => setState(() {
            year = y;
            month = m;
            note = existing()?.note ?? '';
            actual = existing()?.actualNet ?? 0;
            version++;
          });

      /// What the payslip said: its month, the net to pay, and a note (port of readPayslip in SummaryView.swift).
      void apply(PayslipReading r) => setState(() {
            payslip = r;
            payslipError = null;
            if (r.month != null && r.year != null && r.year! >= now.year - 5 && r.year! <= now.year + 1) {
              year = r.year!;
              month = r.month!;
            }
            if (r.netToPay != null) actual = r.netToPay!;
            // The month keeps what the payslip said, in its note.
            final parts = [
              if (r.gross != null) 'ברוטו ${Fmt.money(r.gross!)}',
              if (r.deductions != null) 'ניכויים ${Fmt.money(r.deductions!)}',
              if (r.netToPay != null) 'נטו לתשלום ${Fmt.money(r.netToPay!)}',
            ];
            if (parts.isNotEmpty && (note.isEmpty || note.startsWith('מתלוש:'))) note = 'מתלוש: ${parts.join(' · ')}';
            version++;
          });

      /// Picks the PDF and reads it — with the saved password, or one the user types, when it's locked.
      Future<void> readPayslip() async {
        setState(() => payslipError = null);
        File? file;
        try {
          file = await PayslipPdf.pick();
          if (file == null) return;
          setState(() => reading = true);
          String? password;
          if (await PayslipPdf.isLocked(file)) {
            final saved = await PayslipPdf.savedPassword();
            if (saved != null && saved.isNotEmpty) {
              try {
                apply(await PayslipPdf.read(file, saved));
                return;
              } on PayslipError catch (e) {
                if (e != PayslipError.wrongPassword) rethrow;
              }
            }
            while (true) {
              if (!ctx.mounted) return;
              final answer = await _askPayslipPassword(ctx, error: payslipError);
              if (answer == null) return;
              password = answer.$1;
              try {
                final r = await PayslipPdf.read(file, password);
                if (answer.$2) await PayslipPdf.savePassword(password);
                apply(r);
                return;
              } on PayslipError catch (e) {
                if (e != PayslipError.wrongPassword) rethrow;
                setState(() => payslipError = e.message);
              }
            }
          }
          apply(await PayslipPdf.read(file, null));
        } on PayslipError catch (e) {
          setState(() => payslipError = e.message);
        } catch (e) {
          AppLog.add('payslip', 'קריאת התלוש נכשלה: $e');
          setState(() => payslipError = PayslipError.unreadable.message);
        } finally {
          await PayslipPdf.discard(file);
          if (ctx.mounted) setState(() => reading = false);
        }
      }

      final theme = Theme.of(ctx);
      final p = payslip;
      Widget line(String title, double value) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(children: [
              Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
              Text(Fmt.money(value), textDirection: TextDirection.rtl, style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: tabular)),
            ]),
          );
      final payslipBox = [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            icon: reading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.document_scanner_outlined),
            label: const Text('קרא מתלוש PDF…'),
            onPressed: reading ? null : readPayslip,
          ),
        ),
        if (payslipError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange.shade700),
              const SizedBox(width: 6),
              Expanded(child: Text(payslipError!, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.orange.shade800))),
            ]),
          ),
        if (p != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.green.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.verified, size: 18, color: AppColors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      'נקרא מהתלוש${p.month != null ? ' של ${Fmt.monthNames[p.month! - 1]}' : ''}${p.year != null ? ' ${p.year}' : ''}',
                      style: theme.textTheme.titleSmall?.copyWith(color: AppColors.green, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 2),
              // Whether the totals checked out against each other (verified / scanned in Payslip.swift).
              Text(
                  p.verified
                      ? (p.scanned
                          ? '✅ אומת בחשבון — הסכומים מסתדרים זה עם זה. התלוש סרוק, אז נקראו רק המספרים: כדאי להציץ.'
                          : '✅ אומת בחשבון — ברוטו פחות ניכויים יוצא בדיוק הנטו')
                      : '⚠️ נקרא חלקית — הסכומים לא אומתו זה מול זה. השווה לתלוש לפני השמירה.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: p.verified ? theme.colorScheme.onSurfaceVariant : Colors.orange.shade800)),
              const SizedBox(height: 4),
              if (p.gross != null) line('סה״כ תשלומים (ברוטו)', p.gross!),
              if (p.incomeTax != null) line('מס הכנסה', -p.incomeTax!),
              if (p.nationalInsurance != null) line('ביטוח לאומי', -p.nationalInsurance!),
              if (p.health != null) line('מס בריאות', -p.health!),
              if (p.deductions != null) line('ניכויי חובה וגמל (סה״כ)', -p.deductions!),
              if (p.net != null && p.netToPay != null && (p.net! - p.netToPay!).abs() > 0.005) ...[
                line('שכר נטו', p.net!),
                line('ניכויי רשות', p.netToPay! - p.net!),
              ],
            ]),
          ),
        gap,
      ];
      return Column(key: ValueKey(version), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: month,
              decoration: const InputDecoration(labelText: 'חודש', border: OutlineInputBorder()),
              items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(Fmt.monthNames[m - 1]))],
              onChanged: (v) => pick(year, v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: year,
              decoration: const InputDecoration(labelText: 'שנה', border: OutlineInputBorder()),
              items: [for (var y = now.year - 5; y <= now.year + 1; y++) DropdownMenuItem(value: y, child: Text('$y'))],
              onChanged: (v) => pick(v!, month),
            ),
          ),
        ]),
        gap,
        TextInput(label: 'הערה (לא חובה)', initial: note, onChanged: (v) => note = v),
        gap,
        ...payslipBox,
        NumberField(
          label: 'משכורת בפועל',
          value: actual,
          suffix: '₪',
          helper: 'הסכום ״נטו לתשלום״ מהתלוש — אפשר לבחור את קובץ התלוש וזה ימולא לבד (בדוק לפני השמירה). התחזית משתמשת בממוצע של החודשים האחרונים. ההוספה לעו״ש מעדכנת את היתרה '
              'המשוערת עד שתעדכן יתרה ידנית.',
          onChanged: (v) => actual = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('להוסיף את המשכורת לעו״ש'),
          value: addToChecking,
          onChanged: (v) => setState(() => addToChecking = v),
        ),
        Text(existing() != null
            ? 'החודש הזה כבר שמור — השמירה תחליף את הרשומה הקיימת.'
            : 'נשמר עותק של כל הנתונים הנוכחיים (הכנסות, ניכויים והוצאות).'),
      ]);
    },
    onSave: () => store.edit((f) {
      final old = f.history.where((r) => r.year == year && r.month == month).firstOrNull;
      f.upsertRecord({
        'id': old?.id ?? newId(),
        'year': year,
        'month': month,
        'note': note,
        'budget': deepCopy(f.json['budget'] ?? Starter.budget()),
        'savedAt': dateTimeToSwift(DateTime.now()),
        if (actual > 0) 'actualNet': jsonNumber(actual),
      });
      // Optionally record the salary as an income into the checking account.
      final key = year * 100 + month;
      f.money.removeTransactionsWhere((t) => t['salaryKey'] == key);
      final checking = f.money.checking;
      if (addToChecking && actual > 0 && checking != null) {
        // It came in on that month's pay day (or today, if that's still ahead).
        final payDay = f.money.periodStart(year, month);
        final date = DateTime.now().isBefore(payDay) ? DateTime.now() : payDay;
        f.money.upsertTransaction({
          ...MoneyTransaction.create(kind: TransactionKind.income, accountID: checking.id),
          'date': dateTimeToSwift(date),
          'title': 'משכורת ${Fmt.monthNames[month - 1]}',
          'amount': jsonNumber(actual),
          'salaryKey': key,
        });
      }
    }),
  );
}

/// "התלוש נעול בסיסמה": the password, and whether to remember it on this device; null when cancelled.
/// [error]: "הסיסמה לא נכונה." after a wrong try, shown in the dialog too (the sheet behind it is covered).
Future<(String, bool)?> _askPayslipPassword(BuildContext context, {String? error}) {
  final controller = TextEditingController();
  return showDialog<(String, bool)>(
    context: context,
    builder: (ctx) {
      void done(bool remember) {
        if (controller.text.isNotEmpty) Navigator.pop(ctx, (controller.text, remember));
      }
      return AlertDialog(
        title: const Text('התלוש נעול בסיסמה'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('בדרך כלל זו תעודת הזהות. ״זכור״ שומר אותה בצורה מוצפנת במכשיר הזה בלבד, כדי שהתלוש הבא ייפתח לבד.'),
          gap,
          TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'סיסמה', border: OutlineInputBorder()),
            onSubmitted: (_) => done(false),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
        ]),
        actionsOverflowDirection: VerticalDirection.up,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          TextButton(onPressed: () => done(false), child: const Text('פתח רק הפעם')),
          FilledButton(onPressed: () => done(true), child: const Text('פתח וזכור במכשיר')),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}

/// A sub-heading inside the month breakdown, with its total.
class _Header extends StatelessWidget {
  const _Header(this.title, this.total);
  final String title;
  final double total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [
        Expanded(child: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary))),
        Text(Fmt.money(total.abs()), textDirection: TextDirection.rtl, style: theme.textTheme.labelLarge),
      ]),
    );
  }
}
