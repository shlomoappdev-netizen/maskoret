import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'card.dart';
import 'json.dart';
import 'models.dart';

/// Importing the credit-card statement exported from Max (.xlsx) — port of XLSXReader, MaxParser and
/// Store.importCardFile (Card.swift). New and updated charges are written as the Swift app writes them;
/// existing charge objects are updated in place, so fields this app doesn't know stay as they were.

class CardImportException implements Exception {
  const CardImportException(this.message);
  final String message;
  @override
  String toString() => message;

  static const unreadable = CardImportException('לא הצלחתי לפתוח את הקובץ. ודא שזה קובץ Excel (‎.xlsx) שיוצא מ-Max.');
  static const notMax = CardImportException('הקובץ לא נראה כמו פירוט עסקאות של Max (לא נמצאה עמודת ״תאריך עסקה״).');
  static const empty = CardImportException('לא נמצאו עסקאות בקובץ.');
}

class XlsxSheet {
  XlsxSheet(this.name, this.rows);
  final String name;
  final List<List<String>> rows;
}

/// A minimal .xlsx reader: shared strings + every sheet's cell texts (like XLSXReader in Swift).
class XlsxReader {
  static int columnIndex(String ref) {
    var index = 0;
    for (final ch in ref.toUpperCase().codeUnits) {
      if (ch < 65 || ch > 90) break;
      index = index * 26 + (ch - 64);
    }
    return index - 1 < 0 ? 0 : index - 1;
  }

  static List<XlsxSheet> read(List<int> bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw CardImportException.unreadable;
    }
    String? text(String path) {
      final f = zip.findFile(path);
      if (f == null) return null;
      return _utf8(f.content as List<int>);
    }

    final shared = <String>[];
    final sharedXml = text('xl/sharedStrings.xml');
    if (sharedXml != null) {
      for (final si in XmlDocument.parse(sharedXml).findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    }
    final rels = <String, String>{};
    final relsXml = text('xl/_rels/workbook.xml.rels');
    if (relsXml != null) {
      for (final r in XmlDocument.parse(relsXml).findAllElements('Relationship')) {
        final id = r.getAttribute('Id'), target = r.getAttribute('Target');
        if (id != null && target != null) rels[id] = target;
      }
    }
    final workbook = text('xl/workbook.xml');
    if (workbook == null) throw CardImportException.unreadable;
    final sheets = <XlsxSheet>[];
    for (final s in XmlDocument.parse(workbook).findAllElements('sheet')) {
      final name = s.getAttribute('name') ?? '';
      final rid = s.getAttribute('r:id') ??
          s.attributes.where((a) => a.name.qualified.endsWith(':id')).map((a) => a.value).firstOrNull ??
          '';
      final target = rels[rid];
      if (target == null) continue;
      final path = target.startsWith('/') ? target.substring(1) : 'xl/$target';
      final xml = text(path);
      if (xml == null) continue;
      final cells = <int, Map<int, String>>{};
      for (final c in XmlDocument.parse(xml).findAllElements('c')) {
        final ref = c.getAttribute('r') ?? '';
        final letters = RegExp(r'^[A-Za-z]+').stringMatch(ref) ?? '';
        final row = int.tryParse(ref.substring(letters.length));
        if (row == null) continue;
        final type = c.getAttribute('t') ?? '';
        // <v> for values, <is><t> for inline strings.
        var value = c.findElements('v').map((v) => v.innerText).join();
        if (value.isEmpty) value = c.findAllElements('t').map((t) => t.innerText).join();
        if (type == 's') {
          final i = int.tryParse(value);
          if (i != null && i >= 0 && i < shared.length) value = shared[i];
        }
        (cells[row] ??= {})[columnIndex(letters)] = value;
      }
      final rows = <List<String>>[];
      if (cells.isNotEmpty) {
        final maxRow = cells.keys.reduce((a, b) => a > b ? a : b);
        for (var r = 1; r <= maxRow; r++) {
          final row = cells[r] ?? const {};
          if (row.isEmpty) {
            rows.add([]);
            continue;
          }
          final maxCol = row.keys.reduce((a, b) => a > b ? a : b);
          rows.add([for (var i = 0; i <= maxCol; i++) row[i] ?? '']);
        }
      }
      sheets.add(XlsxSheet(name, rows));
    }
    if (sheets.isEmpty) throw CardImportException.unreadable;
    return sheets;
  }

  static String _utf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);
}

