import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/state/secure_file.dart';
import 'package:maskoret/state/store.dart';
import 'package:maskoret/sync/account.dart';
import 'package:maskoret/sync/server_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'compat_test.dart' show diff, loadFixture;

/// The server side of `save_household_data` / `households.data_revision`, in memory.
class FakeServer implements SyncBackend {
  final households = <String, ({Json data, int revision, DateTime updatedAt, String? device})>{};
  var saves = 0;
  final snapshots = <({String hid, Json data, String note})>[];

  Json data(String hid) => (jsonDecode(jsonEncode(households[hid]!.data)) as Map).cast<String, dynamic>();

  /// Another device (the iPhone) saves.
  void saveFromOtherDevice(String hid, Json data, {DateTime? at}) {
    final h = households[hid]!;
    households[hid] = (data: deepCopy(data) as Json, revision: h.revision + 1, updatedAt: at ?? DateTime.now(), device: 'iPhone');
  }

  @override
  Future<int> headRevision(String hid) async => households[hid]!.revision;

  @override
  Future<RemoteData> fetch(String hid) async {
    final h = households[hid]!;
    return RemoteData(data: data(hid), revision: h.revision, updatedAt: h.updatedAt.toUtc().toIso8601String(), device: h.device);
  }

  @override
  Future<SaveResult> save(String hid, Json data, int expected, String device) async {
    final h = households[hid]!;
    if (h.revision != expected) return SaveResult(false, null);
    saves++;
    households[hid] = (data: jsonDecode(jsonEncode(data)) as Json, revision: h.revision + 1, updatedAt: DateTime.now(), device: device);
    return SaveResult(true, h.revision + 1);
  }

  @override
  Future<({String id, int revision})> create(String name, Json data, String device) async {
    final id = 'h${households.length + 1}';
    households[id] = (data: jsonDecode(jsonEncode(data)) as Json, revision: 1, updatedAt: DateTime.now(), device: device);
    return (id: id, revision: 1);
  }

  @override
  Future<Future<void> Function()> listen(String hid, void Function() onChange) async => () async {};

  @override
  Future<void> saveSnapshot(String hid, Json data, String device, String note) async =>
      snapshots.add((hid: hid, data: jsonDecode(jsonEncode(data)) as Json, note: note));

  @override
  Future<List<HouseholdVersion>> versions(String hid) async => [
        for (var i = 0; i < snapshots.length; i++)
          if (snapshots[i].hid == hid) HouseholdVersion({'id': i, 'revision': 0, 'note': snapshots[i].note}),
      ];

  @override
  Future<Json> versionData(int id) async => jsonDecode(jsonEncode(snapshots[id].data)) as Json;
}

class MemoryKeyStore implements KeyStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

class FakeAccount extends ChangeNotifier implements SyncAccount {
  FakeAccount(this.server);
  final FakeServer server;
  @override
  bool isSignedIn = true;
  @override
  String? userId = 'user-a';
  @override
  String? activeHouseholdId;
  @override
  List<HouseholdInfo> get households =>
      server.households.keys.map((id) => HouseholdInfo.local(id, id)).toList();
  @override
  Future<void> refreshHouseholds() async {}
}

