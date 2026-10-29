import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'state/store.dart';
import 'sync/account.dart';
import 'sync/server_sync.dart';
import 'ui/auth_screen.dart';
import 'ui/common.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('he');
  await Supabase.initialize(url: SupabaseConfig.url, anonKey: SupabaseConfig.anonKey);
  final prefs = await SharedPreferences.getInstance();
  final support = await getApplicationSupportDirectory();
  final store = AppStore(Directory('${support.path}/Maskoret'), prefs);
  final account = UserAccount(prefs);
  final sync = ServerSync(
    store: store,
    account: account,
    backend: SupabaseBackend(),
    prefs: prefs,
    deviceName: await _deviceName(),
  )..attach();
  account.onChanged = sync.accountChanged;
  account.start();
  runApp(MaskoretApp(store: store, account: account, sync: sync, prefs: prefs));
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
  const MaskoretApp({super.key, required this.store, required this.account, required this.sync, required this.prefs});
  final AppStore store;
  final UserAccount account;
  final ServerSync sync;
  final SharedPreferences prefs;

  @override
  State<MaskoretApp> createState() => _MaskoretAppState();
}

class _MaskoretAppState extends State<MaskoretApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back in the app: check the server right away.
    _lifecycle = AppLifecycleListener(onResume: widget.sync.sync);
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
          builder: (context, _) {
            final localOnly = widget.prefs.getBool('localOnly') ?? false;
            if (widget.account.isSignedIn || localOnly) return const HomeShell();
            return AuthScreen(
              onContinueWithout: () {
                widget.prefs.setBool('localOnly', true);
                setState(() {});
              },
            );
          },
        ),
      ),
    );
  }
}
