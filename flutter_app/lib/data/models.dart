import 'json.dart';
import 'tax.dart';

/// Views over the household document (`household_data.data`), which is the Swift `FamilyBackup`:
/// `{ state: FamilyState, files: { memberId: Store.SaveFile } }`.
///
/// Every class here wraps the original JSON object. Getters read with the same defaults as the Swift
/// decoders; setters change only their own key. Nothing is ever re-encoded from scratch, so data from
/// screens this app doesn't have yet (credit cards, maaser, trends, debts…) is never lost.

// MARK: - Family

class FamilyBackup {
  FamilyBackup(this.json);
  final Json json;

  FamilyState get state => FamilyState(JObj.lazy(json, 'state'));

  Json get _files {
    final f = json['files'];
    if (f is Map<String, dynamic>) return f;
    final created = <String, dynamic>{};
    json['files'] = created;
    return created;
  }

  SaveFile? file(String memberId) {
    final f = json['files'];
    if (f is! Map) return null;
    final m = f[memberId];
    return m is Map<String, dynamic> ? SaveFile(m) : null;
  }

  /// The member's file, created like Swift's `newMemberFile()` when it's missing.
  SaveFile fileForEditing(String memberId) {
    final existing = file(memberId);
    if (existing != null) return existing;
    final primary = file(state.primaryID);
    final created = Starter.memberFile(ratesFrom: primary?.budget.ratesJson, moneyFrom: primary?.money);
    _files[memberId] = created;
    return SaveFile(created);
  }
}

class FamilyMember {
  FamilyMember(this.json);
  final Json json;
  JObj get _o => JObj(json);
  String get id => _o.s('id');
  String get name => _o.s('name');
  String get emoji => _o.s('emoji', '🙂');
  String get title => '$emoji $name';
}

class FamilyState {
  FamilyState(this._o);
  final JObj _o;

  List<FamilyMember> get members => _o.objects('members').map(FamilyMember.new).toList();
  String get primaryID => _o.sOpt('primaryID') ?? (members.isNotEmpty ? members.first.id : '');
  String get activeID => _o.sOpt('activeID') ?? primaryID;
  List<String> get viewIDs => (_o.raw('viewIDs') as List?)?.whereType<String>().toList() ?? [activeID];
}

// MARK: - One member's data (Store.SaveFile)

class SaveFile {
  SaveFile(this.json);
  final Json json;
  JObj get _o => JObj(json);

  Budget get budget => Budget(JObj.lazy(json, 'budget'));
  MoneyData get money => MoneyData(JObj.lazy(json, 'money'));
  List<MonthRecord> get history => _o.objects('history').map(MonthRecord.new).toList();

  void upsertRecord(Json record) => _o.upsertById('history', record);
}

// MARK: - Budget

enum IncomeKind { fixed, hourly }

class IncomeItem {
  IncomeItem(this.json);
  final Json json;
  JObj get _o => JObj(json);

  static Json create({String name = ''}) => {
        'id': newId(),
        'name': name,
        'kind': 'fixed',
        'amount': 0,
        'hours': 0,
        'hourlyRate': 0,
        'isActive': true,
        'isNet': false,
      };

  String get id => _o.s('id');
  String get name => _o.s('name');
  set name(String v) => _o.set('name', v);
  IncomeKind get kind => _o.s('kind') == 'hourly' ? IncomeKind.hourly : IncomeKind.fixed;
  set kind(IncomeKind v) => _o.set('kind', v.name);
  double get amount => _o.d('amount');
  set amount(double v) => _o.set('amount', v);
  double get hours => _o.d('hours');
  set hours(double v) => _o.set('hours', v);
  double get hourlyRate => _o.d('hourlyRate');
  set hourlyRate(double v) => _o.set('hourlyRate', v);
  bool get isActive => _o.b('isActive', true);
  set isActive(bool v) => _o.set('isActive', v);
  bool get isNet => _o.b('isNet');
  set isNet(bool v) => _o.set('isNet', v);

  double get rawTotal => kind == IncomeKind.fixed ? amount : hours * hourlyRate;
  double get monthlyTotal => isActive ? rawTotal : 0;
}