void main() {
  late Directory dir;
  late FakeServer server;
  late AppStore store;
  late ServerSync sync;
  late FakeAccount account;
  late MemoryKeyStore keys;

  Future<void> setUpDevice({bool withHousehold = true}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('maskoret_test');
    server = FakeServer();
    if (withHousehold) {
      server.households['h1'] = (data: loadFixture(), revision: 7, updatedAt: DateTime(2026, 10, 28, 20), device: 'iPhone');
    }
    keys = MemoryKeyStore();
    store = await AppStore.open(dir, prefs, keys);
    account = FakeAccount(server);
    sync = ServerSync(
      store: store,
      account: account,
      backend: server,
      prefs: prefs,
      deviceName: 'Android test',
      debounceDelay: const Duration(milliseconds: 10),
      retryDelay: const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
    )..attach();
  }

  tearDown(() async {
    try {
      await store.flush();
      sync.dispose();
      dir.deleteSync(recursive: true);
    } on Error {
      // A test that didn't set up a device.
    }
  });

  test('signing in on a new device shows the household from the server, unchanged', () async {
    await setUpDevice();
    await sync.accountChanged();
    expect(sync.linkedHouseholdId, 'h1');
    expect(sync.lastSeenRevision, 7);
    expect(diff(loadFixture(), store.doc), isEmpty);
    expect(server.saves, 0, reason: 'just looking must not write to the server');
  });

  test('a change on Android reaches the server and keeps every other field', () async {
    await setUpDevice();
    await sync.accountChanged();
    final original = loadFixture();
    final member = store.activeMemberId;

    store.edit((f) => f.budget.incomes.first.amount = 9999);
    expect(sync.hasUnsyncedChanges, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100)); // the debounce fires the sync

    expect(server.saves, 1);
    expect(server.households['h1']!.revision, 8);
    expect(sync.lastSeenRevision, 8);
    expect(sync.hasUnsyncedChanges, isFalse);
    final onServer = server.data('h1');
    final index = (original['files'][member]['budget']['incomes'] as List)
        .indexWhere((i) => i['id'] == store.budget.incomes.first.id);
    expect(diff(original, onServer), ['/files/$member/budget/incomes[$index]/amount']);
    expect(onServer['files'][member]['budget']['incomes'][index]['amount'], 9999);
  });

  test('a change from the iPhone is loaded', () async {
    await setUpDevice();
    await sync.accountChanged();
    final changed = loadFixture();
    final member = store.activeMemberId;
    (changed['files'][member]['budget']['expenses'] as List).first['value'] = 777;
    server.saveFromOtherDevice('h1', changed);
    await sync.sync();
    expect(store.budget.expenses.first.value, 777);
    expect(sync.lastSeenRevision, 8);
    expect(diff(changed, store.doc), isEmpty);
  });

  test('both changed, the server is newer: the server wins and this device\'s version goes to the server history', () async {
    await setUpDevice();
    await sync.accountChanged();
    final member = store.activeMemberId;
    sync.store.onDataChange = null; // edit without triggering the debounce
    store.edit((f) => f.budget.incomes.first.amount = 1);
    sync.localChangedAt = DateTime.now().subtract(const Duration(minutes: 5));
    final theirs = loadFixture();
    (theirs['files'][member]['budget']['incomes'] as List).first['amount'] = 2;
    server.saveFromOtherDevice('h1', theirs);

    await sync.sync();
    expect(store.budget.incomes.first.amount, 2);
    expect(sync.hasUnsyncedChanges, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(server.snapshots.single.note, 'גרסה מהמכשיר שהוחלפה בסנכרון');
    expect(server.snapshots.single.data['files'][member]['budget']['incomes'][0]['amount'], 1);
  });

  test('both changed, this device is newer: ours is saved (the server keeps its own version in its history)', () async {
    await setUpDevice();
    await sync.accountChanged();
    final member = store.activeMemberId;
    final theirs = loadFixture();
    (theirs['files'][member]['budget']['incomes'] as List).first['amount'] = 2;
    server.saveFromOtherDevice('h1', theirs, at: DateTime.now().subtract(const Duration(minutes: 5)));
    sync.store.onDataChange = null;
    store.edit((f) => f.budget.incomes.first.amount = 1);
    sync.localChangedAt = DateTime.now();

    await sync.sync();
    expect(server.households['h1']!.revision, 9);
    expect(server.data('h1')['files'][member]['budget']['incomes'][0]['amount'], 1);
    expect(dir.listSync(recursive: true).whereType<File>().where((f) => f.path.contains('backup')), isEmpty);
  });

  test('a new account with no households uploads this device as the first household', () async {
    await setUpDevice(withHousehold: false);
    await sync.accountChanged();
    expect(server.households.keys, ['h1']);
    expect(sync.linkedHouseholdId, 'h1');
    final onServer = FamilyBackup(server.data('h1'));
    expect(onServer.state.members.single.name, 'אני');
  });

  test('the copy on the device is encrypted, and signing out deletes it with its key', () async {
    await setUpDevice();
    await sync.accountChanged();
    await store.flush();
    final file = File('${dir.path}/household.json');
    final bytes = file.readAsBytesSync();
    expect(SecureFile.isEncrypted(bytes), isTrue);
    expect(utf8.decode(bytes, allowMalformed: true).contains('cardTransactions'), isFalse);
    expect(keys.value, isNotNull);

    await sync.signedOut();
    expect(keys.value, isNull);
    expect(file.existsSync(), isFalse);
    expect(sync.linkedHouseholdId, isNull);
    expect(store.members.single.name, 'אני');
    expect(store.budget.gross, 0);
  });

  test('plain JSON from an older version is read and then encrypted', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final d = await Directory.systemTemp.createTemp('maskoret_plain');
    File('${d.path}/household.json').writeAsStringSync(jsonEncode(loadFixture()));
    final k = MemoryKeyStore();
    final s = await AppStore.open(d, prefs, k);
    expect(diff(loadFixture(), s.doc), isEmpty);
    expect(SecureFile.isEncrypted(File('${d.path}/household.json').readAsBytesSync()), isTrue);
    final again = await AppStore.open(d, prefs, k);
    expect(diff(loadFixture(), again.doc), isEmpty);
    d.deleteSync(recursive: true);
  });

  test('another account signing in on this device starts empty and never gets the previous data', () async {
    await setUpDevice();
    await sync.accountChanged();
    expect(sync.dataOwner, 'user-a');
    expect(store.budget.incomes, isNotEmpty);

    // user-b signs in on the same device; they have no households.
    account.userId = 'user-b';
    server.households.clear();
    await sync.accountChanged();
    expect(sync.dataOwner, 'user-b');
    final created = FamilyBackup(server.data(server.households.keys.single));
    expect(created.state.members.single.name, 'אני', reason: 'user-a\'s family must not be uploaded to user-b');
    expect(jsonEncode(server.data(server.households.keys.single)).contains('cardTransactions'), isFalse);
  });

  test('using the server household keeps the device data in the server history first', () async {
    await setUpDevice();
    store.edit((f) => f.budget.incomes.first.amount = 5000); // data on the device before signing in
    await sync.accountChanged();
    expect(sync.pendingLocalChoice, isTrue);
    await sync.resolveLocalChoice(uploadAsNew: false);
    expect(server.snapshots.single.note, 'הנתונים שהיו במכשיר לפני החיבור לחשבון');
    expect(diff(loadFixture(), store.doc), isEmpty);
  });

  test('restoring a previous version makes it current everywhere', () async {
    await setUpDevice();
    await sync.accountChanged();
    final old = loadFixture();
    (old['files'][store.activeMemberId]['budget']['incomes'] as List).first['amount'] = 31;
    server.snapshots.add((hid: 'h1', data: old, note: 'x'));
    await sync.restore((await sync.versions()).single);
    expect(store.budget.incomes.first.amount, 31);
    expect(server.data('h1')['files'][store.activeMemberId]['budget']['incomes'][0]['amount'], 31);
  });
}
