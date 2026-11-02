/// What a payslip PDF says, as far as the app can tell from its text. Port of `PayslipReading` (Payslip.swift).
class PayslipReading {
  int? year;
  int? month;

  /// Total payments ("סה״כ תשלומים").
  double? gross;

  /// Mandatory deductions and pension ("ניכויי חובה וגמל").
  double? deductions;

  /// Net pay before voluntary deductions ("שכר נטו").
  double? net;

  /// What reaches the bank ("נטו לתשלום").
  double? netToPay;
  double? incomeTax;
  double? nationalInsurance;
  double? health;

  /// The totals agree with each other (payments − deductions = net, or the payments add up to the total).
  bool verified = false;

  /// Read from an image (a scanned payslip) — only its numbers.
  bool scanned = false;

  bool get isUseful => netToPay != null;

  Map<String, dynamic> toJson() => {
        'year': year, 'month': month, 'gross': gross, 'deductions': deductions, 'net': net, 'netToPay': netToPay,
        'incomeTax': incomeTax, 'nationalInsurance': nationalInsurance, 'health': health, 'verified': verified,
      };
}

enum PayslipError implements Exception {
  unreadable('לא ניתן לפתוח את הקובץ כ-PDF.'),
  needsPassword('התלוש נעול בסיסמה.'),
  wrongPassword('הסיסמה לא נכונה.'),
  noText('לא הצלחתי לקרוא טקסט מהקובץ.'),
  /// A scan where the device can't read it (Windows): nothing is sent anywhere.
  noTextLayer('בקובץ אין טקסט — הקלד את הנטו ידנית.'),
  notFound('לא הצלחתי למצוא בתלוש את הנטו. אפשר להקליד אותו ידנית.');

  const PayslipError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Reads the payslip's text — a line-by-line port of `PayslipReader.parse` (Payslip.swift). Payroll programs lay
/// their tables out differently, so instead of relying on positions the totals are found by their arithmetic:
/// payments − deductions = net (− voluntary = net to pay).
class PayslipParser {
  static final _newlines = RegExp('[\n\r\u000B\u000C\u0085  ]');
  static final _amount = RegExp(r'^-?\d{1,3}(,\d{3})*\.\d{2}$');
  static final _plainAmount = RegExp(r'^-?\d+\.\d{2}(?=\d?$)');
  static final _monthYear = RegExp(r'^(\d{1,2})/(\d{2}|\d{4})$');
  static final _integer = RegExp(r'^[+-]?\d+$');
  static final _digits = RegExp(r'^\d+$');

  static PayslipReading parse(String raw) {
    // Some payroll fonts map "נ" to "ð" (or drop it) in the text layer.
    final text = raw.replaceAll('ð', 'נ');
    final lines = text.split(_newlines).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final r = PayslipReading();

    // The month: "8/26" or "08/2026" on a line of its own, or after "לחודש".
    for (final line in lines.take(40)) {
      final my = monthYear(line.replaceAll('לחודש', '').trim());
      if (my != null) {
        r.month = my.$1;
        r.year = my.$2;
        break;
      }
    }

    // Amounts in reading order ("2,750.00").
    final amounts = [for (final l in lines) ?amount(l)];

    // gross − deductions = net: three amounts next to each other, the biggest such chain.
    (int, double, double, double)? best;
    for (var i = 0; i < amounts.length - 2; i++) {
      final a = amounts[i], b = amounts[i + 1], c = amounts[i + 2];
      if (!(a > 0 && b > 0 && c > 0 && b < a && (a - b - c).abs() < 0.02)) continue;
      if (best == null || a > best.$2) best = (i, a, b, c);
    }
    if (best != null) {
      final (i, gross, deductions, net) = best;
      r.gross = gross;
      r.deductions = deductions;
      r.net = net;
      r.netToPay = net;
      r.verified = true;
      // What follows: the net again (nothing voluntary), or voluntary deductions and the net to pay.
      final rest = amounts.skip(i + 3).take(2).toList();
      if (rest.length == 2 && rest[0] > 0 && rest[1] > 0 && (net - rest[0] - rest[1]).abs() < 0.02) {
        r.netToPay = rest[1];
      }
    } else if (sumOfPrevious(amounts) case (final i, final total)) {
      // No deductions: the payments, their total, and later the same amount as the net.
      r.gross = total;
      final after = amounts.skip(i + 1).where((a) => a > 0 && a <= total + 0.02);
      final pay = after.lastOrNull ?? total;
      r.netToPay = pay;
      r.net = pay;
      if (total - pay > 0.005) r.deductions = total - pay;
      r.verified = true;
    } else {
      // No arithmetic to go by: the amount right after the "net to pay" label.
      r.netToPay = _amountAfter('טו לתשלום', lines);
      r.gross = _amountAfter('תשלומים', lines);
    }

    // Mandatory deductions: the amounts that sum to the total, matched to their labels in order.
    final total = r.deductions;
    if (total != null) {
      for (final (label, value) in _deductionParts(lines, const ['מס הכנסה', 'ביטוח לאומי', 'בריאות'], total)) {
        switch (label) {
          case 'מס הכנסה':
            r.incomeTax = value;
          case 'ביטוח לאומי':
            r.nationalInsurance = value;
          default:
            r.health = value;
        }
      }
    }
    return r;
  }

