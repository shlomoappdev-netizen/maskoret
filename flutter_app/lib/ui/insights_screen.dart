import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../data/fmt.dart';
import '../insights/ai_actions.dart';
import '../insights/ai_context.dart';
import '../insights/engine.dart';
import '../insights/markdown.dart';
import '../insights/segments.dart';
import 'common.dart';
import 'theme.dart';

/// A one-tap request on the start screen: the conversation shows `title`; the model gets `prompt`.
class AIQuickAction {
  const AIQuickAction(this.icon, this.title, this.subtitle, this.color, {this.prompt = '', this.draft, this.needsImage = false});
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final String prompt;

  /// Starts the sentence in the text box instead of sending (the user completes it).
  final String? draft;

  /// Asks for a picture first.
  final bool needsImage;

  static const all = [
    AIQuickAction(Icons.auto_awesome, 'תובנות על החודש', 'מה בולט, איפה חורגים ומה לשפר', Colors.purple,
        prompt: InsightsEngine.defaultAnalysis),
    AIQuickAction(Icons.document_scanner_outlined, 'חיסכון מצילום מסך', 'צלם את פרטי החיסכון וה-AI יכניס אותם', Colors.blue,
        prompt: 'בתמונה יש פרטים של חיסכון / פיקדון / פנסיה. הכנס אותם לאפליקציה בדיוק כפי שהם מופיעים בתמונה: אם החשבון כבר קיים — '
            'עדכן אותו (יתרה, ריבית, תאריכים, הפקדה חודשית), ואם לא — הוסף חשבון חדש. אם משהו לא ברור בתמונה, שאל.',
        needsImage: true),
    AIQuickAction(Icons.shopping_cart_outlined, 'צריך לקנות משהו יקר', 'איך לממן בלי לפגוע בתקציב', Colors.orange,
        draft: 'אני צריך לקנות עכשיו '),
    AIQuickAction(Icons.tune, 'המלצות למגמות ולחיסכון', 'תקרות והפקדות שמתאימות למצב', Colors.green,
        prompt: 'תסתכל על המגמות, החסכונות וההוצאות הקבועות, והמלץ על תקרות חודשיות למגמות ועל הפקדות לחיסכון שמתאימות להכנסה שלי. '
            'הצע את השינויים כפעולות.'),
    AIQuickAction(Icons.eco_outlined, 'איפה אפשר לחסוך?', 'הוצאות שאפשר לצמצם', Colors.teal,
        prompt: 'איפה אני יכול לחסוך? תסתכל על ההוצאות הקבועות, האשראי לפי קטגוריה ובתי העסק, ותן לי הצעות קונקרטיות עם סכומים.'),
    AIQuickAction(Icons.show_chart, 'אני בכיוון טוב?', 'לפי התחזית לחודשים הבאים', Colors.pink,
        prompt: 'לפי התחזית לחודשים הבאים — אני בכיוון טוב? מה הסיכונים ומה כדאי לשנות? הוסף תרשים של היתרה הצפויה.'),
  ];
}

