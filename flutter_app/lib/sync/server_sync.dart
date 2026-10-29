import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/json.dart';
import '../data/models.dart';
import '../state/store.dart';
import '../support/app_log.dart';
import 'account.dart';

class RemoteData {
  RemoteData({required this.data, required this.revision, required this.updatedAt, this.device});
  final Json data;
  final int revision;
  final String updatedAt;
  final String? device;
}

class SaveResult {
  SaveResult(this.ok, this.revision);
  final bool ok;
  final int? revision;
}

/// The server calls the sync makes (a fake server is used in the tests).
abstract class SyncBackend {
  Future<int> headRevision(String hid);
  Future<RemoteData> fetch(String hid);
  Future<SaveResult> save(String hid, Json data, int expected, String device);
  Future<({String id, int revision})> create(String name, Json data, String device);

  /// Calls `onChange` whenever the household's revision changes on the server; returns how to stop.
  Future<Future<void> Function()> listen(String hid, void Function() onChange);

  /// Adds a version to the household's history on the server (the newest 30 are kept).
  Future<void> saveSnapshot(String hid, Json data, String device, String note);

  /// The household's previous versions, newest first (without their data).
  Future<List<HouseholdVersion>> versions(String hid);

  Future<Json> versionData(int id);
}

class HouseholdVersion {
  HouseholdVersion(Map<String, dynamic> j)
      : id = (j['id'] as num).toInt(),
        revision = (j['revision'] as num?)?.toInt() ?? 0,
        savedAt = DateTime.tryParse(j['saved_at'] as String? ?? '')?.toLocal(),
        device = j['device'] as String?,
        note = j['note'] as String?;
  final int id;
  final int revision;
  final DateTime? savedAt;
  final String? device;
  final String? note;
}

class SupabaseBackend implements SyncBackend {
  SupabaseClient get _c => Supabase.instance.client;

  @override
  Future<int> headRevision(String hid) async {
    final row = await _c.from('households').select('data_revision').eq('id', hid).single();
    return (row['data_revision'] as num).toInt();
  }

  @override
  Future<RemoteData> fetch(String hid) async {
    final row = await _c.from('household_data').select('data,revision,updated_at,device').eq('household_id', hid).single();
    return RemoteData(
      data: (row['data'] as Map).cast<String, dynamic>(),
      revision: (row['revision'] as num).toInt(),
      updatedAt: row['updated_at'] as String,
      device: row['device'] as String?,
    );
  }

  @override
  Future<SaveResult> save(String hid, Json data, int expected, String device) async {
    final r = await _c.rpc('save_household_data',
        params: {'hid': hid, 'p_data': data, 'expected_revision': expected, 'p_device': device}) as Map;
    return SaveResult(r['ok'] == true, (r['revision'] as num?)?.toInt());
  }

  @override
  Future<({String id, int revision})> create(String name, Json data, String device) async {
    final r = await _c.rpc('create_household', params: {'p_name': name, 'p_data': data, 'p_device': device}) as Map;
    return (id: (r['id'] as String).toLowerCase(), revision: (r['revision'] as num).toInt());
  }

  @override
  Future<Future<void> Function()> listen(String hid, void Function() onChange) async {
    final channel = _c.channel('household-$hid');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'households',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: hid),
          callback: (_) => onChange(),
        )
        .subscribe();
    return () async {
      await _c.removeChannel(channel);
    };
  }

  @override
  Future<void> saveSnapshot(String hid, Json data, String device, String note) async {
    await _c.rpc('save_household_snapshot', params: {'hid': hid, 'p_data': data, 'p_device': device, 'p_note': note});
  }

  @override
  Future<List<HouseholdVersion>> versions(String hid) async {
    final rows = await _c
        .from('household_snapshots')
        .select('id,revision,saved_at,device,note')
        .eq('household_id', hid)
        .order('saved_at', ascending: false);
    return rows.map(HouseholdVersion.new).toList();
  }

  @override
  Future<Json> versionData(int id) async {
    final row = await _c.from('household_snapshots').select('data').eq('id', id).single();
    return (row['data'] as Map).cast<String, dynamic>();
  }
}

