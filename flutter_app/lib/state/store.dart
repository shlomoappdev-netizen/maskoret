import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/json.dart';
import '../data/models.dart';

/// The household on this device: the whole `FamilyBackup` document, kept as JSON in one file.
/// It's the app's working copy (works offline); `ServerSync` keeps it in step with the server.
class AppStore extends ChangeNotifier {
  AppStore(this.folder, this.prefs) {
    final f = _file;
    Json? loaded;
    if (f.existsSync()) {
      try {
        loaded = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
      } catch (_) {
        // A damaged file is kept aside, and a fresh household starts.
        f.copySync('${f.path}.damaged-${DateTime.now().millisecondsSinceEpoch}');
      }
    }
    doc = loaded ?? Starter.family();
    if (loaded == null) _write();
    _fixActiveMember();
  }

  final Directory folder;
  final SharedPreferences prefs;

  late Json doc;

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

  /// Replaces everything with another household's data (from the server or the cache).
  void replace(Json newDoc) {
    doc = newDoc;
    _fixActiveMember();
    _write();
    notifyListeners();
  }

  void _write() {
    folder.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(doc));
    tmp.renameSync(_file.path);
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

  // MARK: Backups (kept on this device)

  Directory get backupFolder => Directory('${folder.path}/backups');

  void backupNow(String suffix, [Json? data]) {
    backupFolder.createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    File('${backupFolder.path}/גיבוי $stamp$suffix.json').writeAsStringSync(jsonEncode(data ?? doc));
  }

  List<File> get backups {
    if (!backupFolder.existsSync()) return [];
    final list = backupFolder.listSync().whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return list;
  }
}