/// A picture no larger than [maxSide] pixels, as base64 — small enough to send to the model.
Future<String?> shrinkImage(Uint8List bytes, {int maxSide = 1400}) async {
  try {
    final probe = await (await ui.instantiateImageCodec(bytes)).getNextFrame();
    final w = probe.image.width, h = probe.image.height;
    probe.image.dispose();
    final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (math.max(w, h) <= maxSide && (isJpeg || bytes.length < 1500000)) return base64Encode(bytes);
    final scale = math.min(1.0, maxSide / math.max(w, h));
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: (w * scale).round(), targetHeight: (h * scale).round());
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    return data == null ? null : base64Encode(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

/// "תובנות AI" — a conversation about the money with a model the user chose (InsightsView.swift).
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _pasted = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _attachments = <String>[];
  int _shown = 0;
  int _streamed = 0;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) context.scope.insights.pullConversation();
  }

  Timer? _poll;

  Future<void> _open() async {
    if (!mounted) return;
    final ai = context.scope.insights;
    await ai.loadModels();
    await ai.pullConversation();
    // While the screen is open, what the other devices write shows up within half a minute.
    _poll ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!ai.isRunning) ai.pullConversation();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _input.dispose();
    _pasted.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _canAsk(InsightsEngine ai) => ai.canSend && !ai.isRunning && (_input.text.trim().isNotEmpty || _attachments.isNotEmpty);

  void _ask() {
    final scope = context.scope;
    final ai = scope.insights;
    if (!_canAsk(ai)) return;
    final text = _input.text.trim();
    ai.send(text.isEmpty ? 'מה יש בתמונה? אם יש בה נתונים שצריך להכניס לאפליקציה — הצע אותם כפעולות.' : text,
        label: text.isEmpty ? '📷 תמונה' : null, images: List.of(_attachments), context: aiContext(scope.store));
    _input.clear();
    setState(_attachments.clear);
  }

  Future<bool> _pickImages() async {
    final picked = await FilePicker.pickFiles(type: FileType.image, dialogTitle: 'צרף צילום מסך');
    for (final f in picked.take(4 - _attachments.length)) {
      try {
        final b64 = await shrinkImage(await f.xFile.readAsBytes());
        if (b64 != null) _attachments.add(b64);
      } catch (_) {}
    }
    if (mounted) setState(() {});
    return _attachments.isNotEmpty;
  }

  Future<void> _run(AIQuickAction action) async {
    final scope = context.scope;
    if (action.draft != null) {
      _input.text = action.draft!;
      _focus.requestFocus();
      setState(() {});
      return;
    }
    if (action.needsImage && _attachments.isEmpty && !await _pickImages()) return;
    if (!mounted) return;
    scope.insights.send(action.prompt, label: action.title, images: List.of(_attachments), context: aiContext(scope.store));
    setState(_attachments.clear);
  }

  void _followBottom(InsightsEngine ai) {
    if (ai.messages.length == _shown && ai.streaming.length == _streamed) return;
    _shown = ai.messages.length;
    _streamed = ai.streaming.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _settings() => Navigator.push(context, glassRoute((_) => const InsightsSettingsScreen()));

  @override
  Widget build(BuildContext context) {
    final ai = context.scope.insights;
    return ListenableBuilder(
      listenable: ai,
      builder: (context, _) {
        final theme = Theme.of(context);
        _followBottom(ai);
        final undo = ai.undo;
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
            child: Row(children: [
              Expanded(
                child: Text(
                  ai.isRunning
                      ? 'חושב…'
                      : (ai.engine == AIEngine.cloud && ai.canSend ? '${ai.activeModelName} · ${ai.cloudProvider.title}' : ai.status),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              if (ai.messages.isNotEmpty)
                IconButton(
                  tooltip: 'שיחה חדשה',
                  icon: const Icon(Icons.edit_square),
                  onPressed: ai.isRunning ? null : ai.clear,
                ),
              IconButton(tooltip: 'הגדרות AI', icon: const Icon(Icons.settings_outlined), onPressed: _settings),
            ]),
          ),
          if (ai.connected == false && ai.engine == AIEngine.cloud)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Glass(
                tint: Colors.orange.withValues(alpha: 0.12),
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Icon(Icons.key, color: Colors.orange.shade700, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('כדי לדבר עם ה-AI צריך מפתח API (או לבחור ״ידני״ בהגדרות).')),
                  FilledButton(onPressed: _settings, child: const Text('הגדרות…')),
                ]),
              ),
            ),
          Expanded(child: ai.messages.isEmpty && !ai.isRunning ? _welcome(ai) : _conversation(ai)),
          if (undo != null && ai.messages.any((m) => m.id == undo.$1))
            Container(
              color: Colors.green.withValues(alpha: 0.1),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                const Expanded(child: Text('השינויים בוצעו')),
                TextButton(onPressed: () => ai.undoLast(context.store), child: const Text('בטל את השינויים')),
              ]),
            ),
          if (ai.awaitingPaste) _pastePanel(ai),
          _composer(ai),
        ]);
      },
    );
  }

  Widget _welcome(InsightsEngine ai) {
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 20, 16, 12), children: [
      Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Colors.purple, Colors.blue], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 30),
        ),
      ),
      const SizedBox(height: 14),
      Text('במה אפשר לעזור?', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text('ה-AI רואה את כל הנתונים באפליקציה, יכול לקרוא צילומי מסך, ומציע שינויים שמתבצעים רק אחרי שתאשר.',
          textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 20),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: LayoutBuilder(builder: (context, c) {
            final columns = c.maxWidth > 700 ? 3 : (c.maxWidth > 440 ? 2 : 1);
            final w = (c.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final a in AIQuickAction.all) SizedBox(width: w, child: _tile(ai, a)),
            ]);
          }),
        ),
      ),
    ]);
  }

  Widget _tile(InsightsEngine ai, AIQuickAction a) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: ai.canSend ? 1 : 0.5,
      child: Glass(
        radius: 14,
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: ai.canSend && !ai.isRunning ? () => _run(a) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(colors: [a.color, Color.lerp(a.color, Colors.black, 0.25)!]),
                ),
                child: Icon(a.icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(a.subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _conversation(InsightsEngine ai) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: SelectionArea(
          child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), children: [
            for (final m in ai.messages) _ChatRow(message: m),
            if (ai.isRunning) _ChatRow(message: InsightMessage(role: 'assistant', text: ai.streaming), live: true),
          ]),
        ),
      ),
    );
  }

  Widget _pastePanel(InsightsEngine ai) {
    final theme = Theme.of(context);
    final withPicture = ai.messages.isNotEmpty && ai.messages.last.imageCount > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Glass(
        tint: AppColors.teal.withValues(alpha: 0.1),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('השאלה והנתונים הועתקו ללוח', style: TextStyle(fontWeight: FontWeight.w600)),
            OutlinedButton(onPressed: ai.copyManualPrompt, child: const Text('העתק שוב')),
            FilledButton(onPressed: ai.openManualSite, child: Text('פתח את ${ai.manualSite}')),
          ]),
          const SizedBox(height: 6),
          Text(
              withPicture
                  ? 'הדבק באתר, צרף שם גם את התמונה, ואחרי שהתשובה מגיעה העתק אותה עם כפתור ההעתקה והדבק כאן:'
                  : 'הדבק באתר. כשהתשובה מגיעה, העתק אותה עם כפתור ההעתקה שמתחת לתשובה והדבק כאן:',
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
    final theme = Theme.of(context);
    final canAsk = _canAsk(ai);
    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 892),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (ai.messages.isNotEmpty && !ai.isRunning)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final a in AIQuickAction.all)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: ActionChip(
                          avatar: Icon(a.icon, size: 16, color: a.color),
                          label: Text(a.title),
                          side: BorderSide(color: a.color.withValues(alpha: 0.35)),
                          backgroundColor: a.color.withValues(alpha: 0.08),
                          onPressed: ai.canSend ? () => _run(a) : null,
                        ),
                      ),
                  ]),
                ),
              if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(spacing: 8, children: [
                    for (final (i, b64) in _attachments.indexed)
                      Stack(children: [
                        _Thumb(b64: b64, size: 64),
                        PositionedDirectional(
                          top: 2,
                          start: 2,
                          child: InkWell(
                            onTap: () => setState(() => _attachments.removeAt(i)),
                            child: const CircleAvatar(radius: 10, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)),
                          ),
                        ),
                      ]),
                  ]),
                ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                      color: _focus.hasFocus ? AppColors.teal.withValues(alpha: 0.5) : theme.colorScheme.onSurface.withValues(alpha: 0.1)),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))],
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  _RoundButton(
                    tooltip: 'צרף צילום מסך או תמונה',
                    icon: Icons.add,
                    background: theme.colorScheme.onSurface.withValues(alpha: 0.07),
                    foreground: theme.colorScheme.onSurfaceVariant,
                    onTap: _attachments.length >= 4 ? null : _pickImages,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.send,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _ask(),
                      style: theme.textTheme.bodyLarge,
                      decoration: const InputDecoration(
                        hintText: 'שאל, בקש שינוי, או צרף צילום מסך…',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (ai.isRunning)
                    _RoundButton(tooltip: 'עצור', icon: Icons.stop, background: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                        foreground: theme.colorScheme.surface, onTap: ai.stop)
                  else
                    _RoundButton(
                      tooltip: 'שלח',
                      icon: Icons.arrow_upward,
                      background: canAsk ? AppColors.teal : theme.colorScheme.onSurface.withValues(alpha: 0.08),
                      foreground: canAsk ? Colors.white : theme.disabledColor,
                      onTap: canAsk ? _ask : null,
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A 32-point round button of the input bar.
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.tooltip, required this.icon, required this.background, required this.foreground, this.onTap});
  final String tooltip;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 32, height: 32, child: Icon(icon, size: 18, color: foreground)),
          ),
        ),
      );
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.b64, required this.size});
  final String b64;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(base64Decode(b64), width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true),
      );
}

