import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/fmt.dart';
import '../support/support.dart';
import '../sync/account.dart';
import 'common.dart';

String _when(DateTime? d) =>
    d == null ? '' : '${Fmt.date(d)} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

IconData _categoryIcon(String c) => switch (c) {
      'bug' => Icons.bug_report_outlined,
      'question' => Icons.help_outline,
      'idea' => Icons.lightbulb_outline,
      _ => Icons.chat_bubble_outline,
    };

/// "מספר מנוי: 1234" with a copy button.
class MemberNumberTile extends StatelessWidget {
  const MemberNumberTile({super.key});

  @override
  Widget build(BuildContext context) {
    final support = context.scope.support;
    return ListenableBuilder(
      listenable: support,
      builder: (context, _) {
        final no = support.memberNo;
        return ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('מספר מנוי'),
          subtitle: Text(no == null ? '…' : '$no', textDirection: TextDirection.ltr, textAlign: TextAlign.right),
          trailing: no == null
              ? null
              : IconButton(
                  tooltip: 'העתקה',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '$no'));
                    showMessage(context, 'מספר המנוי הועתק');
                  },
                ),
        );
      },
    );
  }
}

/// An icon with a red count, for the unread support answers.
class SupportIconButton extends StatelessWidget {
  const SupportIconButton({super.key});

  @override
  Widget build(BuildContext context) {
    final support = context.scope.support;
    return ListenableBuilder(
      listenable: support,
      builder: (context, _) => IconButton(
        tooltip: 'תמיכה ודיווח תקלות',
        icon: Badge(
          isLabelVisible: support.unread > 0,
          label: Text('${support.unread}'),
          child: const Icon(Icons.support_agent),
        ),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportScreen())),
      ),
    );
  }
}

class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.scope.support.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final support = context.scope.support;
    return Scaffold(
      appBar: AppBar(title: const Text('תמיכה ודיווח תקלות')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.edit_outlined),
        label: const Text('פנייה חדשה'),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NewSupportThreadScreen())),
      ),
      body: ListenableBuilder(
        listenable: support,
        builder: (context, _) => PageList(children: [
          const SectionCard(children: [MemberNumberTile()]),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text('כותבים לנו כאן על תקלה, שאלה או רעיון, ומקבלים תשובה בתוך האפליקציה. כדאי לצרף את היומן הטכני '
                'כשמשהו לא עובד — הוא עוזר לנו להבין מה קרה.'),
          ),
          SectionCard(title: 'הפניות שלי', children: [
            if (!support.loaded) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
            if (support.loaded && support.threads.isEmpty) const EmptyHint('עוד לא פתחת פניות.'),
            for (final t in support.threads)
              ListTile(
                leading: Icon(_categoryIcon(t.category)),
                title: Text(t.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${SupportThread.titleOf(t.category)} · ${t.isOpen ? 'פתוחה' : 'סגורה'} · ${_when(t.lastMessageAt)}'),
                trailing: t.userUnread > 0 ? Badge(label: Text('${t.userUnread}')) : null,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SupportChatScreen(threadId: t.id))),
              ),
          ]),
        ]),
      ),
    );
  }
}

class NewSupportThreadScreen extends StatefulWidget {
  const NewSupportThreadScreen({super.key});

  @override
  State<NewSupportThreadScreen> createState() => _NewSupportThreadScreenState();
}

class _NewSupportThreadScreenState extends State<NewSupportThreadScreen> {
  final subject = TextEditingController();
  final body = TextEditingController();
  var category = 'bug';
  var attachLog = true;
  var sending = false;
  String? error;

  @override
  void dispose() {
    subject.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final scope = context.scope;
    if (subject.text.trim().isEmpty || body.text.trim().isEmpty) {
      setState(() => error = 'צריך למלא נושא ותיאור.');
      return;
    }
    setState(() {
      sending = true;
      error = null;
    });
    try {
      final log = attachLog
          ? Diagnostics.report(
              account: scope.account, sync: scope.sync, device: scope.support.deviceName, memberNo: scope.support.memberNo)
          : null;
      final id = await scope.support.openThread(
          subject: subject.text.trim(), category: category, body: body.text.trim(), log: log);
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => SupportChatScreen(threadId: id)));
    } catch (e) {
      setState(() {
        sending = false;
        error = describeSupportError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('פנייה חדשה')),
      body: PageList(children: [
        SectionCard(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in SupportThread.categories.entries)
                  ChoiceChip(
                    avatar: Icon(_categoryIcon(e.key), size: 18),
                    label: Text(e.value),
                    selected: category == e.key,
                    onSelected: (_) => setState(() {
                      category = e.key;
                      attachLog = e.key == 'bug';
                    }),
                  ),
              ]),
              gap,
              TextField(
                controller: subject,
                decoration: const InputDecoration(labelText: 'נושא', hintText: 'במשפט אחד', border: OutlineInputBorder()),
              ),
              gap,
              TextField(
                controller: body,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'מה קרה?', alignLabelWithHint: true, border: OutlineInputBorder()),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('לצרף יומן טכני'),
                value: attachLog,
                onChanged: (v) => setState(() => attachLog = v),
              ),
              Text('היומן כולל את גרסת האפליקציה, סוג המכשיר, מצב הסנכרון ושגיאות אחרונות. הנתונים הכספיים שלך לא נשלחים.',
                  style: Theme.of(context).textTheme.bodySmall),
              if (error != null) ...[
                gap,
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.send),
                label: Text(sending ? 'שולח…' : 'שליחה'),
                onPressed: sending ? null : _send,
              ),
            ]),
          ),
        ]),
      ]),
    );
  }
}