enum CostKind { fixed, percent, automatic }

enum AutoDeduction {
  incomeTax('מס הכנסה', 0),
  nationalInsurance('ביטוח לאומי', 0),
  healthInsurance('מס בריאות', 0),
  pension('פנסיה (חלק העובד)', 6),
  studyFund('קרן השתלמות (חלק העובד)', 2.5);

  const AutoDeduction(this.title, this.defaultPercent);
  final String title;
  final double defaultPercent;

  bool get usesPercent => this == pension || this == studyFund;

  String get explanation => switch (this) {
        incomeTax => 'מחושב לפי מדרגות המס, פחות נקודות הזיכוי שלך וזיכוי של 35% על ההפקדה לפנסיה (עד התקרה).',
        nationalInsurance => 'שיעור מופחת עד סף ההכנסה המופחתת, ושיעור מלא מעליו — עד ההכנסה המרבית.',
        healthInsurance => 'שיעור מופחת עד סף ההכנסה המופחתת, ושיעור מלא מעליו — עד ההכנסה המרבית.',
        pension => 'אחוז מהברוטו שמופרש מהשכר שלך לפנסיה (המינימום לפי חוק הוא 6%). ההפרשה גם מזכה בזיכוי ממס הכנסה.',
        studyFund => 'אחוז מהברוטו שמופרש מהשכר שלך לקרן השתלמות (בדרך כלל 2.5%), אם יש לך.',
      };

  static AutoDeduction? parse(String? s) {
    for (final a in values) {
      if (a.name == s) return a;
    }
    return null;
  }
}

class CostItem {
  CostItem(this.json);
  final Json json;
  JObj get _o => JObj(json);

  static Json create({String name = '', CostKind kind = CostKind.fixed, double value = 0}) => {
        'id': newId(),
        'name': name,
        'kind': kind.name,
        'value': value == value.roundToDouble() ? value.toInt() : value,
        'isActive': true,
      };

  static Json automatic(AutoDeduction type) => {
        ...create(name: type.title, kind: CostKind.automatic, value: type.defaultPercent),
        'auto': type.name,
      };

  String get id => _o.s('id');
  String get name => _o.s('name');
  set name(String v) => _o.set('name', v);
  CostKind get kind => switch (_o.s('kind')) {
        'percent' => CostKind.percent,
        'automatic' => CostKind.automatic,
        _ => CostKind.fixed,
      };
  set kind(CostKind v) => _o.set('kind', v.name);
  double get value => _o.d('value');
  set value(double v) => _o.set('value', v);
  bool get isActive => _o.b('isActive', true);
  set isActive(bool v) => _o.set('isActive', v);
  AutoDeduction? get auto => AutoDeduction.parse(_o.sOpt('auto'));
  String? get targetAccountID => _o.sOpt('targetAccountID');
  set targetAccountID(String? v) => _o.set('targetAccountID', v);

  double rawAmount(double base) => switch (kind) {
        CostKind.fixed => value,
        CostKind.percent => base * value / 100,
        CostKind.automatic => 0,
      };

  double amount(double base) => isActive ? rawAmount(base) : 0;
}

enum PensionMode {
  contributes('מפריש לפנסיה'),
  startsLater('עוד לא — יתחיל מתאריך'),
  none('לא מפריש');

  const PensionMode(this.title);
  final String title;
}

class TaxSettings {
  TaxSettings(this._o);
  final JObj _o;

  double get creditPoints => _o.d('creditPoints', 2.25);
  set creditPoints(double v) => _o.set('creditPoints', v);
  PensionMode get pensionMode =>
      PensionMode.values.firstWhere((m) => m.name == _o.s('pensionMode'), orElse: () => PensionMode.contributes);
  set pensionMode(PensionMode v) => _o.set('pensionMode', v.name);
  DateTime? get pensionStart => _o.date('pensionStart');
  set pensionStart(DateTime? v) => _o.set('pensionStart', v);

  bool contributesPension([DateTime? on]) {
    final date = on ?? DateTime.now();
    return switch (pensionMode) {
      PensionMode.contributes => true,
      PensionMode.none => false,
      PensionMode.startsLater => pensionStart != null && !date.isBefore(pensionStart!),
    };
  }
}

