import 'package:intl/intl.dart';

/// Hebrew formatting, like `Fmt` in Components.swift.
class Fmt {
  static const monthNames = [
    'ינואר', 'פברואר', 'מרץ', 'אפריל', 'מאי', 'יוני',
    'יולי', 'אוגוסט', 'ספטמבר', 'אוקטובר', 'נובמבר', 'דצמבר',
  ];

  /// Whole shekels when there are no agorot (120 ₪), otherwise two digits (12.50 ₪).
  static String money(double value) {
    final rounded = (value * 100).round() / 100;
    final digits = (rounded - rounded.roundToDouble()).abs() < 0.001 ? 0 : 2;
    final f = NumberFormat.currency(locale: 'he', symbol: '₪', decimalDigits: digits);
    return f.format(rounded);
  }

  static String number(double value) {
    final f = NumberFormat('#,##0.##', 'he');
    return f.format(value);
  }

  static String percent(double value) => '${number(value)}%';

  /// A length of time in Hebrew, like `Fmt.duration` in Swift.
  static String duration(double months) {
    if (months < 1) {
      final days = (months * 30.4375).round();
      return days == 1 ? 'יום אחד' : '$days ימים';
    }
    if (months < 24) {
      final m = (months * 10).round() / 10;
      return m == 1 ? 'חודש אחד' : '${number(m)} חודשים';
    }
    return '${number((months / 12 * 10).round() / 10)} שנים';
  }

  static String compact(double value) => NumberFormat.compact(locale: 'he').format(value);

  static String date(DateTime d) => DateFormat('d בMMM y', 'he').format(d);

  static String monthTitle(int year, int month) => '${monthNames[(month.clamp(1, 12)) - 1]} $year';

  /// "5000" / "12.5" for editing fields (no grouping).
  static String plain(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }

  static double? parse(String text) {
    final t = text.replaceAll(',', '').replaceAll('₪', '').replaceAll('%', '').trim();
    if (t.isEmpty) return 0;
    return double.tryParse(t);
  }
}
