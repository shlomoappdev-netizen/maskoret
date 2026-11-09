import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:url_launcher/url_launcher.dart';

import '../data/fmt.dart';
import '../insights/ai_context.dart';
import '../insights/engine.dart';
import '../insights/markdown.dart';
import '../insights/segments.dart';
import 'common.dart';
import 'theme.dart';

const _quickPrompts = [
  'סכם לי את החודש',
  'איפה אפשר לחסוך?',
  'תרשים של ההוצאות המשתנות לפי קטגוריה',
  'האם אני בכיוון טוב לפי התחזית?',
  'שאל אותי שאלות כדי לבנות תקציב מסודר',
];

/// "תובנות AI" — a conversation about the money with a model the user chose (InsightsView.swift).
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  final _input = TextEditingController();
  final _pasted = TextEditingController();
  final _scroll = ScrollController();
  int _shown = 0;
  int _streamed = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted) return;
    final scope = context.scope;
    final ai = scope.insights;
    await ai.loadModels();
  }

  @override
  void dispose() {
    _input.dispose();
    _pasted.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _ask(String text) {
    final scope = context.scope;
    if (!scope.insights.canSend || scope.insights.isRunning || text.trim().isEmpty) return;
    scope.insights.send(text, context: aiContext(scope.store));
    _input.clear();
  }

  void _followBottom(InsightsEngine ai) {
    if (ai.messages.length == _shown && ai.streaming.length == _streamed) return;
    _shown = ai.messages.length;
    _streamed = ai.streaming.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.scope.insights;
    return ListenableBuilder(
      listenable: ai,
      builder: (context, _) {
        final theme = Theme.of(context);
        _followBottom(ai);
        final needsModel = ai.connected == true && !ai.canSend && !ai.awaitingPaste;
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(ai.isRunning ? 'המודל חושב…' : (ai.status.isEmpty ? 'בחר מנוע בהגדרות' : ai.status),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  if (ai.activeModelName.isNotEmpty)
                    Text(ai.activeModelName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
                ]),
              ),
              IconButton(
                tooltip: 'הגדרות',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(context, glassRoute((_) => const InsightsSettingsScreen())),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('תובנות חדשות'),
                onPressed: ai.isRunning || !ai.canSend ? null : () => _ask(InsightsEngine.defaultAnalysis),
              ),
            ]),
          ),
          if (needsModel)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Glass(
                tint: Colors.orange.withValues(alpha: 0.12),
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Icon(Icons.star, color: Colors.orange.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ai.engine == AIEngine.cloud ? 'כתוב איזה מודל להשתמש בו — רק הוא יקבל את הנתונים שלך.' : 'בחר מודל ברירת מחדל — רק הוא יקבל את הנתונים שלך.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.push(context, glassRoute((_) => const InsightsSettingsScreen())),
                    child: const Text('בחירת מודל…'),
                  ),
                ]),
              ),
            ),
          Expanded(child: ai.connected == false && ai.messages.isEmpty ? _SetupHelp(ai: ai, retry: _open) : _conversation(ai)),
          if (ai.awaitingPaste) _pastePanel(ai),
          _composer(ai),
        ]);
      },
    );
  }

  Widget _conversation(InsightsEngine ai) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: SelectionArea(
          child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(20, 8, 20, 12), children: [
            if (ai.messages.isEmpty && !ai.isRunning)
              Glass(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('שאל כל שאלה על הכסף שלך, או לחץ ״תובנות חדשות״.', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    'המודל מקבל סיכום של כל מה שיש באפליקציה: התלוש, ההוצאות הקבועות, החשבונות, האשראי לפי קטגוריה, התשלומים, המגמות '
                    'והתחזית. הוא יכול לצייר תרשימים ולשאול אותך שאלות — התשובות שלך נשמרות בשיחה וממשיכות איתו הלאה.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ]),
              ),
            for (final m in ai.messages) _Bubble(message: m),
            if (ai.isRunning) _Bubble(message: InsightMessage(role: 'assistant', text: ai.streaming), live: true),
          ]),
        ),
      ),
    );
  }

  Widget _pastePanel(InsightsEngine ai) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Glass(
        tint: AppColors.teal.withValues(alpha: 0.1),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('הפרומפט הועתק ללוח (${ai.manualPrompt.length} תווים)', style: const TextStyle(fontWeight: FontWeight.w600)),
            OutlinedButton(onPressed: ai.copyManualPrompt, child: const Text('העתק שוב')),
            FilledButton(onPressed: ai.openManualSite, child: Text('פתח את ${ai.manualSite}')),
          ]),
          const SizedBox(height: 6),
          Text('הדבק את הפרומפט באתר או באפליקציה. כשהתשובה מגיעה, העתק אותה עם כפתור ההעתקה שמתחת לתשובה (לא בסימון), כדי שגם הגרפים והעיצוב יעברו, והדבק כאן:',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          TextField(
            controller: _pasted,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'התשובה מהאתר'),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            FilledButton(
              onPressed: _pasted.text.trim().isEmpty || _pasted.text == ai.manualPrompt
                  ? null
                  : () {
                      ai.submitManualAnswer(_pasted.text);
                      _pasted.clear();
                    },
              child: const Text('שמור תשובה'),
            ),
            OutlinedButton(
              onPressed: () async {
                final data = await Clipboard.getData('text/plain');
                if (data?.text != null) setState(() => _pasted.text = data!.text!);
              },
              child: const Text('הדבק מהלוח'),
            ),
            TextButton(
              onPressed: () {
                ai.cancelManual();
                _pasted.clear();
              },
              child: const Text('ביטול'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _composer(InsightsEngine ai) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final p in _quickPrompts)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ActionChip(label: Text(p), onPressed: ai.canSend && !ai.isRunning ? () => _ask(p) : null),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _ask,
                decoration: const InputDecoration(hintText: 'כתוב שאלה או תשובה לשאלה של המודל…', border: OutlineInputBorder(), isDense: true),
              ),
            ),
            const SizedBox(width: 6),
            if (ai.isRunning)
              TextButton(onPressed: ai.stop, child: const Text('עצור'))
            else
              IconButton.filled(
                tooltip: 'שלח',
                icon: const Icon(Icons.arrow_upward),
                onPressed: ai.canSend ? () => _ask(_input.text) : null,
              ),
          ]),
        ]),
      ),
    );
  }
}