class Purchase {
  Purchase(this.json);
  final Json json;
  DateTime get date => JObj(json).date('date') ?? DateTime.now();
  double get price => JObj(json).d('price');
}

/// Something bought again every so often (shoes, a phone…). Only read here, for the monthly total.
class TrackedItem {
  TrackedItem(this.json);
  final Json json;
  JObj get _o => JObj(json);

  bool get includeInBudget => _o.b('includeInBudget', true);
  double get expectedMonths => _o.d('expectedMonths');
  List<Purchase> get purchases => _o.objects('purchases').map(Purchase.new).toList();

  static double monthsBetween(DateTime a, DateTime b) =>
      b.difference(a).inMicroseconds / 1e6 / 86400 / 30.4375;

  double? get averageLifespan {
    final s = purchases..sort((a, b) => a.date.compareTo(b.date));
    final intervals = <double>[];
    for (var i = 1; i < s.length; i++) {
      final m = monthsBetween(s[i - 1].date, s[i].date);
      if (m > 0) intervals.add(m);
    }
    if (intervals.isNotEmpty) return intervals.reduce((a, b) => a + b) / intervals.length;
    return expectedMonths > 0 ? expectedMonths : null;
  }

  double get averagePrice {
    final p = purchases;
    if (p.isEmpty) return 0;
    return p.fold(0.0, (a, b) => a + b.price) / p.length;
  }

  double get monthlyCost {
    final life = averageLifespan;
    if (life == null || life <= 0) return 0;
    return averagePrice / life;
  }
}

class Budget {
  Budget(this._o);
  final JObj _o;

  List<IncomeItem> get incomes => _o.objects('incomes').map(IncomeItem.new).toList();
  List<CostItem> get deductions => _o.objects('deductions').map(CostItem.new).toList();
  List<CostItem> get expenses => _o.objects('expenses').map(CostItem.new).toList();
  List<TrackedItem> get trackedItems => _o.objects('trackedItems').map(TrackedItem.new).toList();
  TaxSettings get taxSettings => TaxSettings(JObj.lazy(_o.writeMap, 'taxSettings'));
  Json? get ratesJson => _o.raw('rates') is Map ? (_o.raw('rates') as Map).cast<String, dynamic>() : null;
  late final TaxRates rates = TaxRates.effective(_o.raw('rates'));

  void upsertIncome(Json item) => _o.upsertById('incomes', item);
  void removeIncome(String id) => _o.removeWhere('incomes', (e) => e['id'] == id);
  void upsertDeduction(Json item) => _o.upsertById('deductions', item);
  void removeDeduction(String id) => _o.removeWhere('deductions', (e) => e['id'] == id);
  void upsertExpense(Json item) => _o.upsertById('expenses', item);
  void removeExpense(String id) => _o.removeWhere('expenses', (e) => e['id'] == id);

  bool hasAuto(AutoDeduction type) => deductions.any((d) => d.auto == type);

  /// Taxable gross income — the base for tax, insurance and percentage deductions.
  double get gross => incomes.where((i) => !i.isNet).fold(0.0, (a, i) => a + i.monthlyTotal);

  /// Income that is already net (e.g. IDF soldier pay) — added after deductions.
  double get netIncomes => incomes.where((i) => i.isNet).fold(0.0, (a, i) => a + i.monthlyTotal);

  double get totalIncome => gross + netIncomes;

  double get pensionContribution {
    if (!taxSettings.contributesPension()) return 0;
    final g = gross;
    return deductions
        .where((d) => d.isActive && d.auto == AutoDeduction.pension)
        .fold(0.0, (a, d) => a + g * d.value / 100);
  }

  double rawDeductionAmount(CostItem item) {
    final type = item.auto;
    if (item.kind != CostKind.automatic || type == null) return item.rawAmount(gross);
    final g = gross;
    return switch (type) {
      AutoDeduction.incomeTax =>
        TaxCalc.incomeTax(g, taxSettings.creditPoints, pensionContribution, rates),
      AutoDeduction.nationalInsurance => TaxCalc.nationalInsurance(g, rates),
      AutoDeduction.healthInsurance => TaxCalc.healthInsurance(g, rates),
      AutoDeduction.pension => taxSettings.contributesPension() ? g * item.value / 100 : 0,
      AutoDeduction.studyFund => g * item.value / 100,
    };
  }