/// Keeps the household on screen in sync with the server — a port of ServerSync.swift.
///
/// The file on this device stays the app's working copy (it works offline). Each save on the server
/// gets a new revision; the device remembers the revision it last saw. When only the server changed,
/// its version is loaded; when only this device changed, it's saved; when both changed, the newer one
/// wins and the other goes to the household's version history on the server (the newest 30 are kept).
/// Nothing is kept on the device except the encrypted working copy, and it's deleted on sign-out.
class ServerSync extends ChangeNotifier {
  ServerSync({
    required this.store,
    required this.account,
    required this.backend,
    required this.prefs,
    required this.deviceName,
    this.debounceDelay = const Duration(seconds: 2),
    this.retryDelay = const Duration(milliseconds: 500),
    this.pollInterval = const Duration(seconds: 60),
  });

  final AppStore store;
  final SyncAccount account;
  final SyncBackend backend;
  final SharedPreferences prefs;
  final String deviceName;
  final Duration debounceDelay;
  final Duration retryDelay;
  final Duration pollInterval;

  String status = '';
  bool isSyncing = false;
  String? lastError;

  /// Signed in for the first time with data already on this device, and the account has households:
  /// ask whether to upload this data as a new household or use one from the server.
  bool pendingLocalChoice = false;

  Timer? _debounce;
  Timer? _timer;
  Future<void> Function()? _stopListening;
  String? _listeningTo;

  /// The household whose data is in the local file right now.
  String? get linkedHouseholdId => prefs.getString('syncLinkedHousehold');
  set linkedHouseholdId(String? v) =>
      v == null ? prefs.remove('syncLinkedHousehold') : prefs.setString('syncLinkedHousehold', v.toLowerCase());

  int get lastSeenRevision => prefs.getInt('syncLastSeenRevision') ?? 0;
  set lastSeenRevision(int v) => prefs.setInt('syncLastSeenRevision', v);