/// One message: the user's on a colored bubble, the AI's as plain text with an avatar — like chat apps.
class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.message, this.live = false});
  final InsightMessage message;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.role == 'user') {
      final onlyPicture = message.label == '📷 תמונה' && message.imageCount > 0;
      return Padding(
        padding: const EdgeInsetsDirectional.only(bottom: 18, end: 60),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(colors: [AppColors.teal, AppColors.blue]),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (message.images.isNotEmpty)
                Wrap(spacing: 6, runSpacing: 6, children: [for (final b in message.images) _Thumb(b64: b, size: 110)])
              else if (message.imageCount > 0)
                Text(message.imageCount == 1 ? '📷 תמונה' : '📷 ${message.imageCount} תמונות',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              if (!onlyPicture) ...[
                if (message.imageCount > 0) const SizedBox(height: 6),
                Text(message.shownText, style: const TextStyle(color: Colors.white)),
              ],
            ]),
          ),
        ),
      );
    }
    final segments = InsightParser.parse(message.text);
    final at = message.date;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Colors.purple, Colors.blue], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: const Icon(Icons.auto_awesome, color: Colors.white, size: 15),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (live && (segments.isEmpty || InsightParser.isThinking(message.text))) const _TypingDots(),
            for (final s in segments)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: switch (s) {
                  TextSegment(:final text) => MarkdownText(text),
                  ChartSegment(:final spec) => InsightChart(spec: spec),
                  ActionsSegment(:final plan, :final raw) =>
                    live ? const SizedBox.shrink() : _ActionPlanCard(plan: plan, raw: raw, message: message),
                  BrokenSegment() => live
                      ? const SizedBox.shrink()
                      : Text('(ה-AI ניסה להוסיף תרשים או שינוי, אבל הנתונים שלו לא היו תקינים)', style: theme.textTheme.bodySmall),
                },
              ),
            if (!live)
              Row(children: [
                InkWell(
                  onTap: () => Clipboard.setData(ClipboardData(text: InsightParser.withoutThinking(message.text))),
                  child: Icon(Icons.copy, size: 14, color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 10),
                Text('${message.model != null ? '${message.model} · ' : ''}${Fmt.date(at)} ${at.hour}:${at.minute.toString().padLeft(2, '0')}',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ]),
          ]),
        ),
      ]),
    );
  }
}