  double deductionAmount(CostItem item) => item.isActive ? rawDeductionAmount(item) : 0;
  double get totalDeductions => deductions.fold(0.0, (a, d) => a + deductionAmount(d));
  double get net => gross - totalDeductions + netIncomes;
  double get expenseBase => net > 0 ? net : 0;
  double get totalExpenses {
    final base = expenseBase;
    return expenses.fold(0.0, (a, e) => a + e.amount(base));
  }

  double get periodicTotal =>
      trackedItems.where((t) => t.includeInBudget).fold(0.0, (a, t) => a + t.monthlyCost);
  double get remaining => net - totalExpenses - periodicTotal;
}

// MARK: - History

class MonthRecord {
  MonthRecord(this.json);
  final Json json;
  JObj get _o => JObj(json);
  String get id => _o.s('id');
  int get year => _o.i('year');
  int get month => _o.i('month');
  String get note => _o.s('note');
  double? get actualNet => _o.dOpt('actualNet');
  int get sortKey => year * 100 + month;
}

// MARK: - Money

enum AccountKind {
  checking('עו״ש'),
  savings('חיסכון נזיל'),
  deposit('פיקדון / תוכנית חיסכון'),
  pension('פנסיה');

  const AccountKind(this.title);
  final String title;
  bool get hasInterest => this == savings || this == deposit;
  String get rateTitle => this == pension ? 'תשואה שנתית משוערת' : 'ריבית שנתית';
}

enum Compounding {
  simple('פשוטה (משולמת בפירעון)'),
  monthly('צבירה חודשית'),
  yearly('צבירה שנתית');

  const Compounding(this.title);
  final String title;
}

enum RateType {
  fixed('ריבית קבועה'),
  prime('צמודה לפריים');

  const RateType(this.title);
  final String title;
}

T _enum<T extends Enum>(List<T> values, String? s, T def) =>
    values.firstWhere((v) => v.name == s, orElse: () => def);

class BalanceEntry {
  BalanceEntry(this.json);
  final Json json;
  JObj get _o => JObj(json);

  static Json create({required DateTime date, required double amount, String note = ''}) => {
        'id': newId(),
        'date': dateTimeToSwift(date),
        'amount': amount == amount.roundToDouble() ? amount.toInt() : amount,
        'note': note,
      };

  String get id => _o.s('id');
  DateTime get date => _o.date('date') ?? DateTime.now();
  double get amount => _o.d('amount');
  String get note => _o.s('note');
}

class RateTier {
  RateTier(this.json);
  final Json json;
  int get fromMonth => JObj(json).i('fromMonth');
  double get primeMinus => JObj(json).d('primeMinus');
}

class Account {
  Account(this.json);
  final Json json;
  JObj get _o => JObj(json);

  static Json create({String name = '', AccountKind kind = AccountKind.checking}) => {
        'id': newId(),
        'name': name,
        'kind': kind.name,
        'balances': <dynamic>[],
        'annualRate': 0,
        'compounding': 'simple',
        'interestTax': 15,
        'monthlyContribution': 0,
        'note': '',
        'rateType': 'fixed',
        'primeMinus': 0,
        'contributionDay': 1,
        'exitFirstMonths': 0,
        'exitEveryMonths': 0,
        'rateTiers': <dynamic>[],
      };

