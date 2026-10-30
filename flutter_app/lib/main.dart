import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/rates_update.dart';
import 'state/secure_file.dart';
import 'state/store.dart';
import 'sync/account.dart';
import 'sync/server_sync.dart';
import 'ui/app_prompts.dart';
import 'ui/auth_screen.dart';
import 'ui/common.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';
import 'support/announcements.dart';
import 'support/app_log.dart';
import 'support/support.dart';
import 'update/updater.dart';
import 'update/whats_new.dart';

/// --dart-define=DEMO=true: open straight into the app with demo data (for checking screens).
const demo = bool.fromEnvironment('DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The font is bundled with the app (assets/google_fonts) — never downloaded.
  GoogleFonts.config.allowRuntimeFetching = false;
  await initializeDateFormatting('he');
  await Supabase.initialize(url: SupabaseConfig.url, anonKey: SupabaseConfig.anonKey);
  final prefs = await SharedPreferences.getInstance();
  final support = await getApplicationSupportDirectory();
  // The technical log lives outside the data folder (that one is wiped on sign-out).
  await AppLog.init(Directory('${support.path}/logs'));
  await Diagnostics.init();
  AppLog.add('app', 'הפעלה · ${Diagnostics.appVersion} · ${Diagnostics.platform}');
  final store = await AppStore.open(Directory('${support.path}/Maskoret'), prefs, SystemKeyStore());
  // Older versions had a "continue without an account" mode; now, like the iPhone and Mac app, an account is needed.
  prefs.remove('localOnly');
  // Checking the screens without an account: the anonymized household from the tests, nothing goes to the server.
  if (demo) store.replace((jsonDecode(await rootBundle.loadString('assets/demo_household.json')) as Map).cast<String, dynamic>());
  // The rates file (if the household set one): twice a day at most, like Store.refreshRates.
  if (!demo) _checkRates(store);
  final account = UserAccount(prefs);
  final deviceName = await _deviceName();
  final sync = ServerSync(
    store: store,
    account: account,
    backend: SupabaseBackend(),
    prefs: prefs,
    deviceName: deviceName,
  )..attach();
  final supportCenter = SupportCenter(deviceName: deviceName);
  account.onChanged = () async {
    AppLog.add('auth', account.isSignedIn ? 'מחובר' : 'מנותק');
    await sync.accountChanged();
    await supportCenter.start(account.userId);
  };
  account.start();
  final updater = Updater()..startAutoCheck();
  final announcements = Announcements(prefs, client: demo ? null : Supabase.instance.client);
  if (demo) {
    announcements.showSample();
  } else {
    announcements.start();
  }
  runApp(MaskoretApp(
      store: store,
      account: account,
      sync: sync,
      prefs: prefs,
      updater: updater,
      support: supportCenter,
      announcements: announcements));
}

Future<void> _checkRates(AppStore store) async {
  final (_, newer, fetched) = await RatesUpdate.check(store.file);
  if (fetched || newer != null) store.edit((f) => RatesUpdate.apply(f, newer, checked: fetched));
}

/// Shown on the server next to each save ("updated from …"), like `Platform.deviceName` in Swift.
Future<String> _deviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final brand = a.manufacturer.isEmpty ? '' : '${a.manufacturer[0].toUpperCase()}${a.manufacturer.substring(1)} ';
      return '$brand${a.model}';
    }
    if (Platform.isWindows) return (await info.windowsInfo).computerName;
  } catch (_) {}
  return Platform.operatingSystem;
}

class MaskoretApp extends StatefulWidget {
  const MaskoretApp(
      {super.key,
      required this.store,
      required this.account,
      required this.sync,
      required this.prefs,
      required this.updater,
      required this.support,
      required this.announcements});
  final AppStore store;
  final UserAccount account;
  final ServerSync sync;
  final SharedPreferences prefs;
  final Updater updater;
  final SupportCenter support;
  final Announcements announcements;

  @override
  State<MaskoretApp> createState() => _MaskoretAppState();
}

class _MaskoretAppState extends State<MaskoretApp> {
  late final AppLifecycleListener _lifecycle;
  final _navigator = GlobalKey<NavigatorState>();

  /// One window at a time: "מה חדש" first, then "גרסה X זמינה".
  bool _dialogOpen = false;
  bool _whatsNewChecked = false;

  @override
  void initState() {
    super.initState();
    // Back in the app: check the server right away.
    _lifecycle = AppLifecycleListener(onResume: () {
      widget.sync.sync();
      widget.updater.check();
      widget.announcements.refresh();
    });
    widget.updater.addListener(_offerUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showWhatsNew());
  }

  @override
  void dispose() {
    widget.updater.removeListener(_offerUpdate);
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _showWhatsNew() async {
    try {
      await _whatsNew();
    } finally {
      _whatsNewChecked = true;
      _offerUpdate();
    }
  }

  Future<void> _whatsNew() async {
    final info = await PackageInfo.fromPlatform();
    final build = int.tryParse(info.buildNumber) ?? 0;
    // Checking the window in demo mode: as if the previous two builds were the last ones seen.
    if (demo && !widget.prefs.containsKey(WhatsNew.seenKey)) await widget.prefs.setInt(WhatsNew.seenKey, build - 2);
    final entries = await WhatsNew.pending(widget.prefs, build);
    final context = _navigator.currentState?.overlay?.context;
    if (entries == null || context == null || !context.mounted) return;
    _dialogOpen = true;
    await showWhatsNew(context, entries);
    await WhatsNew.markSeen(widget.prefs, build);
    _dialogOpen = false;
  }

  Future<void> _offerUpdate() async {
    final context = _navigator.currentState?.overlay?.context;
    if (!_whatsNewChecked || _dialogOpen || !widget.updater.shouldPrompt || context == null) return;
    _dialogOpen = true;
    await showUpdatePrompt(context, widget.updater);
    _dialogOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      store: widget.store,
      account: widget.account,
      sync: widget.sync,
      prefs: widget.prefs,
      updater: widget.updater,
      support: widget.support,
      announcements: widget.announcements,
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'מחשבון שכר',
        debugShowCheckedModeBanner: false,
        locale: const Locale('he', 'IL'),
        supportedLocales: const [Locale('he', 'IL')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: ListenableBuilder(
          listenable: widget.account,
          builder: (context, _) => GlassBackground(
            child: widget.account.isSignedIn || demo ? const HomeShell() : const AuthScreen(welcome: true),
          ),
        ),
      ),
    );
  }
}
