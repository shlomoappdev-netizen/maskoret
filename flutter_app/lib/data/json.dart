import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Helpers for reading and writing the Swift app's JSON exactly as Swift's `JSONEncoder` does:
/// dates are seconds since 2001-01-01 (`timeIntervalSinceReferenceDate`), UUIDs are uppercase,
/// optionals that are nil are left out.
typedef Json = Map<String, dynamic>;

const _referenceEpochSeconds = 978307200; // 2001-01-01T00:00:00Z

DateTime swiftDateToDateTime(num seconds) =>
    DateTime.fromMicrosecondsSinceEpoch(((seconds + _referenceEpochSeconds) * 1e6).round());

num dateTimeToSwift(DateTime d) => jsonNumber(d.microsecondsSinceEpoch / 1e6 - _referenceEpochSeconds);

/// Whole numbers are written as integers, like Swift writes `5000` for `5000.0`.
num jsonNumber(num v) {
  if (v is double && v.isFinite && v == v.roundToDouble() && v.abs() < 1e15) return v.toInt();
  return v;
}

String newId() => const Uuid().v4().toUpperCase();

/// Deep copy of a JSON value.
dynamic deepCopy(dynamic v) => jsonDecode(jsonEncode(v));

/// A view over one JSON object of the shared document. Reads fall back to the Swift defaults when a key
/// is missing; writes change only the key being written, so every other key (including ones this app
/// doesn't know yet) stays exactly as it was.
class JObj {
  JObj(Json map) : _map = map, _parent = null, _key = null;

  /// An object that may not exist yet: it's created inside `parent[key]` on the first write.
  JObj.lazy(Json parent, String key) : _map = null, _parent = parent, _key = key;

  Json? _map;
  final Json? _parent;
  final String? _key;

  Json? get readMap {
    if (_map != null) return _map;
    final v = _parent![_key!];
    return v is Json ? v : (v is Map ? v.cast<String, dynamic>() : null);
  }

  Json get writeMap {
    if (_map != null) return _map!;
    final v = _parent![_key!];
    if (v is Map<String, dynamic>) return _map = v;
    final created = <String, dynamic>{};
    _parent[_key!] = created;
    return _map = created;
  }

  dynamic raw(String k) => readMap?[k];
  bool has(String k) => readMap?.containsKey(k) == true && readMap![k] != null;

  double d(String k, [double def = 0]) {
    final v = raw(k);
    return v is num ? v.toDouble() : def;
  }

  double? dOpt(String k) {
    final v = raw(k);
    return v is num ? v.toDouble() : null;
  }

  int i(String k, [int def = 0]) {
    final v = raw(k);
    return v is num ? v.toInt() : def;
  }

  int? iOpt(String k) {
    final v = raw(k);
    return v is num ? v.toInt() : null;
  }

  String s(String k, [String def = '']) {
    final v = raw(k);
    return v is String ? v : def;
  }

  String? sOpt(String k) {
    final v = raw(k);
    return v is String ? v : null;
  }

  bool b(String k, [bool def = false]) {
    final v = raw(k);
    return v is bool ? v : def;
  }

  DateTime? date(String k) {
    final v = raw(k);
    return v is num ? swiftDateToDateTime(v) : null;
  }

  /// Sets a value; null removes the key (Swift leaves nil optionals out).
  void set(String k, dynamic v) {
    if (v == null) {
      if (readMap?.containsKey(k) == true) writeMap.remove(k);
      return;
    }
    if (v is DateTime) v = dateTimeToSwift(v);
    if (v is num) v = jsonNumber(v);
    final current = readMap?[k];
    if (current == v && current != null) return; // unchanged — don't create anything
    writeMap[k] = v;
  }

  /// The JSON objects inside an array (the list itself is shared, edits go straight to the document).
  List<Json> objects(String k) {
    final v = raw(k);
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => e is Json ? e : e.cast<String, dynamic>()).toList();
  }

  List<dynamic> writeList(String k) {
    final v = writeMap[k];
    if (v is List) return v;
    final created = <dynamic>[];
    writeMap[k] = created;
    return created;
  }

  void addObject(String k, Json item) => writeList(k).add(item);

  void removeWhere(String k, bool Function(Json) test) {
    final v = raw(k);
    if (v is! List) return;
    writeList(k).removeWhere((e) => e is Map && test(e.cast<String, dynamic>()));
  }

  /// Replaces the object with the same `id`, or appends it.
  void upsertById(String k, Json item) {
    final list = writeList(k);
    final i = list.indexWhere((e) => e is Map && e['id'] == item['id']);
    if (i >= 0) {
      list[i] = item;
    } else {
      list.add(item);
    }
  }
}