/// A parsed charge, before ids are given.
class _Parsed {
  _Parsed(this.tx, this.needsCharge);
  final Json tx;
  final bool needsCharge;
}

class MaxResult {
  MaxResult(this.billingLabel, this.transactions);
  final String billingLabel;
  final List<Json> transactions;
}

/// Port of `MaxParser`.
class MaxParser {
  /// Like Swift's DateFormatter with "dd-MM-yyyy" / "dd/MM/yyyy" / "dd.MM.yyyy": the year is taken literally
  /// (so "15-10-26" is the year 26, exactly as the Mac app reads it — the ids must be the same on every device).
  static final _dayMonthYear = RegExp(r'^(\d{1,2})([-/.])(\d{1,2})\2(\d{1,4})$');

  static DateTime? parseDate(String text) {
    final s = text.trim();
    if (s.isEmpty) return null;
    final m = _dayMonthYear.firstMatch(s);
    if (m != null) {
      final d = int.parse(m.group(1)!), mo = int.parse(m.group(3)!), y = int.parse(m.group(4)!);
      if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
      return DateTime(y, mo, d, 12);
    }
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (iso != null) return DateTime(int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!), 12);
    // Excel serial date.
    final serial = double.tryParse(s);
    if (serial != null && serial > 20000 && serial < 80000) {
      return DateTime(1899, 12, 30 + serial.truncate(), 12);
    }
    return null;
  }

  static double? parseAmount(String text) {
    final cleaned = text.replaceAll('₪', '').replaceAll(',', '').trim();
    return cleaned.isEmpty ? null : double.tryParse(cleaned);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static MaxResult parse(List<XlsxSheet> sheets) {
    var label = '';
    final parsed = <_Parsed>[];
    var foundHeader = false;
    final importedAt = dateTimeToSwift(DateTime.now());

    for (final sheet in sheets) {
      final headerIndex = sheet.rows.indexWhere((r) => r.any((c) => c.trim() == 'תאריך עסקה'));
      if (headerIndex < 0) continue;
      foundHeader = true;
      final header = sheet.rows[headerIndex].map((c) => c.trim()).toList();
      int? col(String name) {
        final i = header.indexOf(name);
        return i < 0 ? null : i;
      }

      int? colContaining(String part) {
        final i = header.indexWhere((h) => h.contains(part));
        return i < 0 ? null : i;
      }

      if (label.isEmpty) {
        for (final row in sheet.rows.take(headerIndex)) {
          final cell = row.where((c) => RegExp(r'^\d{1,2}/\d{4}$').hasMatch(c)).firstOrNull;
          if (cell != null) {
            label = cell;
            break;
          }
        }
      }

      final status = sheet.name.contains('טרם')
          ? 'pending'
          : sheet.name.contains('חו')
              ? 'foreign'
              : 'charged';
      final cDate = col('תאריך עסקה');
      final cMerchant = col('שם בית העסק') ?? colContaining('בית העסק');
      final cCategory = col('קטגוריה');
      final cCard = colContaining('ספרות');
      final cType = col('סוג עסקה');
      final cAmount = col('סכום חיוב');
      final cOriginal = col('סכום עסקה מקורי');
      final cOrigCurrency = col('מטבע עסקה מקורי');
      final cCharge = col('תאריך חיוב');
      final cNote = col('הערות');
      final cMethod = colContaining('אופן ביצוע');

      for (final row in sheet.rows.skip(headerIndex + 1)) {
        String cell(int? c) => c == null || c >= row.length ? '' : row[c].trim();
        final date = parseDate(cell(cDate));
        if (date == null) continue;
        final merchant = cell(cMerchant);
        if (merchant.isEmpty) continue;
        final original = parseAmount(cell(cOriginal)) ?? 0;
        final charged = parseAmount(cell(cAmount));
        final chargeDate = parseDate(cell(cCharge));
        final currency = cell(cOrigCurrency);
        final tx = <String, dynamic>{
          'id': '',
          'date': dateTimeToSwift(date),
          'merchant': merchant,
          'category': cell(cCategory),
          'cardLast4': cell(cCard),
          'type': cell(cType),
          'amount': jsonNumber(charged ?? original),
          'originalAmount': jsonNumber(original),
          'originalCurrency': currency.isEmpty ? '₪' : currency,
          if (chargeDate != null) 'chargeDate': dateTimeToSwift(chargeDate),
          'chargeEstimated': chargeDate == null,
          'note': cell(cNote),
          'method': cell(cMethod),
          'status': status,
          'ignored': false,
          'importedAt': importedAt,
          'owedPortion': 0,
        };
        parsed.add(_Parsed(tx, chargeDate == null));
      }
    }
    if (!foundHeader) throw CardImportException.notMax;
    if (parsed.isEmpty) throw CardImportException.empty;

    // Estimated charge date for pending items: the statement's billing month, on the usual charge day.
    final counts = <int, int>{};
    for (final p in parsed) {
      final t = CardTransaction(p.tx);
      if (t.status == 'charged' && t.chargeDate != null) counts[t.chargeDate!.day] = (counts[t.chargeDate!.day] ?? 0) + 1;
    }
    var usualDay = 2;
    if (counts.isNotEmpty) {
      final best = counts.values.reduce((a, b) => a > b ? a : b);
      usualDay = (counts.keys.where((d) => counts[d] == best).toList()..sort()).first;
    }
    num? estimated;
    final parts = label.split('/');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]), y = int.tryParse(parts[1]);
      if (m != null && y != null) estimated = dateTimeToSwift(DateTime(y, m, usualDay, 12));
    }

    // Stable ids — identical purchases on the same day get #1, #2…
    final seen = <String, int>{};
    final result = <Json>[];
    for (final p in parsed) {
      final tx = p.tx;
      if (p.needsCharge && estimated != null) tx['chargeDate'] = estimated;
      final t = CardTransaction(tx);
      final d = t.date;
      final base = [
        t.status == 'pending' ? 'P' : 'C',
        '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}',
        t.merchantKey,
        t.cardLast4,
        t.originalAmount.toStringAsFixed(2),
        t.note,
      ].join('|');
      final n = (seen[base] ?? 0) + 1;
      seen[base] = n;
      tx['id'] = '$base#$n';
      result.add(tx);
    }
    return MaxResult(label, result);
  }
}

