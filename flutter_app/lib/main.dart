import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'state/secure_file.dart';
import 'state/store.dart';
import 'sync/account.dart';
import 'sync/server_sync.dart';
import 'ui/auth_screen.dart';
import 'ui/common.dart';
import 'ui/home_shell.dart';
import 'support/app_log.dart';
import 'support/support.dart';
import 'update/updater.dart';

/// --dart-define=DEMO=true: open straight into the app with demo data (for checking screens).
const demo = bool.fromEnvironment('DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final updater = Updater()..check();
  runApp(MaskoretApp(
      store: store, account: account, sync: sync, prefs: prefs, updater: updater, support: supportCenter));
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
      required this.support});
  final AppStore store;
  final UserAccount account;
  final ServerSync sync;
  final SharedPreferences prefs;
  final Updater updater;
  final SupportCenter support;

  @override
  State<MaskoretApp> createState() => _MaskoretAppState();
}

class _MaskoretAppState extends State<MaskoretApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back in the app: check the server right away.
    _lifecycle = AppLifecycleListener(onResume: () {
      widget.sync.sync();
      widget.updater.check();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D6B);
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
          useMaterial3: true,
          cardTheme: const CardThemeData(elevation: 0),
        );
    return AppScope(
      store: widget.store,
      account: widget.account,
      sync: widget.sync,
      prefs: widget.prefs,
      updater: widget.updater,
      support: widget.support,
      child: MaterialApp(
        title: 'מחשבון שכר',
        debugShowCheckedModeBanner: false,
        locale: const Locale('he', 'IL'),
        supportedLocales: const [Locale('he', 'IL')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: ListenableBuilder(
          listenable: widget.account,
          builder: (context, _) =>
              widget.account.isSignedIn || demo ? const HomeShell() : const AuthScreen(welcome: true),
        ),
      ),
    );
  }
}