  String get id => _o.s('id');
  String get name => _o.s('name');
  set name(String v) => _o.set('name', v);
  AccountKind get kind => _enum(AccountKind.values, _o.sOpt('kind'), AccountKind.checking);
  set kind(AccountKind v) => _o.set('kind', v.name);
  List<BalanceEntry> get balances => _o.objects('balances').map(BalanceEntry.new).toList();
  void upsertBalance(Json entry) => _o.upsertById('balances', entry);
  void removeBalance(String id) => _o.removeWhere('balances', (e) => e['id'] == id);
  double get annualRate => _o.d('annualRate');
  set annualRate(double v) => _o.set('annualRate', v);
  Compounding get compounding => _enum(Compounding.values, _o.sOpt('compounding'), Compounding.simple);
  set compounding(Compounding v) => _o.set('compounding', v.name);
  DateTime? get maturityDate => _o.date('maturityDate');
  set maturityDate(DateTime? v) => _o.set('maturityDate', v);
  double get interestTax => _o.d('interestTax', 15);
  set interestTax(double v) => _o.set('interestTax', v);
  double get monthlyContribution => _o.d('monthlyContribution');
  set monthlyContribution(double v) => _o.set('monthlyContribution', v);
  String get note => _o.s('note');
  set note(String v) => _o.set('note', v);
  RateType get rateType => _enum(RateType.values, _o.sOpt('rateType'), RateType.fixed);
  set rateType(RateType v) => _o.set('rateType', v.name);
  double get primeMinus => _o.d('primeMinus');
  set primeMinus(double v) => _o.set('primeMinus', v);
  DateTime? get startDate => _o.date('startDate');
  set startDate(DateTime? v) => _o.set('startDate', v);
  int get contributionDay => _o.i('contributionDay', 1);
  set contributionDay(int v) => _o.set('contributionDay', v);
  int get exitFirstMonths => _o.i('exitFirstMonths');
  int get exitEveryMonths => _o.i('exitEveryMonths');
  List<RateTier> get rateTiers => _o.objects('rateTiers').map(RateTier.new).toList();

  bool get isPrimeLinked => rateType == RateType.prime && kind != AccountKind.pension;

  BalanceEntry? get latestBalance {
    final b = balances;
    if (b.isEmpty) return null;
    return b.reduce((a, c) => c.date.isAfter(a.date) ? c : a);
  }
}

enum TransactionKind {
  income('הכנסה'),
  expense('הוצאה'),
  transfer('העברה');

  const TransactionKind(this.title);
  final String title;
}

class MoneyTransaction {
  MoneyTransaction(this.json);
  final Json json;
  JObj get _o => JObj(json);

  static Json create({TransactionKind kind = TransactionKind.expense, String? accountID}) => {
        'id': newId(),
        'date': dateTimeToSwift(DateTime.now()),
        'title': '',
        'amount': 0,
        'kind': kind.name,
        if (accountID != null) 'accountID': accountID,
        'note': '',
        'paidByCard': false,
        'cardInstallments': 1,
      };

  String get id => _o.s('id');
  DateTime get date => _o.date('date') ?? DateTime.now();
  set date(DateTime v) => _o.set('date', v);
  String get title => _o.s('title');
  set title(String v) => _o.set('title', v);
  double get amount => _o.d('amount');
  set amount(double v) => _o.set('amount', v);
  TransactionKind get kind => _enum(TransactionKind.values, _o.sOpt('kind'), TransactionKind.expense);
  set kind(TransactionKind v) => _o.set('kind', v.name);
  String? get accountID => _o.sOpt('accountID');
  set accountID(String? v) => _o.set('accountID', v);
  String? get toAccountID => _o.sOpt('toAccountID');
  set toAccountID(String? v) => _o.set('toAccountID', v);
  String get note => _o.s('note');
  set note(String v) => _o.set('note', v);
  int? get salaryKey => _o.iOpt('salaryKey');
  bool get paidByCard => _o.b('paidByCard');
  set paidByCard(bool v) => _o.set('paidByCard', v);
  int get cardInstallments => _o.i('cardInstallments', 1).clamp(1, 1000);
  set cardInstallments(int v) => _o.set('cardInstallments', v);

  bool get isPlanned => date.isAfter(DateTime.now());

  /// Signed change this transaction makes to `account`.
  double effectOn(String account) {
    switch (kind) {
      case TransactionKind.income:
        return accountID == account ? amount : 0;
      case TransactionKind.expense:
        if (paidByCard) return 0;
        return accountID == account ? -amount : 0;
      case TransactionKind.transfer:
        var change = 0.0;
        if (accountID == account) change -= amount;
        if (toAccountID == account) change += amount;
        return change;
    }
  }
}

class MoneyData {
  MoneyData(this._o);
  final JObj _o;

