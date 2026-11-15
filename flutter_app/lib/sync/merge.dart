/// Three-way merge of the household document, used when this device and the server both changed it since
/// the last version they agreed on (`base`). The same rules as SyncMerge.swift:
/// - A value only one side changed takes that side's value.
/// - Objects merge key by key.
/// - Lists of objects that all have a unique "id" merge item by item: items added on either side are kept,
///   an item deleted on one side is dropped unless the other side edited it, edited items merge recursively.
/// - Lists of unique strings (lists of ids) merge as sets.
/// - When both sides changed the same plain value differently, the side that changed later wins
///   (`preferLocal`) and it is counted as a conflict (the caller keeps the losing version in the server's history).
/// Without a base (a device that synced before this existed), everything is treated as changed on both sides,
/// so items from both are kept and the later side wins on the rest.
class MergeResult {
  MergeResult(this.value, this.conflicts);
  final Map<String, dynamic> value;

  /// Paths where both sides changed the same value differently (the later side's value was taken).
  final List<String> conflicts;
}

MergeResult mergeDocuments(Map<String, dynamic>? base, Map<String, dynamic> local, Map<String, dynamic> remote,
    {bool preferLocal = false}) {
  final conflicts = <String>[];
  final merged = _merge(base ?? _missing, local, remote, conflicts, '', preferLocal);
  return MergeResult((merged as Map).cast<String, dynamic>(), conflicts);
}

class _Missing {
  const _Missing();
}

const _missing = _Missing();

bool deepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The ids of a list whose items are all objects with a unique, non-empty string "id"; null otherwise.
List<String>? _ids(dynamic v) {
  if (v is! List) return null;
  final ids = <String>[];
  for (final item in v) {
    if (item is! Map) return null;
    final id = item['id'];
    if (id is! String || id.isEmpty) return null;
    ids.add(id);
  }
  return ids.toSet().length == ids.length ? ids : null;
}

bool _isStringSet(dynamic v) => v is List && v.every((e) => e is String) && v.toSet().length == v.length;

dynamic _merge(dynamic b, dynamic l, dynamic r, List<String> conflicts, String path, bool preferLocal) {
  if (deepEquals(l, r)) return l;
  if (deepEquals(l, b)) return r;
  if (deepEquals(r, b)) return l;

  // Both changed it.
  if (l is Map && r is Map) {
    final bm = b is Map ? b : const <String, dynamic>{};
    final out = <String, dynamic>{};
    for (final k in [...l.keys, ...r.keys.where((k) => !l.containsKey(k))]) {
      final v = _merge(bm.containsKey(k) ? bm[k] : _missing, l.containsKey(k) ? l[k] : _missing,
          r.containsKey(k) ? r[k] : _missing, conflicts, '$path/$k', preferLocal);
      if (v is! _Missing) out[k as String] = v;
    }
    return out;
  }

  final lIds = _ids(l), rIds = _ids(r);
  if (lIds != null && rIds != null) {
    final bList = _ids(b) != null ? b as List : const [];
    final bById = {for (final x in bList) (x as Map)['id'] as String: x};
    final lById = {for (final x in l as List) (x as Map)['id'] as String: x};
    final rById = {for (final x in r as List) (x as Map)['id'] as String: x};
    final out = <dynamic>[];
    for (final item in r) {
      final id = (item as Map)['id'] as String;
      final inBase = bById.containsKey(id);
      if (lById.containsKey(id)) {
        out.add(_merge(inBase ? bById[id] : _missing, lById[id], item, conflicts, '$path[$id]', preferLocal));
      } else if (!inBase) {
        out.add(item); // added on the server
      } else if (!deepEquals(item, bById[id])) {
        out.add(item); // deleted here, but edited on the server: the edit is kept
        conflicts.add('$path[$id]');
      } // else: deleted here
    }
    for (final item in l) {
      final id = (item as Map)['id'] as String;
      if (rById.containsKey(id)) continue;
      if (!bById.containsKey(id)) {
        out.add(item); // added here
      } else if (!deepEquals(item, bById[id])) {
        out.add(item); // edited here, deleted on the server: the edit is kept
        conflicts.add('$path[$id]');
      } // else: deleted on the server
    }
    return out;
  }

  if (_isStringSet(l) && _isStringSet(r)) {
    final bSet = _isStringSet(b) ? (b as List).cast<String>().toSet() : <String>{};
    final lSet = (l as List).cast<String>().toSet(), rSet = (r as List).cast<String>().toSet();
    return [
      for (final x in rSet)
        if (lSet.contains(x) || !bSet.contains(x)) x,
      for (final x in lSet)
        if (!rSet.contains(x) && !bSet.contains(x)) x,
    ];
  }

  // The same plain value changed on both sides.
  if (r is _Missing) return l; // deleted on the server, changed here: keep the change
  if (l is _Missing) return r;
  conflicts.add(path);
  return preferLocal ? l : r;
}