/// The result of an import, as shown to the user (CardImport.summary in Swift).
class CardImportRecord {
  CardImportRecord(this.json);
  final Json json;
  String get summary {
    final j = JObj(json);
    final label = j.s('billingLabel');
    final parts = ['${j.i('count')} עסקאות בקובץ${label.isEmpty ? '' : ' (חיוב $label)'}', '${j.i('added')} חדשות'];
    final updated = j.i('updated'), confirmed = j.i('confirmed'), repeats = j.i('repeats'), stale = j.i('removedStale');
    if (updated > 0) parts.add('$updated כבר היו — עודכנו בלי כפילות');
    if (confirmed > 0) parts.add('$confirmed ממתינות נקלטו סופית');
    if (repeats > 0) parts.add('$repeats רכישות זהות חוזרות נשמרו (באמת נקנו פעמיים)');
    if (stale > 0) parts.add('$stale ממתינות ישנות הוסרו');
    return parts.join(' · ');
  }
}

/// Card actions on one member's data — ports of the Store extensions in Card.swift / Receivables.swift.
class CardActions {
  CardActions(this.file);
  final SaveFile file;

  JObj get _money => JObj.lazy(file.json, 'money');

  List<Json> get _cards => _money.objects('cardTransactions');

  /// Imports a Max export without creating duplicates (see Store.importCardFile in Card.swift).
  CardImportRecord importFile(List<int> bytes, String fileName, {DateTime? now}) {
    final result = MaxParser.parse(XlsxReader.read(bytes));
    final today = now ?? DateTime.now();
    final money = _money;
    final rules = <String, String>{};
    for (final r in money.objects('merchantRules')) {
      final k = r['merchantKey'], e = r['expenseID'];
      if (k is String && e is String) rules.putIfAbsent(k, () => e);
    }
    final expenseIDs = file.budget.expenses.map((e) => e.id).toSet();

    void carry(Json old, Json tx) {
      for (final k in ['linkedExpenseID', 'linkedTrackedID']) {
        if (old[k] != null) {
          tx[k] = old[k];
        } else {
          tx.remove(k);
        }
      }
      tx['ignored'] = old['ignored'] ?? false;
      if (old['importedAt'] != null) tx['importedAt'] = old['importedAt'];
      tx['owedPortion'] = old['owedPortion'] ?? 0;
    }

    void applyRule(Json tx) {
      final t = CardTransaction(tx);
      if (t.linkedExpenseID == null && t.linkedTrackedID == null) {
        final e = rules[t.merchantKey];
        if (e != null && expenseIDs.contains(e)) tx['linkedExpenseID'] = e;
      }
    }

    /// The fields of `tx` copied onto the old object (so unknown fields stay); returns the object to keep.
    Json merged(Json old, Json tx) {
      final out = Map<String, dynamic>.of(old);
      for (final e in tx.entries) {
        out[e.key] = e.value;
      }
      for (final k in ['chargeDate', 'linkedExpenseID', 'linkedTrackedID']) {
        if (!tx.containsKey(k)) out.remove(k);
      }
      return out;
    }

    int days(DateTime a, DateTime b) =>
        DateTime(a.year, a.month, a.day).difference(DateTime(b.year, b.month, b.day)).inDays.abs();

    int? pendingMatch(Json tx, List<Json> list) {
      final t = CardTransaction(tx);
      int? best;
      for (var i = 0; i < list.length; i++) {
        final p = CardTransaction(list[i]);
        if (p.merchantKey == t.merchantKey &&
            p.cardLast4 == t.cardLast4 &&
            (p.originalAmount - t.originalAmount).abs() < 0.005 &&
            days(p.date, t.date) <= 2) {
          if (best == null || days(p.date, t.date) < days(CardTransaction(list[best]).date, t.date)) best = i;
        }
      }
      return best;
    }

    final all = money.writeList('cardTransactions');
    final pending = all.whereType<Map<String, dynamic>>().where((t) => t['status'] == 'pending').toList();
    all.removeWhere((t) => t is Map && t['status'] == 'pending');
    var added = 0, updated = 0, confirmed = 0;
    final renamed = <String, String>{};

    // 1. Charged (and foreign) items.
    for (final tx in result.transactions.where((t) => t['status'] != 'pending')) {
      final i = all.indexWhere((t) => t is Map && t['id'] == tx['id']);
      if (i >= 0) {
        final old = all[i] as Json;
        carry(old, tx);
        all[i] = merged(old, tx);
        updated++;
      } else {
        final j = pendingMatch(tx, pending);
        var keep = tx;
        if (j != null) {
          carry(pending[j], tx);
          tx['importedAt'] = dateTimeToSwift(today);
          renamed[pending[j]['id'] as String] = tx['id'] as String;
          keep = merged(pending[j], tx);
          pending.removeAt(j);
          confirmed++;
        } else {
          added++;
        }
        applyRule(keep);
        all.add(keep);
      }
    }

    // 2. Pending items in this file (each existing pending item is used once).
    final fresh = <Json>[];
    for (final tx in result.transactions.where((t) => t['status'] == 'pending')) {
      var j = pending.indexWhere((p) => p['id'] == tx['id']);
      if (j < 0) j = pendingMatch(tx, pending) ?? -1;
      var keep = tx;
      if (j >= 0) {
        carry(pending[j], tx);
        if (pending[j]['id'] != tx['id']) renamed[pending[j]['id'] as String] = tx['id'] as String;
        keep = merged(pending[j], tx);
        pending.removeAt(j);
        updated++;
      } else {
        added++;
      }
      applyRule(keep);
      fresh.add(keep);
    }

    // 3. Older pending items this file doesn't mention: kept unless their charge date is long gone.
    final staleBefore = today.subtract(const Duration(days: 35));
    final kept = pending.where((p) {
      final t = CardTransaction(p);
      return !(t.chargeDate ?? t.date).isBefore(staleBefore);
    }).toList();
    all.addAll([...fresh, ...kept]);

    if (renamed.isNotEmpty) {
      for (final r in money.objects('receivables')) {
        final shares = r['cardShares'];
        if (shares is Map) {
          for (final e in renamed.entries) {
            if (shares.containsKey(e.key)) shares[e.value] = shares.remove(e.key);
          }
        }
        final credits = r['cardCreditIDs'];
        if (credits is List) {
          for (var i = 0; i < credits.length; i++) {
            credits[i] = renamed[credits[i]] ?? credits[i];
          }
        }
      }
      for (final t in money.objects('trends')) {
        final ids = t['cardIDs'];
        if (ids is List) {
          for (var i = 0; i < ids.length; i++) {
            ids[i] = renamed[ids[i]] ?? ids[i];
          }
        }
        final shares = t['shares'];
        if (shares is Map) {
          for (final e in renamed.entries) {
            if (shares.containsKey(e.key)) shares[e.value] = shares.remove(e.key);
          }
        }
      }
    }

    // Like CardTransaction.occurrence: the number after the last "#".
    final repeats = result.transactions.where((t) => (int.tryParse((t['id'] as String).split('#').last) ?? 1) > 1).length;
    final record = <String, dynamic>{
      'id': newId(),
      'fileName': fileName,
      'importedAt': dateTimeToSwift(today),
      'billingLabel': result.billingLabel,
      'count': result.transactions.length,
      'added': added,
      'updated': updated,
      'confirmed': confirmed,
      'repeats': repeats,
      'removedStale': pending.length - kept.length,
    };
    syncOwedPortions();
    final imports = money.writeList('cardImports');
    imports.insert(0, record);
    if (imports.length > 50) imports.removeRange(50, imports.length);
    return CardImportRecord(record);
  }