class _SetupHelp extends StatelessWidget {
  const _SetupHelp({required this.ai, required this.retry});
  final InsightsEngine ai;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PageList(padding: const EdgeInsets.all(20), children: [
      Glass(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('חסר מפתח API — הוסף אותו בהגדרות',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('בוחרים ספק, מדביקים מפתח API אישי וכותבים את שם המודל. המפתח נשמר רק במכשיר הזה.'),
          const SizedBox(height: 4),
          const Text('בלי מפתח? אפשר לעבור ל״ידני״: הפרומפט מועתק ללוח, מדביקים אותו באתר צ׳אט, ומחזירים לכאן את התשובה.'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            FilledButton(
              onPressed: () => Navigator.push(context, glassRoute((_) => const InsightsSettingsScreen())),
              child: const Text('הגדרות…'),
            ),
            OutlinedButton(onPressed: retry, child: const Text('בדוק שוב')),
          ]),
        ]),
      ),
    ]);
  }
}

/// The engine, the key and the model.
class InsightsSettingsScreen extends StatefulWidget {
  const InsightsSettingsScreen({super.key});

  @override
  State<InsightsSettingsScreen> createState() => _InsightsSettingsScreenState();
}

class _InsightsSettingsScreenState extends State<InsightsSettingsScreen> {
  final _key = TextEditingController();
  var _version = 0;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.scope.insights;
    return ListenableBuilder(
      listenable: ai,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('הגדרות תובנות')),
          body: PageList(children: [
            SectionCard(title: 'מנוע', children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<AIEngine>(
                  key: ValueKey(ai.engine),
                  initialValue: ai.engine,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'מנוע', border: OutlineInputBorder()),
                  items: [for (final e in AIEngine.values) DropdownMenuItem(value: e, child: Text(e.title))],
                  onChanged: (v) => ai.setEngine(v!),
                ),
              ),
              if (ai.status.isNotEmpty) EmptyHint(ai.status),
            ]),
            if (ai.engine == AIEngine.cloud) ..._cloud(ai, theme),
            if (ai.engine == AIEngine.manual)
              SectionCard(title: 'ידני', children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    initialValue: ai.manualSite,
                    decoration: const InputDecoration(labelText: 'אתר', border: OutlineInputBorder()),
                    items: [for (final s in manualSites.keys) DropdownMenuItem(value: s, child: Text(s))],
                    onChanged: (v) => ai.setManualSite(v!),
                  ),
                ),
                const EmptyHint('כשאתה שואל, כל הנתונים והשאלה מועתקים ללוח כפרומפט אחד. מדביקים אותו באתר (בלי מפתח API, גם בחשבון '
                    'חינמי), ואז מדביקים כאן את התשובה — היא נשמרת בשיחה עם תרשימים ועיצוב, והשיחה ממשיכה משם.'),
              ]),
            SectionCard(children: [
              ListTile(
                leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text('נקה שיחה', style: TextStyle(color: theme.colorScheme.error)),
                onTap: () async {
                  if (await confirm(context, 'לנקות את השיחה?', 'כל השאלות והתשובות יימחקו מהמכשיר.', ok: 'נקה')) ai.clear();
                },
              ),
            ]),
          ]),
        );
      },
    );
  }

  List<Widget> _cloud(InsightsEngine ai, ThemeData theme) => [
        SectionCard(title: 'מודל בענן', children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: DropdownButtonFormField<CloudProvider>(
              key: ValueKey(ai.cloudProvider),
              initialValue: ai.cloudProvider,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'ספק', border: OutlineInputBorder()),
              items: [for (final p in CloudProvider.values) DropdownMenuItem(value: p, child: Text(p.title))],
              onChanged: (v) {
                ai.setProvider(v!);
                _key.clear();
                setState(() => _version++);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _key,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  textDirection: TextDirection.ltr,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: ai.hasCloudKey ? 'מפתח API (שמור)' : 'הדבק כאן את מפתח ה-API',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _key.text.trim().isEmpty
                    ? null
                    : () async {
                        await ai.saveAPIKey(_key.text);
                        _key.clear();
                        await ai.loadCloudModels();
                      },
                child: const Text('שמור'),
              ),
              if (ai.hasCloudKey)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: () => ai.saveAPIKey(''),
                  child: const Text('מחק'),
                ),
            ]),
          ),
          if (ai.cloudProvider.keyPage != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => launchUrl(Uri.parse(ai.cloudProvider.keyPage!), mode: LaunchMode.externalApplication),
                child: const Text('איפה מקבלים מפתח?'),
              ),
            ),
          if (ai.cloudProvider == CloudProvider.custom)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextFormField(
                initialValue: ai.cloudBaseURL,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'כתובת ה-API', hintText: 'https://…/v1', border: OutlineInputBorder()),
                onChanged: ai.setCloudBaseURL,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('model-$_version'),
                  initialValue: ai.cloudModel,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: 'מודל',
                    hintText: ai.cloudProvider.isAnthropic ? 'למשל: claude-sonnet-5-5' : 'שם המודל',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: ai.setCloudModel,
                ),
              ),
              if (ai.cloudModels.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'בחר מודל',
                  icon: const Icon(Icons.arrow_drop_down_circle_outlined),
                  onSelected: (m) {
                    ai.setCloudModel(m);
                    setState(() => _version++);
                  },
                  itemBuilder: (_) => [for (final m in ai.cloudModels) PopupMenuItem(value: m, child: Text(m))],
                ),
              TextButton(onPressed: ai.hasCloudKey ? ai.loadCloudModels : null, child: const Text('טען רשימה')),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'שים לב: במצב הזה הנתונים הכספיים שלך נשלחים לשרת של הספק שבחרת. המפתח נשמר באחסון המאובטח של המכשיר. תובנות אוטומטיות לא '
              'נשלחות לענן — רק כשאתה שואל.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800),
            ),
          ),
        ]),
      ];

}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.live = false});
  final InsightMessage message;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = message.role == 'user';
    final at = message.date;
    final body = user
        ? Text(message.auto ? '✨ תובנות אוטומטיות' : message.text)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (live && (message.text.isEmpty || InsightParser.isThinking(message.text)))
              Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('חושב…', style: theme.textTheme.bodySmall),
              ]),
            for (final s in InsightParser.parse(message.text))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: switch (s) {
                  TextSegment(:final text) => MarkdownText(text),
                  ChartSegment(:final spec) => InsightChart(spec: spec),
                  BrokenSegment() => live
                      ? const SizedBox.shrink()
                      : Text('(המודל ניסה לצייר תרשים, אבל הנתונים שלו לא היו תקינים)', style: theme.textTheme.bodySmall),
                },
              ),
            if (message.model != null && !live)
              Text('${message.model} · ${Fmt.date(at)} ${at.hour}:${at.minute.toString().padLeft(2, '0')}',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]);
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: 12, end: user ? 60 : 0),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Glass(
          radius: 14,
          tint: user ? AppColors.teal.withValues(alpha: 0.16) : null,
          padding: const EdgeInsets.all(12),
          child: body,
        ),
      ),
    );
  }
}