  static double? amount(String line) {
    final s = line.replaceAll('₪', '').trim();
    if (_amount.hasMatch(s)) return double.parse(s.replaceAll(',', ''));
    // From recognized images: no thousands separator, and the ₪ sign sometimes read as a trailing digit.
    final m = _plainAmount.firstMatch(s);
    return m == null ? null : double.parse(m.group(0)!);
  }

  /// An amount that equals the sum of the 2–6 amounts right before it (the payments and their total).
  static (int, double)? sumOfPrevious(List<double> amounts) {
    (int, double)? best;
    for (var i = 0; i < amounts.length; i++) {
      if (amounts[i] <= 0) continue;
      for (var k = 2; k <= 6 && i - k >= 0; k++) {
        final parts = amounts.sublist(i - k, i);
        if (!parts.every((p) => p > 0) || (parts.fold(0.0, (s, p) => s + p) - amounts[i]).abs() >= 0.02) continue;
        if (best == null || amounts[i] > best.$2) best = (i, amounts[i]);
      }
    }
    return best;
  }

  static (int, int)? monthYear(String raw) {
    final s = raw.replaceAll(' ', '');
    final m = _monthYear.firstMatch(s);
    if (m == null) return null;
    final month = int.parse(m.group(1)!);
    var year = int.parse(m.group(2)!);
    if (month < 1 || month > 12) return null;
    if (year < 100) year += 2000;
    if (year < 2000 || year > 2100) return null;
    return (month, year);
  }

  static double? _amountAfter(String label, List<String> lines) {
    final i = lines.indexWhere((l) => l.contains(label));
    if (i < 0) return null;
    return lines.skip(i + 1).take(4).map(amount).nonNulls.firstOrNull;
  }

  static double? _amountOrInteger(String line) => amount(line) ?? (_integer.hasMatch(line) ? double.parse(line) : null);

  /// In a block where amounts come before (or after) their labels, the ones that add up to `total` belong to the
  /// deduction labels that appear in that block, in the same order.
  static List<(String, double)> _deductionParts(List<String> lines, List<String> labels, double total) {
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('ביטוח לאומי')) continue;
      // The labels of this block, in order.
      final found = <String>[];
      var j = i;
      while (j > 0 && amount(lines[j - 1]) == null) {
        j--;
      }
      var k = j;
      while (k < lines.length && amount(lines[k]) == null) {
        final l = labels.where((l) => lines[k].contains(l) && !lines[k].contains('%')).firstOrNull;
        if (l != null) found.add(l);
        k++;
      }
      // The amounts right before the labels (a "%" label takes its rate first).
      final values = <double>[];
      var v = j - 1;
      while (v >= 0) {
        final a = _amountOrInteger(lines[v]);
        if (a == null) break;
        values.insert(0, a);
        v--;
      }
      final hasRate = lines.sublist(j, k).any((l) => l.contains('%'));
      if (hasRate && values.isNotEmpty && _digits.hasMatch(lines[v + 1])) values.removeAt(0);
      final money = values.length > found.length ? values.sublist(values.length - found.length) : values;
      final sum = money.fold(0.0, (s, x) => s + x);
      if (found.length == money.length && (sum - total).abs() < 0.02) return [for (var x = 0; x < found.length; x++) (found[x], money[x])];
      // Pension may be part of the total too — accept when the parts don't exceed it.
      if (found.length == money.length && sum <= total + 0.02) return [for (var x = 0; x < found.length; x++) (found[x], money[x])];
    }
    return [];
  }
}
