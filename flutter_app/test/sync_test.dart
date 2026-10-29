import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/state/store.dart';
import 'package:maskoret/sync/account.dart';
import 'package:maskoret/sync/server_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'compat_test.dart' show diff, loadFixture;

/// The server side of `save_household_data` / `households.data_revision`, in memory.
class FakeServer implements SyncBackend {
  final households = <String, ({Json data, int revision, DateTime updatedAt, String? device})>{};
  var saves = 0;

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
}

class FakeAccount extends ChangeNotifier implements SyncAccount {
  FakeAccount(this.server);
  final FakeServer server;
  @override
  bool isSignedIn = true;
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

  Future<void> setUpDevice({bool withHousehold = true}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    dir = await Directory.systemTemp.createTemp('maskoret_test');
    server = FakeServer();
    if (withHousehold) {
      server.households['h1'] = (data: loadFixture(), revision: 7, updatedAt: DateTime(2026, 10, 28, 20), device: 'iPhone');
    }
    store = AppStore(dir, prefs);
    sync = ServerSync(
      store: store,
      account: FakeAccount(server),
      backend: server,
      prefs: prefs,
      deviceName: 'Android test',
      debounceDelay: const Duration(milliseconds: 10),
      retryDelay: const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
    )..attach();
  }

  tearDown(() {
    sync.dispose();
    dir.deleteSync(recursive: true);
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

  test('both changed, the server is newer: the server wins and this device keeps a backup', () async {
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
    expect(store.backups, isNotEmpty);
    final backup = jsonDecode(store.backups.first.readAsStringSync());
    expect(backup['files'][member]['budget']['incomes'][0]['amount'], 1);
  });

  test('both changed, this device is newer: ours is saved and the server version is backed up', () async {
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
    final backup = jsonDecode(store.backups.first.readAsStringSync());
    expect(backup['files'][member]['budget']['incomes'][0]['amount'], 2);
  });

  test('a new account with no households uploads this device as the first household', () async {
    await setUpDevice(withHousehold: false);
    await sync.accountChanged();
    expect(server.households.keys, ['h1']);
    expect(sync.linkedHouseholdId, 'h1');
    final onServer = FamilyBackup(server.data('h1'));
    expect(onServer.state.members.single.name, 'אני');
  });
}