  /// Keeps `owedPortion` on card charges in sync with the "owed to me" shares.
  void syncOwedPortions() {
    final portions = <String, double>{};
    for (final r in _money.objects('receivables')) {
      if (r['forgiven'] == true) continue;
      final shares = r['cardShares'];
      if (shares is Map) {
        shares.forEach((k, v) => portions[k as String] = (portions[k] ?? 0) + ((v as num?)?.toDouble() ?? 0));
      }
    }
    for (final t in _cards) {
      final amount = (t['amount'] as num?)?.toDouble() ?? 0;
      var p = portions[t['id']] ?? 0;
      if (p < 0) p = 0;
      final cap = amount > 0 ? amount : 0.0;
      if (p > cap) p = cap;
      if (((t['owedPortion'] as num?)?.toDouble() ?? 0) != p) t['owedPortion'] = jsonNumber(p);
    }
  }

  Json? _card(String id) => _cards.where((t) => t['id'] == id).firstOrNull;

  /// Links a charge to a fixed expense; with `remember`, every charge from the same merchant follows.
  void linkToExpense(String txID, String? expenseID, {bool remember = true}) {
    final tx = _card(txID);
    if (tx == null) return;
    final key = CardTransaction(tx).merchantKey;
    final o = JObj(tx)..set('linkedExpenseID', expenseID);
    if (expenseID != null) o.set('linkedTrackedID', null);
    final money = _money;
    if (expenseID != null && remember) {
      money.removeWhere('merchantRules', (r) => r['merchantKey'] == key);
      money.addObject('merchantRules', {'merchantKey': key, 'expenseID': expenseID});
      for (final t in _cards) {
        final c = CardTransaction(t);
        if (c.merchantKey == key && c.linkedExpenseID == null && c.linkedTrackedID == null) t['linkedExpenseID'] = expenseID;
      }
    }
    if (expenseID == null) money.removeWhere('merchantRules', (r) => r['merchantKey'] == key);
  }