/// Three dots that pulse while the model is working.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(children: [
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsetsDirectional.only(end: 5),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.3 + 0.7 * math.max(0, math.sin(_c.value * 2 * math.pi - i * 0.8))),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Changes the model proposed: each with a checkbox; nothing happens until "אשר ובצע".
class _ActionPlanCard extends StatefulWidget {
  const _ActionPlanCard({required this.plan, required this.raw, required this.message});
  final AIActionPlan plan;
  final String raw;
  final InsightMessage message;

  @override
  State<_ActionPlanCard> createState() => _ActionPlanCardState();
}

class _ActionPlanCardState extends State<_ActionPlanCard> {
  Set<int>? _chosen;

  /// The user's changes, per action: field → text.
  final _edits = <int, Map<String, String>>{};
  final _editing = <int>{};

  /// The proposal with the user's polish.
  AIActionPlan get _plan => AIActionPlan(widget.plan.summary, [
        for (final a in widget.plan.actions) _edits[a.id] == null ? a : a.edited(_edits[a.id]!),
      ]);

  Widget _editor(AIAction original) {
    final theme = Theme.of(context);
    final fields = AIAction.editableFields.where((f) => original.fields.containsKey(f.$1));
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: theme.colorScheme.surface, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (key, label) in fields)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TextFormField(
              key: ValueKey('${original.id}-$key-${_edits[original.id] == null}'),
              initialValue: _edits[original.id]?[key] ?? original.text(key),
              decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
              keyboardType: AIAction.numberFields.contains(key) ? const TextInputType.numberWithOptions(decimal: true) : null,
              onChanged: (v) => setState(() => (_edits[original.id] ??= {})[key] = v),
            ),
          ),
        if (_edits[original.id] != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _edits.remove(original.id)),
              child: const Text('חזרה להצעה המקורית'),
            ),
          ),
      ]),
    );
  }

  IconData _icon(AIAction a) => switch (a.icon) {
        'account' => Icons.savings_outlined,
        'trend' => Icons.trending_up,
        'expense' => Icons.autorenew,
        _ => Icons.event_note,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = context.scope;
    final plan = _plan;
    final m = widget.message;
    final applied = m.applied;
    final open = applied == null && !m.dismissed;
    final selection = _chosen ?? {for (final a in plan.actions) a.id};
    final store = scope.store;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.purple.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.auto_fix_high, color: Colors.purple, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(plan.summary.isEmpty ? 'שינויים מוצעים' : plan.summary,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (applied != null)
            Text(applied.isEmpty ? 'לא בוצע' : 'בוצע ✓',
                style: TextStyle(color: applied.isEmpty ? Colors.orange : Colors.green, fontWeight: FontWeight.w700))
          else if (m.dismissed)
            Text('נדחה', style: theme.textTheme.bodySmall),
        ]),
        const SizedBox(height: 8),
        for (final a in plan.actions)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (open)
                SizedBox(
                  width: 32,
                  height: 28,
                  child: Checkbox(
                    value: selection.contains(a.id),
                    activeColor: Colors.purple,
                    onChanged: (v) => setState(() {
                      final s = Set.of(selection);
                      v == true ? s.add(a.id) : s.remove(a.id);
                      _chosen = s;
                    }),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
                  child: Icon(applied?.contains(a.id) == true ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 20, color: applied?.contains(a.id) == true ? Colors.green : theme.disabledColor),
                ),
              Container(
                width: 26,
                height: 26,
                margin: const EdgeInsetsDirectional.only(end: 8),
                decoration: BoxDecoration(color: Colors.purple, borderRadius: BorderRadius.circular(6)),
                child: Icon(_icon(a), size: 15, color: Colors.white),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Flexible(child: Text(a.title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                    if (_edits[a.id] != null)
                      const Padding(
                        padding: EdgeInsetsDirectional.only(start: 6),
                        child: Text('נערך', style: TextStyle(color: Colors.purple, fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                  ]),
                  for (final line in a.details)
                    Text(line, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  if (_editing.contains(a.id)) _editor(widget.plan.actions.firstWhere((o) => o.id == a.id)),
                ]),
              ),
              if (open)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.purple, visualDensity: VisualDensity.compact),
                  icon: Icon(_editing.contains(a.id) ? Icons.check : Icons.edit_outlined, size: 16),
                  label: Text(_editing.contains(a.id) ? 'סיום' : 'ערוך'),
                  onPressed: () => setState(() => _editing.contains(a.id) ? _editing.remove(a.id) : _editing.add(a.id)),
                ),
            ]),
          ),
        if (m.actionError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(m.actionError!, style: TextStyle(color: Colors.orange.shade800, fontSize: 12)),
          ),
        if (open) ...[
          if (store.isCombined)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('השינויים יחולו על הנתונים של ${store.activeMember?.title ?? ''}', style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.purple),
              icon: const Icon(Icons.check, size: 18),
              label: Text(selection.length == plan.actions.length ? 'אשר ובצע' : 'בצע ${selection.length} מתוך ${plan.actions.length}'),
              onPressed: selection.isEmpty
                  ? null
                  : () => scope.insights.apply(plan, selection, m.id, store, raw: _edits.isEmpty ? null : widget.raw),
            ),
            TextButton(onPressed: () => scope.insights.dismiss(m.id), child: const Text('לא עכשיו')),
          ]),
        ],
      ]),
    );
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
  Timer? _modelPush;

  @override
  void dispose() {
    _key.dispose();
    _modelPush?.cancel();
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
                leading: ai.checkingConnection
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                title: const Text('בדוק חיבור'),
                subtitle: ai.connectionCheck == null
                    ? null
                    : Text(ai.connectionCheck!.$2,
                        style: TextStyle(color: ai.connectionCheck!.$1 ? Colors.green.shade700 : Colors.orange.shade800)),
                onTap: ai.checkingConnection ? null : ai.testConnection,
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                title: Text('נקה שיחה', style: TextStyle(color: theme.colorScheme.error)),
                onTap: () async {
                  if (await confirm(context, 'לנקות את השיחה?', 'כל השאלות והתשובות יימחקו מכל המכשירים שלך.', ok: 'נקה')) ai.clear();
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
                        await ai.testConnection();
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
          SwitchListTile(
            title: const Text('שמור את המפתח בחשבון'),
            subtitle: const Text('זמין בכל המכשירים שלך, מוצפן'),
            value: ai.keyInAccount,
            onChanged: ai.setKeyInAccount,
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
                    hintText: switch (ai.cloudProvider) {
                      CloudProvider.anthropic => 'למשל: claude-sonnet-5-5',
                      CloudProvider.gemini => 'למשל: gemini-2.5-flash',
                      CloudProvider.openai => 'למשל: gpt-5-mini',
                      _ => 'שם המודל',
                    },
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    ai.setCloudModel(v);
                    _modelPush?.cancel();
                    _modelPush = Timer(const Duration(seconds: 2), ai.pushKeySettings);
                  },
                ),
              ),
              if (ai.cloudModels.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'בחר מודל',
                  icon: const Icon(Icons.arrow_drop_down_circle_outlined),
                  onSelected: (m) {
                    ai.setCloudModel(m);
                    ai.pushKeySettings();
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
              'הנתונים הכספיים נשלחים לספק שבחרת רק כשאתה שואל. המפתח נשמר באחסון המאובטח של המכשיר'
              '${ai.keyInAccount ? ', ומוצפן גם בחשבון שלך.' : '.'}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ]),
      ];

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
    Colors.blue, Colors.purple, Colors.pink, Colors.orange, Colors.green, Colors.teal,
    Colors.amber, Colors.red, Colors.indigo, Colors.lightGreen, Colors.brown, Colors.cyan,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = spec.data.take(12).toList();
    final type = spec.type.toLowerCase();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.08)),
      ),
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
            PieChartSectionData(value: math.max(p.value, 0), color: _colors[i % _colors.length], radius: 42, showTitle: false),
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
                    color: Colors.blue,
                    barWidth: 3,
                    isCurved: true,
                    preventCurveOverShooting: true,
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.blue.withValues(alpha: 0.35), Colors.blue.withValues(alpha: 0.02)],
                      ),
                    ),
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
                        width: 20,
                        borderRadius: BorderRadius.circular(6),
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [_colors[i % _colors.length], Color.lerp(_colors[i % _colors.length], Colors.white, 0.3)!],
                        ),
                      ),
                    ]),
                ],
              )),
      ),
    );
  }
}
