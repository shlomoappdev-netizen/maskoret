import 'package:flutter/material.dart';

import '../support/announcements.dart';
import '../update/updater.dart';
import '../update/whats_new.dart';
import 'common.dart';
import 'theme.dart';
import 'updates_screen.dart';

/// "גרסה X זמינה" — the notes of the new version, "עדכן עכשיו" or "אחר כך".
Future<void> showUpdatePrompt(BuildContext context, Updater updater) async {
  final latest = updater.latest!;
  updater.promptShown();
  final update = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.system_update_alt, color: AppColors.teal, size: 36),
      title: Text('גרסה ${latest.version} זמינה'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 360),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (latest.notes.isEmpty) const Text('יש גרסה חדשה של מחשבון שכר.'),
            for (final n in latest.notes) _Bullet(n),
            const SizedBox(height: 8),
            Text('הנתונים שמורים בשרת, כך שהעדכון לא נוגע בהם.', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('אחר כך')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('עדכן עכשיו')),
      ],
    ),
  );
  // Either way the window doesn't come back for this version until the next launch.
  updater.postpone();
  if (update == true && context.mounted) {
    Navigator.push(context, glassRoute((_) => const UpdatesScreen()));
    updater.install();
  }
}

/// "מה חדש בגרסה X" after an update — every version since the last one the user saw.
Future<void> showWhatsNew(BuildContext context, List<ChangelogEntry> entries) {
  final theme = Theme.of(context);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      titlePadding: const EdgeInsetsDirectional.fromSTEB(24, 12, 8, 0),
      title: Row(children: [
        const Icon(Icons.auto_awesome, color: AppColors.teal),
        const SizedBox(width: 10),
        Expanded(child: Text('מה חדש בגרסה ${entries.first.version}')),
        IconButton(tooltip: 'סגור', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ]),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 420),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            for (final (i, e) in entries.indexed) ...[
              if (entries.length > 1)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 14, bottom: 4),
                  child: Text(['גרסה ${e.version}', ?e.date].join(' · '),
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
              for (final n in e.notes) _Bullet(n),
            ],
          ]),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('הבנתי'))],
    ),
  );
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(Icons.check_circle, size: 16, color: AppColors.teal),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
      );
}

/// The admin's message at the top of the summary, until the user closes it.
class AnnouncementCard extends StatelessWidget {
  const AnnouncementCard({super.key});

  @override
  Widget build(BuildContext context) {
    final center = context.scope.announcements;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final a = center.current;
        if (a == null) return const SizedBox.shrink();
        return Padding(padding: const EdgeInsets.only(bottom: 14), child: _Card(a: a, onClose: () => center.dismiss(a.id)));
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.a, required this.onClose});
  final Announcement a;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Glass(
      tint: AppColors.teal.withValues(alpha: theme.brightness == Brightness.dark ? 0.22 : 0.12),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 6, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [AppColors.teal, AppColors.blue]),
          ),
          child: const Icon(Icons.campaign, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (a.body.isNotEmpty) ...[const SizedBox(height: 4), Text(a.body)],
          ]),
        ),
        IconButton(tooltip: 'סגור', icon: const Icon(Icons.close), onPressed: onClose),
      ]),
    );
  }
}
