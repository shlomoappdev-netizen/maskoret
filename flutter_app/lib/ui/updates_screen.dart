import 'dart:io';

import 'package:flutter/material.dart';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/updater.dart';
import '../update/whats_new.dart';
import 'app_prompts.dart' show playBetaPage;
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
  State<UpdatesScreen> createState() => Updater.fromPlayStore ? _PlayUpdatesState() : _UpdatesScreenState();
}

/// The Play build: the installed version and what's new in it, and that updates come through Google Play
/// (an app from Play may not update itself).
class _PlayUpdatesState extends State<UpdatesScreen> {
  String _version = '';
  int _build = 0;
  List<ChangelogEntry>? _changelog;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    final all = await WhatsNew.all();
    if (!mounted) return;
    setState(() {
      _version = info.version;
      _build = int.tryParse(info.buildNumber) ?? 0;
      _changelog = all?.where((e) => e.build <= _build && e.notes.isNotEmpty).take(5).toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('עדכונים')),
      body: PageList(children: [
        SectionCard(title: 'הגרסה שלך', children: [
          ListTile(
            leading: const Icon(Icons.shop_outlined),
            title: Text(_version.isEmpty ? '…' : 'גרסה $_version'),
            subtitle: const Text('העדכונים מגיעים דרך Google Play'),
          ),
        ]),
        if (_loading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else
          for (final e in _changelog ?? const <ChangelogEntry>[])
            SectionCard(
              title: 'מה חדש בגרסה ${e.version}',
              subtitle: e.date == null ? null : 'פורסמה ${e.date}',
              children: [
                for (final n in e.notes) ListTile(dense: true, leading: const Icon(Icons.check, size: 18), title: Text(n)),
              ],
            ),
      ]),
    );
  }
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
            if (Platform.isAndroid)
              SectionCard(title: 'עוברים ל-Google Play', children: [
                ListTile(
                  leading: const Icon(Icons.shop_outlined),
                  title: const Text('העדכונים לאנדרואיד מגיעים מעכשיו רק דרך Google Play'),
                  subtitle: const Text('נרשמים לבטא באתר ומתקינים מ-Google Play מעל האפליקציה הזו. הנתונים נשארים.'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => launchUrl(Uri.parse(playBetaPage), mode: LaunchMode.externalApplication),
                ),
              ]),
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
                  if (updater.phase == UpdatePhase.downloading || updater.phase == UpdatePhase.verifying)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: LinearProgressIndicator(
                          value: updater.phase == UpdatePhase.downloading && updater.progress > 0 ? updater.progress : null),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(switch (updater.phase) {
                        UpdatePhase.downloading => 'מוריד… ${(updater.progress * 100).round()}%',
                        UpdatePhase.verifying => 'מאמת את הקובץ…',
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