  /// Links a charge to a tracked purchase (e.g. shoes) and records the purchase there.
  void linkToTracked(String txID, String? itemID) {
    final tx = _card(txID);
    if (tx == null) return;
    final o = JObj(tx)..set('linkedTrackedID', itemID);
    if (itemID != null) o.set('linkedExpenseID', null);
    if (itemID == null) return;
    final c = CardTransaction(tx);
    final item = JObj(file.json['budget'] as Json).objects('trackedItems').where((t) => t['id'] == itemID).firstOrNull;
    if (item == null) return;
    final price = c.originalAmount != 0 ? c.originalAmount.abs() : c.amount.abs();
    final purchases = JObj(item);
    final exists = purchases.objects('purchases').any((p) {
      final d = Purchase(p).date;
      return d.year == c.date.year && d.month == c.date.month && d.day == c.date.day && (Purchase(p).price - price).abs() < 0.01;
    });
    if (!exists) {
      purchases.addObject('purchases', {
        'id': newId(),
        'date': dateTimeToSwift(c.date),
        'price': jsonNumber(price),
        'note': c.merchant,
      });
    }
  }

  void setIgnored(String txID, bool ignored) => _card(txID)?['ignored'] = ignored;

  /// Adds or removes a charge from a trend (מגמות).
  void toggleInTrend(String txID, String trendID) {
    final trend = _money.objects('trends').where((t) => t['id'] == trendID).firstOrNull;
    if (trend == null) return;
    final ids = JObj(trend).writeList('cardIDs');
    if (ids.contains(txID)) {
      ids.remove(txID);
    } else {
      ids.add(txID);
    }
  }
}

extension CardDataDue on CardData {
  /// True when this month's charge day has passed but its statement wasn't imported yet.
  bool importDue([DateTime? now]) {
    final day = usualChargeDay;
    if (day == null) return false;
    final today = now ?? DateTime.now();
    if (today.day < day) return false;
    final key = today.year * 100 + today.month;
    return !cardStatementKeys.any((k) => k >= key);
  }
}
