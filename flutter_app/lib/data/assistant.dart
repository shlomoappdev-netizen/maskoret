import 'json.dart';

/// One short thing the assistant knows ("מצב משפחתי: זוג עם ילדים") — AssistantFact in Assistant.swift.
class AssistantFact {
  AssistantFact(this.json);
  final Json json;

  String get id => json['id'] as String? ?? '';
  String get text => json['text'] as String? ?? '';
  DateTime? get date => json['date'] is num ? swiftDateToDateTime(json['date'] as num) : null;

  /// The question this answers (AssistantQuestion.id), when it came from one.
  String? get questionID => json['questionID'] as String?;

  static Json create({required String text, required DateTime date, String? questionID}) => {
        'id': newId(),
        'text': text,
        'date': dateTimeToSwift(date),
        if (questionID != null) 'questionID': questionID,
      };
}

/// A getting-to-know-you question shown at the top of the screens it belongs to (AssistantQuestion in Assistant.swift).
class AssistantQuestion {
  const AssistantQuestion(this.id, this.label, this.text, this.answers, this.screens);
  final String id;

  /// What the fact is called ("מצב משפחתי"); the fact is "label: answer".
  final String label;
  final String text;
  final List<String> answers;

  /// The screens it shows on (Dest names, the same as the Mac's SidebarItem raw values).
  final List<String> screens;

  /// The same list, in the same order, as `AssistantQuestion.all` in Assistant.swift.
  static const all = [
    AssistantQuestion('family', 'מצב משפחתי', 'מי בבית?',
        ['רווק/ה', 'זוג בלי ילדים', 'זוג עם ילדים', 'הורה יחיד'], ['summary', 'incomes']),
    AssistantQuestion('goal', 'יעד כספי עיקרי', 'מה היעד הכספי הכי חשוב לך עכשיו?',
        ['לסגור את החודש בלי מינוס', 'לבנות כרית ביטחון', 'לחסוך לדירה', 'לחסוך למטרה גדולה אחרת', 'להשקיע לטווח ארוך'],
        ['summary', 'accounts', 'forecast']),
    AssistantQuestion('housing', 'מגורים', 'מה מצב המגורים שלך?',
        ['שכירות', 'דירה בבעלות עם משכנתא', 'דירה בבעלות בלי משכנתא', 'אצל ההורים'], ['expenses', 'summary']),
    AssistantQuestion('car', 'רכב', 'יש רכב בבית?',
        ['אין רכב', 'רכב אחד', 'שני רכבים או יותר', 'רכב מהעבודה / ליסינג'], ['expenses', 'card']),
    AssistantQuestion('income_stability', 'יציבות ההכנסה', 'כמה ההכנסה שלך קבועה מחודש לחודש?',
        ['קבועה', 'משתנה קצת', 'משתנה מאוד'], ['incomes', 'forecast']),
    AssistantQuestion('big_change', 'שינוי גדול צפוי בשנה הקרובה', 'צפוי שינוי גדול בשנה הקרובה?',
        ['לא צפוי שינוי', 'ילד/ה בדרך', 'מעבר דירה', 'חתונה או אירוע גדול', 'החלפת עבודה', 'קניית רכב'], ['forecast', 'summary']),
    AssistantQuestion('hard_spot', 'המקום שהכי קשה לעמוד בו בתקציב', 'איפה הכי קשה לך לעמוד בתקציב?',
        ['אוכל בחוץ ומשלוחים', 'סופר', 'קניות ובגדים', 'בילויים ויציאות', 'ילדים', 'לא קשה לי במיוחד'], ['trends', 'card']),
    AssistantQuestion('runway', 'לכמה זמן החיסכון מספיק בלי הכנסה', 'אם ההכנסה נעצרת מחר — לכמה זמן החיסכון מספיק?',
        ['פחות מחודש', '1–3 חודשים', '3–6 חודשים', 'יותר מחצי שנה'], ['accounts', 'forecast']),
    AssistantQuestion('tone', 'איך לדבר איתי על חריגות', 'כשיש חריגה מהתקציב — איך להגיד לך?',
        ['ישר ולעניין', 'בעדינות, עם עידוד', 'רק מספרים, בלי הערות'], ['trends', 'card', 'summary']),
  ];
}

/// What the assistant knows about one family member, and its questions — a view over `money.assistant`
/// (AssistantProfile in Assistant.swift; the same JSON).
class AssistantProfile {
  AssistantProfile(this._money);

  /// The member's money object; `assistant` is created inside it on the first write.
  final JObj _money;

