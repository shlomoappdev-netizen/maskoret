import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/fmt.dart';
import '../data/json.dart';
import '../data/models.dart';
import '../data/rates_update.dart';
import 'common.dart';
import 'theme.dart';

/// "נתוני מס" — credit points, pension, the official rates and their updates (TaxSettingsView.swift).
class TaxSettingsScreen extends StatefulWidget {
  const TaxSettingsScreen({super.key});

  @override
  State<TaxSettingsScreen> createState() => _TaxSettingsScreenState();
}

class _TaxSettingsScreenState extends State<TaxSettingsScreen> {
  var _checking = false;
  var _status = '';

  Future<void> _refresh() async {
    final store = context.store;
    setState(() => _checking = true);
    final (status, newer, fetched) = await RatesUpdate.check(store.file, force: true);
    if (fetched || newer != null) store.edit((f) => RatesUpdate.apply(f, newer, checked: fetched));
    if (mounted) {
      setState(() {
        _checking = false;
        _status = status;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StoreBuilder(builder: (context, store) {
      final b = store.budget;
      final ts = b.taxSettings;
      final rates = b.rates;
      final theme = Theme.of(context);
      void edit(void Function(TaxSettings t) change) => store.edit((f) => change(f.budget.taxSettings));
      String range(int i) {
        final lower = i == 0 ? 0.0 : (rates.brackets[i - 1].upTo ?? 0);
        final upper = rates.brackets[i].upTo;
        if (upper != null) return i == 0 ? 'עד ${Fmt.money(upper)}' : '${Fmt.money(lower + 1)} – ${Fmt.money(upper)}';
        return 'מעל ${Fmt.money(lower)}';
      }

      final active = ts.contributesPension();
      final hasItem = b.deductions.any((d) => d.auto == AutoDeduction.pension);
      final lastCheck = JObj(store.file.json).date('lastRatesCheck');
      final sources = [for (final s in (rates.json['sources'] as List? ?? const [])) if (s is Map) s];

      return PageList(children: [
        SectionCard(
          title: 'נקודות זיכוי',
          subtitle: 'תושב/ת ישראל: 2.25 · אישה: עוד 0.5 · חייל/ת משוחרר/ת: עד 2 נקודות למשך 3 שנים מהשחרור (לפי משך השירות) · '
              'סיום תואר ראשון: נקודה אחת לשנה · ילדים: לפי גילם. המספר המדויק מופיע בתלוש השכר.',
          children: [
            ListTile(
              title: const Text('נקודות זיכוי'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton.outlined(
                  tooltip: 'פחות',
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: ts.creditPoints <= 0 ? null : () => edit((t) => t.creditPoints = (t.creditPoints - 0.25).clamp(0, 20)),
                ),
                SizedBox(
                  width: 56,
                  child: Text(Fmt.number(ts.creditPoints),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular)),
                ),
                IconButton.outlined(
                  tooltip: 'יותר',
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: ts.creditPoints >= 20 ? null : () => edit((t) => t.creditPoints = (t.creditPoints + 0.25).clamp(0, 20)),
                ),
              ]),
            ),
            _RateLine('שווי בחודש', Fmt.money(ts.creditPoints * rates.creditPointValue)),
          ],
        ),
        SectionCard(
          title: 'פנסיה',
          subtitle: 'בדרך כלל חובת ההפרשה מתחילה מגיל 21 לגבר ו-20 לאישה, ואחרי חצי שנה במקום העבודה (או 3 חודשים למי שכבר היה '
              'לו קרן פנסיה) — אבל כדאי לבדוק בתלוש או מול המעסיק. ״יתחיל מתאריך״ מפעיל את הניכוי לבד כשמגיע התאריך. אחוז '
              'ההפרשה עצמו נקבע בשורת ״פנסיה״ בעמוד ניכויים.',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: DropdownButtonFormField<PensionMode>(
                initialValue: ts.pensionMode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'פנסיה מהתלוש', border: OutlineInputBorder()),
                items: [for (final m in PensionMode.values) DropdownMenuItem(value: m, child: Text(m.title))],
                onChanged: (v) => edit((t) => t.pensionMode = v!),
              ),
            ),
            if (ts.pensionMode == PensionMode.startsLater)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: DateField(
                  label: 'מתחיל להפריש ב-',
                  value: ts.pensionStart ?? DateTime.now(),
                  onChanged: (v) => edit((t) => t.pensionStart = v),
                ),
              ),
            _RateLine(
              'כרגע',
              active
                  ? (hasItem ? 'יורדת פנסיה — ${Fmt.money(b.pensionContribution)}' : 'מפריש, אבל אין שורת ״פנסיה״ בניכויים')
                  : 'לא יורדת פנסיה, ואין זיכוי מס על הפרשה',
            ),
          ],
        ),
        SectionCard(title: 'מס הכנסה — מדרגות חודשיות ${rates.year}', children: [
          for (var i = 0; i < rates.brackets.length; i++) _RateLine(range(i), Fmt.percent(rates.brackets[i].rate)),
          _RateLine('מס יסף', '${Fmt.percent(rates.surtaxRate)} מעל ${Fmt.money(rates.surtaxMonthlyThreshold)}'),
          _RateLine('שווי נקודת זיכוי', Fmt.money(rates.creditPointValue)),
          _RateLine('זיכוי פנסיה',
              '${Fmt.percent(rates.pensionCreditRate)} על עד ${Fmt.percent(rates.pensionCreditMaxPercent)} משכר של עד ${Fmt.money(rates.pensionInsuredSalaryCap)}'),
        ]),
        SectionCard(title: 'ביטוח לאומי ומס בריאות (עובד)', subtitle: 'שיעור מופחת / שיעור מלא.', children: [
          _RateLine('סף שיעור מופחת', Fmt.money(rates.niReducedThreshold)),
          _RateLine('הכנסה מרבית', Fmt.money(rates.niMaxIncome)),
          _RateLine('ביטוח לאומי', '${Fmt.percent(rates.niReducedRate)} / ${Fmt.percent(rates.niFullRate)}'),
          _RateLine('מס בריאות', '${Fmt.percent(rates.healthReducedRate)} / ${Fmt.percent(rates.healthFullRate)}'),
        ]),
        SectionCard(
          title: 'עדכון אוטומטי',
          subtitle: 'האפליקציה בודקת פעמיים ביום אם פורסמו שיעורים חדשים ומעדכנת לבד. החישוב הוא הערכה לשכיר — הוא לא כולל '
              'שווי הטבות, הפרשות מעסיק מעל התקרה או תיאום מס, ולכן עשוי להיות שונה במעט מהתלוש.',
          children: [
            _RateLine('גרסת נתונים', rates.updated),
            if (lastCheck != null) _RateLine('בדיקה אחרונה', '${Fmt.date(lastCheck)} ${lastCheck.hour}:${lastCheck.minute.toString().padLeft(2, '0')}'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('בדוק עדכונים עכשיו'),
                  onPressed: _checking ? null : _refresh,
                ),
                if (_checking) ...[
                  const SizedBox(width: 12),
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ]),
            ),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(_status, style: theme.textTheme.bodySmall),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: TextFormField(
                  initialValue: RatesUpdate.url(store.file),
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(labelText: 'כתובת קובץ העדכון', border: OutlineInputBorder()),
                  onChanged: (v) => store.edit((f) => JObj(f.json).set('ratesURL', v)),
                ),
              ),
            ),
          ],
        ),
        SectionCard(title: 'מקורות רשמיים', children: [
          for (final s in sources)
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(s['title'] as String? ?? ''),
              onTap: () {
                final uri = Uri.tryParse(s['url'] as String? ?? '');
                if (uri != null && uri.scheme == 'https') launchUrl(uri, mode: LaunchMode.externalApplication);
              },
            ),
        ]),
      ]);
    });
  }
}

class _RateLine extends StatelessWidget {
  const _RateLine(this.title, this.value);
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(title)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontFeatures: tabular)),
          ),
        ]),
      );
}
