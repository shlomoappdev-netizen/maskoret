import 'json.dart';
import 'models.dart';

/// The member actions of Family.swift (addMember / updateMember / deleteMember) on the shared document.
class FamilyActions {
  FamilyActions(this.family);
  final FamilyBackup family;

  JObj get _state => JObj.lazy(family.json, 'state');

  /// `newMemberFile()`: a starter budget with the current tax rates, rate settings and prime of `from`.
  static Json newMemberFile(SaveFile? from) {
    final file = Starter.memberFile(ratesFrom: from?.budget.ratesJson, moneyFrom: from?.money);
    if (from != null) {
      final source = JObj(from.json);
      for (final k in ['ratesURL', 'lastRatesCheck']) {
        if (source.has(k)) file[k] = source.raw(k);
      }
      final money = from.money.raw;
      for (final k in ['boiRate', 'nextRateDecision']) {
        if (money[k] != null) (file['money'] as Json)[k] = money[k];
      }
    }
    return file;
  }

  /// Adds a member with empty data; returns its id (the caller switches to it).
  String add({required String name, required String emoji, SaveFile? copyFrom}) {
    final id = newId();
    _state.addObject('members', {'id': id, 'name': name.trim().isEmpty ? 'בן משפחה' : name.trim(), 'emoji': emoji.trim().isEmpty ? '🙂' : emoji.trim()});
    final files = family.json['files'];
    if (files is Map) {
      files[id] = newMemberFile(copyFrom);
    } else {
      family.json['files'] = {id: newMemberFile(copyFrom)};
    }
    _state.set('viewIDs', [id]);
    return id;
  }

  void update(String id, {required String name, required String emoji}) {
    final m = _state.objects('members').where((m) => m['id'] == id).firstOrNull;
    if (m == null) return;
    m['name'] = name.trim();
    m['emoji'] = emoji.trim().isEmpty ? '🙂' : emoji.trim();
  }

  /// Deletes a member and their data (never the first one). `activeId` is the member edited on this device;
  /// returns the member to edit next.
  String delete(String id, String activeId) {
    final state = family.state;
    if (id == state.primaryID || state.members.length < 2) return activeId;
    final next = id == activeId ? state.primaryID : activeId;
    _state.removeWhere('members', (m) => m['id'] == id);
    (family.json['files'] as Map?)?.remove(id);
    final view = state.viewIDs.where((v) => v != id).toList();
    _state.set('viewIDs', view.isEmpty ? [next] : view);
    if (state.activeID == id) _state.set('activeID', next);
    return next;
  }
}