  /// The longest a fact can be (what the user writes and what the model asks to remember).
  static const maxFactLength = 200;

  Json? get _read {
    final v = _money.raw('assistant');
    return v is Json ? v : (v is Map ? v.cast<String, dynamic>() : null);
  }

  JObj get _write => JObj.lazy(_money.writeMap, 'assistant');

  List<AssistantFact> get facts {
    final v = _read?['facts'];
    if (v is! List) return const [];
    return [for (final e in v) if (e is Map) AssistantFact(e is Json ? e : e.cast<String, dynamic>())];
  }

  /// Questions the user asked not to be asked.
  List<String> get skipped {
    final v = _read?['skipped'];
    return v is List ? v.whereType<String>().toList() : const [];
  }

  /// When a question was last answered or put off: at most one a day.
  DateTime? get lastAskedAt {
    final v = _read?['lastAskedAt'];
    return v is num ? swiftDateToDateTime(v) : null;
  }

  /// Tips the user put off with "לא עכשיו" (AssistantTip.id).
  List<String> get dismissedTips {
    final v = _read?['dismissedTips'];
    return v is List ? v.whereType<String>().toList() : const [];
  }

  /// How many put-off tips are kept (their ids carry a month, so old ones stop mattering).
  static const maxDismissedTips = 200;

  /// "לא עכשיו" on a tip: this one doesn't show again.
  void dismissTip(String id) {
    final list = _write.writeList('dismissedTips');
    if (list.contains(id)) return;
    list.add(id);
    if (list.length > maxDismissedTips) list.removeRange(0, list.length - maxDismissedTips);
  }

  static String _normalized(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// The question to show at the top of a screen now: none when one was already asked today, otherwise the first
  /// one of this screen that wasn't answered or turned off.
  AssistantQuestion? questionFor(String screen, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final last = lastAskedAt?.toLocal();
    if (last != null && last.year == today.year && last.month == today.month && last.day == today.day) return null;
    final answered = {for (final f in facts) f.questionID};
    final off = skipped;
    for (final q in AssistantQuestion.all) {
      if (q.screens.contains(screen) && !answered.contains(q.id) && !off.contains(q.id)) return q;
    }
    return null;
  }

  /// An answer becomes a fact (replacing an earlier answer to the same question).
  void answer(AssistantQuestion question, String answer, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final o = _write;
    o.removeWhere('facts', (f) => f['questionID'] == question.id);
    o.addObject('facts', AssistantFact.create(text: '${question.label}: $answer', date: at, questionID: question.id));
    o.set('lastAskedAt', at);
  }

  /// "לא עכשיו": the question comes back another day.
  void postpone({DateTime? now}) => _write.set('lastAskedAt', now ?? DateTime.now());

  /// "אל תשאל שוב".
  void skip(AssistantQuestion question, {DateTime? now}) {
    _skip(question.id);
    _write.set('lastAskedAt', now ?? DateTime.now());
  }

  void _skip(String id) {
    final list = _write.writeList('skipped');
    if (!list.contains(id)) list.add(id);
  }

  /// Adds a fact in the user's (or the model's) words. False when it's empty or already there.
  bool remember(String text, {DateTime? now}) {
    var t = text.trim();
    if (t.characters > maxFactLength) t = String.fromCharCodes(t.runes.take(maxFactLength));
    final key = _normalized(t);
    if (key.isEmpty || facts.any((f) => _normalized(f.text) == key)) return false;
    _write.addObject('facts', AssistantFact.create(text: t, date: now ?? DateTime.now()));
    return true;
  }

  /// Removes a fact. An answer that was deleted isn't asked about again.
  void forget(String id) {
    final fact = facts.where((f) => f.id == id).firstOrNull;
    if (fact == null) return;
    if (fact.questionID != null) _skip(fact.questionID!);
    _write.removeWhere('facts', (f) => f['id'] == id);
  }

  /// Removes the fact the model named: the same text, or one that contains it / is contained in it. False when none.
  bool forgetMatching(String text) {
    final wanted = _normalized(text);
    if (wanted.isEmpty) return false;
    final all = facts;
    final found = all.where((f) => _normalized(f.text) == wanted).firstOrNull ??
        all.where((f) {
          final n = _normalized(f.text);
          return n.isNotEmpty && (n.contains(wanted) || wanted.contains(n));
        }).firstOrNull;
    if (found == null) return false;
    forget(found.id);
    return true;
  }
}

extension on String {
  int get characters => runes.length;
}