  List<Account> get accounts => _o.objects('accounts').map(Account.new).toList();
  List<MoneyTransaction> get transactions => _o.objects('transactions').map(MoneyTransaction.new).toList();
  double get primeRate => _o.d('primeRate', 4.75);
  bool get primeAuto => _o.b('primeAuto', true);
  int get cardTransactionCount => (_o.raw('cardTransactions') as List?)?.length ?? 0;

  Account? get checking {
    for (final a in accounts) {
      if (a.kind == AccountKind.checking) return a;
    }
    return null;
  }

  Account? account(String? id) {
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Swift adds a checking account whenever there is none; here it's added only when one is needed.
  Account ensureChecking() {
    final c = checking;
    if (c != null) return c;
    final created = Account.create(name: 'עו״ש', kind: AccountKind.checking);
    _o.writeList('accounts').insert(0, created);
    return Account(created);
  }

  void upsertAccount(Json account) => _o.upsertById('accounts', account);
  void upsertTransaction(Json t) => _o.upsertById('transactions', t);
  void removeTransaction(String id) => _o.removeWhere('transactions', (e) => e['id'] == id);
  void removeTransactionsWhere(bool Function(Json) test) => _o.removeWhere('transactions', test);

  /// Port of `Store.deleteAccount`.
  void deleteAccount(String id, Budget budget) {
    _o.removeWhere('accounts', (a) => a['id'] == id);
    _o.removeWhere('transactions', (t) => t['accountID'] == id && t['toAccountID'] == null);
    for (final t in transactions) {
      if (t.toAccountID == id) t.toAccountID = null;
      if (t.accountID == id) t.accountID = null;
    }
    for (final e in budget.expenses) {
      if (e.targetAccountID == id) e.targetAccountID = null;
    }
    if (checking == null) {
      _o.writeList('accounts').insert(0, Account.create(name: 'עו״ש', kind: AccountKind.checking));
    }
  }
}

// MARK: - New data, encoded like the Swift app encodes it

class Starter {
  /// `Budget.starter`.
  static Json budget({Json? rates}) => {
        'incomes': [IncomeItem.create(name: 'משכורת')],
        'deductions': [
          CostItem.automatic(AutoDeduction.incomeTax),
          CostItem.automatic(AutoDeduction.nationalInsurance),
          CostItem.automatic(AutoDeduction.healthInsurance),
          CostItem.automatic(AutoDeduction.pension),
        ],
        'expenses': [
          CostItem.create(name: 'שכירות'),
          CostItem.create(name: 'טלפון ואינטרנט'),
          CostItem.create(name: 'חיסכון', kind: CostKind.percent, value: 10),
        ],
        'trackedItems': <dynamic>[],
        'taxSettings': {'creditPoints': 2.25, 'pensionMode': 'contributes'},
        'rates': deepCopy(rates ?? TaxRates.bundled.json),
      };

  /// `MoneyData()` (keys the Swift decoder fills in by itself are left out).
  static Json money() => {
        'accounts': [Account.create(name: 'עו״ש', kind: AccountKind.checking)],
        'transactions': <dynamic>[],
        'forecast': {'months': 6, 'basis': 'recentAverage', 'manualNet': 0},
        'primeRate': 4.75,
        'primeAuto': true,
      };

  /// `Store.newMemberFile()`.
  static Json memberFile({Json? ratesFrom, MoneyData? moneyFrom}) {
    final money = Starter.money();
    if (moneyFrom != null) {
      money['primeRate'] = moneyFrom.primeRate;
      money['primeAuto'] = moneyFrom.primeAuto;
    }
    return {'budget': budget(rates: ratesFrom), 'history': <dynamic>[], 'money': money};
  }

  /// `ServerSync.emptyFamily`: one member ("אני"), starter budget, the current tax rates.
  static Json family() {
    final id = newId();
    return {
      'state': {
        'members': [
          {'id': id, 'name': 'אני', 'emoji': '🙂'}
        ],
        'primaryID': id,
        'activeID': id,
        'viewIDs': [id],
      },
      'files': {
        id: {'budget': budget(), 'history': <dynamic>[], 'money': money()},
      },
    };
  }
}