  /// When this device's data changed without being saved to the server yet.
  DateTime? get localChangedAt {
    final ms = prefs.getInt('syncLocalChangedAt');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set localChangedAt(DateTime? v) => v == null
      ? prefs.remove('syncLocalChangedAt')
      : prefs.setInt('syncLocalChangedAt', v.millisecondsSinceEpoch);

  bool get hasUnsyncedChanges => localChangedAt != null;

  /// The account whose data is in the local copy. null = data from before signing in (the device owner's).
  String? get dataOwner => prefs.getString('syncDataOwner');
  set dataOwner(String? v) => v == null ? prefs.remove('syncDataOwner') : prefs.setString('syncDataOwner', v);

  DateTime? get lastSync {
    final ms = prefs.getInt('syncLastSync');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  void attach() {
    store.onDataChange = _localDidChange;
    _timer ??= Timer.periodic(pollInterval, (_) => sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _debounce?.cancel();
    _stopListening?.call();
    super.dispose();
  }

  // MARK: Which household is on screen

  /// Called whenever the user, their households or the chosen household change.
  Future<void> accountChanged() async {
    if (!account.isSignedIn) {
      await _stop();
      status = '';
      notifyListeners();
      return;
    }
    // Another account's data must never reach this one (a shared device).
    final me = account.userId;
    final owner = dataOwner;
    if (owner != null && me != null && owner != me) {
      await _wipeDevice();
      dataOwner = me;
    }
    if (account.households.isEmpty) await account.refreshHouseholds();

    final linked = linkedHouseholdId;
    if (linked == null) {
      await _linkLocalData();
      return;
    }
    // The chosen household is gone (deleted, or this user was removed): keep the data, stop syncing it.
    if (!account.households.any((h) => h.id == linked)) {
      _unlink();
      if (account.households.isNotEmpty) {
        await switchTo(account.households.first.id, cache: false);
        lastError = 'משק הבית הקודם כבר לא זמין לך (נמחק או שהוסרת ממנו).';
        notifyListeners();
      } else {
        // No household on this account: this device's data becomes its household.
        await createHousehold('משק הבית שלי', from: store.doc);
      }
      return;
    }
    final wanted = account.activeHouseholdId;
    if (wanted != null && wanted != linked && account.households.any((h) => h.id == wanted)) {
      await switchTo(wanted);
      return;
    }
    account.activeHouseholdId = linked;
    await _listen(linked);
    await sync();
  }

  /// First time this device's data meets the account.
  Future<void> _linkLocalData() async {
    if (account.households.isEmpty) {
      // New account: this device's data becomes their first household.
      await createHousehold('משק הבית שלי', from: store.doc);
    } else if (store.isEmpty) {
      await switchTo(account.activeHouseholdId ?? account.households.first.id, cache: false);
    } else {
      pendingLocalChoice = true;
      notifyListeners();
    }
  }

  /// The answer to `pendingLocalChoice`.
  Future<void> resolveLocalChoice({required bool uploadAsNew}) async {
    pendingLocalChoice = false;
    notifyListeners();
    if (uploadAsNew) {
      await createHousehold('משק הבית שלי (מהמכשיר)', from: store.doc);
    } else {
      // This device's data joins the household's version history on the server before it's replaced.
      final target = account.activeHouseholdId ?? account.households.first.id;
      await _uploadVersion(store.doc, target, 'הנתונים שהיו במכשיר לפני החיבור לחשבון');
      await switchTo(target, cache: false);
    }
  }

  Future<void> createHousehold(String name, {Json? from}) async {
    try {
      final data = from ?? Starter.family();
      final created = await backend.create(name, deepCopy(data) as Json, deviceName);
      if (linkedHouseholdId != null) await _cacheCurrent();
      if (from == null) store.replace(data);
      linkedHouseholdId = created.id;
      lastSeenRevision = created.revision;
      localChangedAt = null;
      await account.refreshHouseholds();
      account.activeHouseholdId = created.id;
      _markSynced('משק הבית נוצר ונשמר בשרת');
      await _listen(created.id);
    } catch (e) {
      lastError = UserAccount.describe(e);
      notifyListeners();
    }
  }

  /// Shows another household: this one is kept in a cache on the device, then the other is loaded.
  Future<void> switchTo(String id, {bool cache = true}) async {
    id = id.toLowerCase();
    final current = linkedHouseholdId;
    if (current != null) {
      if (current == id) return;
      await sync(); // push what's pending first
      if (cache) await _cacheCurrent();
    }
    final cached = await _readCache(id);
    if (cached != null) {
      store.replace(cached.family);
      lastSeenRevision = cached.revision;
    } else {
      lastSeenRevision = 0; // nothing on the device yet: the server's version is loaded below
    }
    linkedHouseholdId = id;
    localChangedAt = null;
    account.activeHouseholdId = id;
    await _listen(id);
    await sync();
  }

  /// Signing out (or deleting the account): last changes go up, then the encrypted copy on this device is deleted.
  Future<void> signedOut() async {
    await sync();
    await _stop();
    await _wipeDevice();
    notifyListeners();
  }

  /// Nothing of this account stays on the device: the encrypted files and their key are deleted,
  /// and the screen shows an empty household until someone signs in.
  Future<void> _wipeDevice() async {
    _unlink();
    await store.wipe();
    dataOwner = null;
    account.activeHouseholdId = null;
    prefs.remove('syncLastSync');
    status = '';
    lastError = null;
  }

  void _unlink() {
    linkedHouseholdId = null;
    lastSeenRevision = 0;
    localChangedAt = null;
  }

  // MARK: Triggers

  void _localDidChange() {
    if (linkedHouseholdId == null || !account.isSignedIn) return;
    localChangedAt = DateTime.now();
    status = 'יש שינויים שעוד לא נשמרו בשרת';
    notifyListeners();
    _schedule(debounceDelay);
  }

  void _schedule(Duration delay) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => sync());
  }

  Future<void> _listen(String? id) async {
    if (_listeningTo == id) return;
    await _stop();
    if (id == null) return;
    _listeningTo = id;
    try {
      _stopListening = await backend.listen(id, () => sync());
    } catch (_) {
      // Realtime is a bonus; the check every 60 seconds still runs.
    }
  }

  Future<void> _stop() async {
    final stop = _stopListening;
    _stopListening = null;
    _listeningTo = null;
    if (stop != null) {
      try {
        await stop();
      } catch (_) {}
    }
  }

  // MARK: Sync

  Future<void> sync() async {
    final hid = linkedHouseholdId;
    if (!account.isSignedIn || hid == null || isSyncing) return;
    isSyncing = true;
    notifyListeners();
    try {
      final head = await backend.headRevision(hid);
      if (head > lastSeenRevision) {
        final remote = await backend.fetch(hid);
        final remoteDate = DateTime.tryParse(remote.updatedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final mine = localChangedAt;
        if (mine != null && mine.isAfter(remoteDate)) {
          // Both changed, this device is newer: ours is saved, and the server keeps its version in the history.
          await _push(hid, remote.revision);
        } else {
          _apply(remote.data, backupFirst: localChangedAt != null);
          localChangedAt = null;
          lastSeenRevision = remote.revision;
          _markSynced('עודכן מ-${remote.device ?? 'השרת'}');
        }
      } else if (localChangedAt != null) {
        await _push(hid, lastSeenRevision);
      } else {
        _markSynced('מסונכרן');
      }
    } catch (e) {
      _handle(e);
    } finally {
      isSyncing = false;
      notifyListeners();
    }
    // A change made while this round was running waits for the next one.
    if (localChangedAt != null && !(_debounce?.isActive ?? false)) _schedule(debounceDelay);
  }

  Future<void> _push(String hid, int expected) async {
    final changedBefore = localChangedAt;
    final result = await backend.save(hid, deepCopy(store.doc) as Json, expected, deviceName);
    if (result.ok && result.revision != null) {
      lastSeenRevision = result.revision!;
      // A change made while saving stays pending for the next round.
      if (localChangedAt == changedBefore) localChangedAt = null;
      _markSynced('נשמר בשרת');
    } else {
      // Someone saved in between — the next round loads it and decides.
      AppLog.add('sync', 'התנגשות: יש גרסה חדשה בשרת (ציפינו ל-$expected)');
      status = 'יש גרסה חדשה בשרת — מסנכרן…';
      _schedule(retryDelay);
    }
  }

  void _handle(Object error) {
    final text = error.toString().toLowerCase() +
        (error is PostgrestException ? ' ${error.code ?? ''} ${error.message}'.toLowerCase() : '');
    if (text.contains('not a member') || text.contains('pgrst116')) {
      // Removed from the household, or it was deleted.
      () async {
        await account.refreshHouseholds();
        await accountChanged();
      }();
      return;
    }
    lastError = UserAccount.describe(error);
    AppLog.add('sync', 'שגיאה: $error');
  }

  void _markSynced(String message) {
    AppLog.add('sync', '$message (rev $lastSeenRevision)');
    // From now on the data on this device belongs to this account.
    final me = account.userId;
    if (me != null) dataOwner = me;
    status = message;
    lastError = null;
    prefs.setInt('syncLastSync', DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
  }

  void _apply(Json remote, {required bool backupFirst}) {
    // The version being replaced goes to the server's history (not to a file on the device).
    final hid = linkedHouseholdId;
    if (backupFirst && hid != null) _uploadVersion(deepCopy(store.doc) as Json, hid, 'גרסה מהמכשיר שהוחלפה בסנכרון');
    if (FamilyBackup(remote).state.members.isEmpty) return;
    store.replace(remote);
  }

  Future<void> _uploadVersion(Json data, String hid, String note) async {
    try {
      await backend.saveSnapshot(hid, data, deviceName, note);
    } catch (e) {
      lastError = UserAccount.describe(e);
      notifyListeners();
    }
  }

  // MARK: Version history (replaces local backups)

  Future<List<HouseholdVersion>> versions() async {
    final hid = linkedHouseholdId;
    if (hid == null) return [];
    return backend.versions(hid);
  }

  /// Brings back an earlier version: it becomes the current one on every device (what's there now joins the history).
  Future<void> restore(HouseholdVersion version) async {
    final data = await backend.versionData(version.id);
    _apply(data, backupFirst: false);
    localChangedAt = DateTime.now();
    await sync();
  }

  // MARK: Cache of the households not on screen

  Directory get _cacheFolder => Directory('${store.folder.path}/households');

  Future<void> _cacheCurrent() async {
    final id = linkedHouseholdId;
    if (id == null) return;
    _cacheFolder.createSync(recursive: true);
    await store.secure.write(File('${_cacheFolder.path}/$id.json'),
        jsonEncode({'revision': lastSeenRevision, 'family': store.doc}));
  }

  Future<({int revision, Json family})?> _readCache(String id) async {
    try {
      final text = await store.secure.read(File('${_cacheFolder.path}/$id.json'));
      if (text == null) return null;
      final j = jsonDecode(text) as Map;
      return (revision: (j['revision'] as num).toInt(), family: (j['family'] as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