class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key, required this.threadId});
  final String threadId;

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  SupportThread? thread;
  List<SupportMessage> messages = [];
  final draft = TextEditingController();
  final scroll = ScrollController();
  var attachLog = false;
  var sending = false;
  String? error;
  Future<void> Function()? _stopListening;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopListening = context.scope.support.listenToThread(widget.threadId, _load);
      _load();
    });
  }

  @override
  void dispose() {
    _stopListening?.call();
    draft.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final support = context.scope.support;
    try {
      final t = await support.thread(widget.threadId);
      final m = await support.messages(widget.threadId);
      if (!mounted) return;
      setState(() {
        thread = t;
        messages = m;
      });
      await support.markRead(widget.threadId);
      support.refresh();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients) scroll.animateTo(scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      });
    } catch (e) {
      if (mounted) setState(() => error = describeSupportError(e));
    }
  }

  Future<void> _send() async {
    final scope = context.scope;
    final text = draft.text.trim();
    if (text.isEmpty || sending) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      final log = attachLog
          ? Diagnostics.report(
              account: scope.account, sync: scope.sync, device: scope.support.deviceName, memberNo: scope.support.memberNo)
          : null;
      await scope.support.send(widget.threadId, text, log);
      draft.clear();
      attachLog = false;
      await _load();
    } catch (e) {
      error = describeSupportError(e);
    }
    if (mounted) setState(() => sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = thread;
    return Scaffold(
      appBar: AppBar(
        title: Text(t?.subject ?? 'פנייה', overflow: TextOverflow.ellipsis),
        actions: [
          if (t != null)
            TextButton(
              onPressed: () async {
                await run(context, () => context.scope.support.setStatus(widget.threadId, open: !t.isOpen));
                _load();
              },
              child: Text(t.isOpen ? 'סגירת הפנייה' : 'פתיחה מחדש'),
            ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(controller: scroll, padding: const EdgeInsets.all(14), children: [
                if (t != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('${SupportThread.titleOf(t.category)} · נפתחה ${_when(t.createdAt)}',
                        textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                  ),
                for (final m in messages) _bubble(context, m),
              ]),
            ),
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (error != null) Text(error!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
              if (attachLog) Text('היומן הטכני יצורף להודעה', style: theme.textTheme.bodySmall),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                IconButton(
                  tooltip: attachLog ? 'היומן הטכני יצורף להודעה' : 'לצרף יומן טכני',
                  icon: Icon(attachLog ? Icons.attach_file : Icons.attach_file_outlined,
                      color: attachLog ? theme.colorScheme.primary : null),
                  onPressed: () => setState(() => attachLog = !attachLog),
                ),
                Expanded(
                  child: TextField(
                    controller: draft,
                    minLines: 1,
                    maxLines: 6,
                    decoration: const InputDecoration(hintText: 'הודעה', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                IconButton(
                  tooltip: 'שליחה',
                  icon: sending
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                  onPressed: sending ? null : _send,
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _bubble(BuildContext context, SupportMessage m) {
    final theme = Theme.of(context);
    final mine = !m.fromAdmin;
    return Align(
      // RTL: "start" is the right side — my messages there, support's on the left.
      alignment: mine ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.fromAdmin ? 'צוות התמיכה' : 'אתה', style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          SelectableText(m.body),
          if (m.log != null && m.log!.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.description_outlined, size: 16),
              label: const Text('יומן טכני מצורף'),
              onPressed: () => _showLog(context, m.log!),
            ),
          Text(_when(m.createdAt), style: theme.textTheme.labelSmall),
        ]),
      ),
    );
  }

  void _showLog(BuildContext context, String log) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('יומן טכני'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(log, textDirection: TextDirection.ltr, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log));
              showMessage(ctx, 'היומן הועתק');
            },
            child: const Text('העתקה'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('סגור')),
        ],
      ),
    );
  }
}

/// Errors from the support functions, in Hebrew (the server's limits: 10 new threads a day, 60 messages an hour).
String describeSupportError(Object e) {
  final text = e.toString().toLowerCase();
  if (text.contains('too many reports')) return 'אפשר לפתוח עד 10 פניות ביום. נסה שוב מחר, או כתוב בפנייה קיימת.';
  if (text.contains('too many messages')) return 'נשלחו הרבה הודעות בשעה האחרונה. נסה שוב בעוד קצת.';
  if (text.contains('thread not found') || text.contains('not your thread')) return 'הפנייה לא נמצאה.';
  return UserAccount.describe(e);
}
