import 'package:flutter/material.dart';

import '../update/updater.dart';
import 'common.dart';

/// "יש גרסה חדשה" at the top of the app.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final updater = context.scope.updater;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: InkWell(
        onTap: () => Navigator.push(context, glassRoute((_) => const UpdatesScreen())),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Icon(Icons.system_update_alt, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text('יש גרסה חדשה (${updater.latest!.version}) — לחץ לפרטים ולעדכון',
                  style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
            ),
          ]),
        ),
      ),
    );
  }
}

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.scope.updater.check(force: true));
  }

  @override
  Widget build(BuildContext context) {
    final updater = context.scope.updater;
    return Scaffold(
      appBar: AppBar(title: const Text('עדכונים')),
      body: ListenableBuilder(
        listenable: updater,
        builder: (context, _) {
          final theme = Theme.of(context);
          final latest = updater.latest;
          return PageList(children: [
            SectionCard(title: 'הגרסה שלך', children: [
              ListTile(
                title: Text(updater.currentVersion.isEmpty ? '…' : 'גרסה ${updater.currentVersion}'),
                subtitle: Text(updater.available
                    ? 'יש גרסה חדשה יותר'
                    : updater.phase == UpdatePhase.checking
                        ? 'בודק…'
                        : 'זו הגרסה העדכנית'),
                trailing: IconButton(
                  tooltip: 'בדוק עכשיו',
                  icon: const Icon(Icons.refresh),
                  onPressed: updater.busy ? null : () => updater.check(force: true),
                ),
              ),
              if (updater.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(updater.error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
            ]),
            if (updater.available && latest != null)
              SectionCard(
                title: 'גרסה ${latest.version}',
                subtitle: latest.date == null ? null : 'פורסמה ${latest.date}',
                children: [
                  for (final n in latest.notes)
                    ListTile(dense: true, leading: const Icon(Icons.check, size: 18), title: Text(n)),
                  if (updater.phase == UpdatePhase.downloading)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: LinearProgressIndicator(value: updater.progress > 0 ? updater.progress : null),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(switch (updater.phase) {
                        UpdatePhase.downloading => 'מוריד… ${(updater.progress * 100).round()}%',
                        UpdatePhase.installing => 'מתקין…',
                        _ => 'עדכן עכשיו',
                      }),
                      onPressed: updater.busy ? null : updater.install,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text('הנתונים שמורים בשרת, כך שהעדכון לא נוגע בהם.'),
                  ),
                ],
              ),
          ]);
        },
      ),
    );
  }
}