/// The Markdown of an answer, the way chat apps show it (MarkdownView.swift).
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.text, {super.key});
  final String text;

  TextSpan _inline(String t, TextStyle? style) {
    const mono = ['Menlo', 'Consolas', 'monospace'];
    return TextSpan(style: style, children: [
      for (final r in parseInline(t))
        TextSpan(
          text: r.text,
          style: TextStyle(
            fontWeight: r.bold ? FontWeight.w700 : null,
            fontStyle: r.italic ? FontStyle.italic : null,
            fontFamilyFallback: r.code ? mono : null,
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(height: 1.45);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget rich(String t, [TextStyle? style]) => Text.rich(_inline(t, style ?? base));
    Widget item(int indent, String mark, String t) => Padding(
          padding: EdgeInsetsDirectional.only(start: indent * 18.0 + 4, top: 2, bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mark, style: base?.copyWith(color: muted)),
            const SizedBox(width: 6),
            Expanded(child: rich(t)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final b in parseMarkdown(text))
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: switch (b) {
            MdHeading(:final level, :final text) => Padding(
                padding: EdgeInsets.only(top: level <= 2 ? 6 : 2),
                child: rich(
                    text,
                    (level <= 1 ? theme.textTheme.titleLarge : (level == 2 ? theme.textTheme.titleMedium : theme.textTheme.titleSmall))
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            MdParagraph(:final text) => rich(text),
            MdBullet(:final indent, :final text) => item(indent, indent == 0 ? '•' : (indent == 1 ? '◦' : '▪'), text),
            MdNumbered(:final indent, :final number, :final text) => item(indent, '$number.', text),
            MdQuote(:final text) => Container(
                padding: const EdgeInsetsDirectional.only(start: 10),
                decoration: BoxDecoration(
                  border: BorderDirectional(start: BorderSide(color: AppColors.teal.withValues(alpha: 0.6), width: 3)),
                ),
                child: rich(text, base?.copyWith(color: muted)),
              ),
            MdCode(:final text) => Directionality(
                textDirection: TextDirection.ltr,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(8)),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(text, style: base?.copyWith(fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'])),
                  ),
                ),
              ),
            MdTable(:final rows) => _table(context, rows, base),
            MdRule() => const Divider(),
            MdQuestions(:final title) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  const Icon(Icons.help_outline, color: AppColors.teal, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: rich(title, theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                ]),
              ),
          },
        ),
    ]);
  }

  Widget _table(BuildContext context, List<List<String>> rows, TextStyle? base) {
    final on = Theme.of(context).colorScheme.onSurface;
    final columns = rows.map((r) => r.length).reduce(math.max);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: on.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
        children: [
          for (final (i, row) in rows.indexed)
            TableRow(
              decoration: BoxDecoration(color: i == 0 ? on.withValues(alpha: 0.07) : null),
              children: [
                for (var c = 0; c < columns; c++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text.rich(_inline(c < row.length ? row[c] : '', i == 0 ? base?.copyWith(fontWeight: FontWeight.w700) : base)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A chart the model drew: bar, line or pie, with up to 12 points.
class InsightChart extends StatelessWidget {
  const InsightChart({super.key, required this.spec});
  final ChartSpec spec;

  static const _colors = [
    Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.pink, Colors.teal,
    Colors.amber, Colors.red, Colors.indigo, Colors.lightGreen, Colors.brown, Colors.cyan,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = spec.data.take(12).toList();
    final type = spec.type.toLowerCase();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.03), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if ((spec.title ?? '').isNotEmpty) ...[
          Text(spec.title!, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
        ],
        if (type == 'pie' || type == 'donut') _pie(theme, points) else _xy(theme, points, line: type == 'line'),
      ]),
    );
  }

  Widget _pie(ThemeData theme, List<ChartPoint> points) {
    final total = math.max(points.fold(0.0, (s, p) => s + math.max(p.value, 0)), 1.0);
    return Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: 170,
        height: 170,
        child: PieChart(PieChartData(sectionsSpace: 1.5, centerSpaceRadius: 42, sections: [
          for (final (i, p) in points.indexed)
            PieChartSectionData(value: math.max(p.value, 0), color: _colors[i % _colors.length], radius: 40, showTitle: false),
        ])),
      ),
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final (i, p) in points.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              CircleAvatar(radius: 4, backgroundColor: _colors[i % _colors.length]),
              const SizedBox(width: 6),
              Text(p.label, style: theme.textTheme.bodySmall),
              const SizedBox(width: 10),
              Text('${Fmt.money(p.value)} · ${Fmt.percent((p.value / total * 100).roundToDouble())}',
                  textDirection: TextDirection.rtl,
                  style: theme.textTheme.bodySmall?.copyWith(fontFeatures: tabular, color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
      ]),
    ]);
  }

  Widget _xy(ThemeData theme, List<ChartPoint> points, {required bool line}) {
    var minY = 0.0, maxY = 0.0;
    for (final p in points) {
      minY = math.min(minY, p.value);
      maxY = math.max(maxY, p.value);
    }
    final axis = niceAxis(minY, maxY * 1.05);
    final titles = FlTitlesData(
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 44,
          interval: axis.step,
          getTitlesWidget: (v, _) => Text(Fmt.compact(v), style: theme.textTheme.labelSmall),
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 30,
          interval: 1,
          getTitlesWidget: (v, _) {
            final x = v.round();
            if ((v - x).abs() > 0.01) return const SizedBox.shrink();
            // Time runs right to left, like the Mac: the first point at the right.
            final i = line ? points.length - 1 - x : x;
            if (i < 0 || i >= points.length) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SizedBox(
                width: 56,
                child: Text(points[i].label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.rtl,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 10)),
              ),
            );
          },
        ),
      ),
    );
    return SizedBox(
      height: 220,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: line
            ? LineChart(LineChartData(
                minY: axis.min,
                maxY: axis.max,
                gridData: FlGridData(drawVerticalLine: false, horizontalInterval: axis.step),
                borderData: FlBorderData(show: false),
                titlesData: titles,
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (final (i, p) in points.indexed.toList().reversed) FlSpot((points.length - 1 - i).toDouble(), p.value)],
                    color: AppColors.teal,
                    barWidth: 3,
                  ),
                ],
              ))
            : BarChart(BarChartData(
                minY: axis.min,
                maxY: axis.max,
                gridData: FlGridData(drawVerticalLine: false, horizontalInterval: axis.step),
                borderData: FlBorderData(show: false),
                titlesData: titles,
                barGroups: [
                  for (final (i, p) in points.indexed.toList().reversed)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: p.value,
                        width: 18,
                        borderRadius: BorderRadius.circular(4),
                        gradient: const LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [AppColors.blue, AppColors.teal]),
                      ),
                    ]),
                ],
              )),
      ),
    );
  }
}
