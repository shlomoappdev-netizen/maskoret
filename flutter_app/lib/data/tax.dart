import 'bundled_rates.dart';
import 'json.dart';

/// One monthly income-tax bracket. `upTo == null` means "and above".
class TaxBracket {
  const TaxBracket(this.upTo, this.rate);
  final double? upTo;
  final double rate; // percent
}

/// Official Israeli payroll-deduction parameters (monthly values) — port of `TaxRates.swift`.
class TaxRates {
  TaxRates._(this.json);

  final Json json;

  late final int version = (json['version'] as num).toInt();
  late final int year = (json['year'] as num).toInt();
  late final String updated = json['updated'] as String;
  late final List<TaxBracket> brackets = (json['brackets'] as List)
      .map((b) => TaxBracket((b['upTo'] as num?)?.toDouble(), (b['rate'] as num).toDouble()))
      .toList();
  double _n(String k) => (json[k] as num).toDouble();
  late final double surtaxMonthlyThreshold = _n('surtaxMonthlyThreshold');
  late final double surtaxRate = _n('surtaxRate');
  late final double creditPointValue = _n('creditPointValue');
  late final double niReducedThreshold = _n('niReducedThreshold');
  late final double niMaxIncome = _n('niMaxIncome');
  late final double niReducedRate = _n('niReducedRate');
  late final double niFullRate = _n('niFullRate');
  late final double healthReducedRate = _n('healthReducedRate');
  late final double healthFullRate = _n('healthFullRate');
  late final double pensionCreditRate = _n('pensionCreditRate');
  late final double pensionCreditMaxPercent = _n('pensionCreditMaxPercent');
  late final double pensionInsuredSalaryCap = _n('pensionInsuredSalaryCap');

  static final TaxRates bundled = TaxRates._(bundledRatesJson);

  static const _required = [
    'version', 'year', 'updated', 'brackets', 'surtaxMonthlyThreshold', 'surtaxRate', 'creditPointValue',
    'niReducedThreshold', 'niMaxIncome', 'niReducedRate', 'niFullRate', 'healthReducedRate', 'healthFullRate',
    'pensionCreditRate', 'pensionCreditMaxPercent', 'pensionInsuredSalaryCap', 'sources',
  ];

  /// Like Swift's `(try? decode(TaxRates)) ?? .bundled`, and the app always calculates with
  /// the newest rates it knows (the saved ones, or the bundled ones when those are newer).
  static TaxRates effective(dynamic saved) {
    if (saved is! Map) return bundled;
    final m = saved.cast<String, dynamic>();
    try {
      for (final k in _required) {
        if (k == 'sources') {
          if (m[k] is! List) return bundled;
        } else if (m[k] == null) {
          return bundled;
        }
      }
      final r = TaxRates._(m);
      r.brackets; // validates
      r.pensionInsuredSalaryCap;
      return r.version < bundled.version ? bundled : r;
    } catch (_) {
      return bundled;
    }
  }
}

/// Pure calculation helpers — all amounts are monthly. Port of `TaxCalc` in TaxRates.swift.
class TaxCalc {
  static double bracketTax(double income, TaxRates rates) {
    if (income <= 0) return 0;
    var tax = 0.0;
    var lower = 0.0;
    for (final bracket in rates.brackets) {
      final upper = bracket.upTo ?? double.maxFinite;
      if (income > lower) {
        tax += ((income < upper ? income : upper) - lower) * bracket.rate / 100;
      }
      if (income <= upper) break;
      lower = upper;
    }
    tax += _max0(income - rates.surtaxMonthlyThreshold) * rates.surtaxRate / 100;
    return tax;
  }

  static double pensionCredit(double contribution, double gross, TaxRates rates) {
    final maxEligible = _min(gross, rates.pensionInsuredSalaryCap) * rates.pensionCreditMaxPercent / 100;
    return _min(contribution, maxEligible) * rates.pensionCreditRate / 100;
  }

  static double incomeTax(double gross, double creditPoints, double pensionContribution, TaxRates rates) {
    final before = bracketTax(gross, rates);
    final credits = creditPoints * rates.creditPointValue + pensionCredit(pensionContribution, gross, rates);
    return _max0(before - credits);
  }

  static double _twoTier(double gross, double reduced, double full, TaxRates rates) {
    final reducedPart = _min(_max0(gross), rates.niReducedThreshold);
    final fullPart = _max0(_min(gross, rates.niMaxIncome) - rates.niReducedThreshold);
    return reducedPart * reduced / 100 + fullPart * full / 100;
  }

  static double nationalInsurance(double gross, TaxRates rates) =>
      _twoTier(gross, rates.niReducedRate, rates.niFullRate, rates);

  static double healthInsurance(double gross, TaxRates rates) =>
      _twoTier(gross, rates.healthReducedRate, rates.healthFullRate, rates);
}

double _max0(double v) => v > 0 ? v : 0;
double _min(double a, double b) => a < b ? a : b;
