import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/json.dart';
import '../data/models.dart';
import 'secure_file.dart';

/// The household on this device: the whole `FamilyBackup` document. It's a temporary working copy
/// (fast start, works offline), kept encrypted; the server is the source of truth and `ServerSync`
/// keeps the two in step. Signing out deletes it.
class AppStore extends ChangeNotifier {
  AppStore._(this.secure, this.prefs, this.doc);

  /// Loads the encrypted copy (or plain JSON from an older version, which is then encrypted).
  static Future<AppStore> open(Directory folder, SharedPreferences prefs, KeyStore keys) async {
    final secure = SecureFile(folder, keys);
    final file = File('${folder.path}/household.json');
    Json? loaded;
    var wasPlain = false;
    if (file.existsSync()) {
      wasPlain = !SecureFile.isEncrypted(await file.readAsBytes());
      try {
        final text = await secure.read(file);
        if (text != null) loaded = (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    final store = AppStore._(secure, prefs, loaded ?? Starter.family());
    store._fixActiveMember();
    if (loaded == null || wasPlain) await store._write();
    return store;
  }

  final SecureFile secure;
  final SharedPreferences prefs;

  Json doc;

  Directory get folder => secure.folder;

  /// Called after every change made on this device (not for data that came from the server).
  VoidCallback? onDataChange;

  File get _file => File('${folder.path}/household.json');

  FamilyBackup get family => FamilyBackup(doc);
  List<FamilyMember> get members => family.state.members;

  /// The member being edited on this device (like Swift, this choice is per device).
  String get activeMemberId => prefs.getString('activeMemberID') ?? family.state.activeID;
  set activeMemberId(String id) {
    prefs.setString('activeMemberID', id);
    notifyListeners();
  }

  FamilyMember? get activeMember {
    for (final m in members) {
      if (m.id == activeMemberId) return m;
    }
    return null;
  }

  void _fixActiveMember() {
    final ids = members.map((m) => m.id).toSet();
    if (!ids.contains(prefs.getString('activeMemberID'))) {
      final fromDoc = family.state.activeID;
      prefs.setString('activeMemberID', ids.contains(fromDoc) ? fromDoc : family.state.primaryID);
    }
  }

  SaveFile get file => family.fileForEditing(activeMemberId);
  Budget get budget => file.budget;
  MoneyData get money => file.money;

  /// Every edit goes through here: it changes the document in place, saves, and tells the sync.
  void edit(void Function(SaveFile file) change) {
    change(file);
    _write();
    notifyListeners();
    onDataChange?.call();
  }

  /// Changes to the household itself (family members): like [edit], on the whole document.
  void editFamily(void Function(FamilyBackup family) change) {
    change(family);
    _fixActiveMember();
    _write();
    notifyListeners();
    onDataChange?.call();
  }

  /// Replaces everything with another household's data (from the server or the cache).
  void replace(Json newDoc) {
    doc = newDoc;
    _fixActiveMember();
    _write();
    notifyListeners();
  }

  Future<void> _pending = Future.value();

  /// Saves are queued, so an older copy never overwrites a newer one.
  Future<void> _write() {
    final text = jsonEncode(doc);
    return _pending = _pending.then((_) => secure.write(_file, text)).catchError((Object e) {
      debugPrint('Save failed: $e');
    });
  }

  /// Waits until everything is on disk (used before wiping, and by the tests).
  Future<void> flush() => _pending;

  /// Signing out: the encrypted files and their key are deleted, and an empty household is shown.
  Future<void> wipe() async {
    await flush();
    await secure.wipeAll();
    prefs.remove('activeMemberID');
    doc = Starter.family();
    _fixActiveMember();
    notifyListeners();
  }

  /// Like Swift's `ServerSync.isEmpty`: data that was never really used.
  bool get isEmpty {
    if (members.length > 1) return false;
    final f = family.file(activeMemberId);
    if (f == null) return true;
    return f.history.isEmpty &&
        f.money.transactions.isEmpty &&
        f.money.cardTransactionCount == 0 &&
        f.budget.gross == 0;
  }
}
