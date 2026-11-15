@Tags(['swift'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/assistant.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/models.dart';
import 'package:maskoret/insights/ai_actions.dart';
import 'package:maskoret/insights/engine.dart';

/// The assistant's profile ("מה העוזר יודע עליי") and its questions — the logic, and the same JSON as Assistant.swift.
void main() {
  final canRun = Platform.isMacOS && Process.runSync('which', ['swiftc']).exitCode == 0;
  const screens = ['summary', 'incomes', 'expenses', 'accounts', 'trends', 'card', 'forecast', 'insights'];

  (Json, SaveFile) fresh() {
    final doc = Starter.family();
    final family = FamilyBackup(doc);
    return (doc, family.fileForEditing(family.state.primaryID));
  }

  AssistantQuestion q(String id) => AssistantQuestion.all.firstWhere((x) => x.id == id);

  test('every screen with a card has questions, and ids are unique', () {
    expect(AssistantQuestion.all.map((x) => x.id).toSet().length, AssistantQuestion.all.length);
    for (final s in screens.where((s) => s != 'insights')) {
      expect(AssistantQuestion.all.where((x) => x.screens.contains(s)), isNotEmpty, reason: s);
    }
    for (final x in AssistantQuestion.all) {
      expect(x.answers.length, greaterThan(1), reason: x.id);
      expect(x.screens.every(screens.contains), isTrue, reason: x.id);
    }
  });

  test('one question a day: an answer becomes a fact, and the next one waits for tomorrow', () {
    final (doc, file) = fresh();
    final a = file.money.assistant;
    final day1 = DateTime(2026, 11, 15, 9), day2 = DateTime(2026, 11, 16, 0, 5);
    expect((doc['files'] as Map).values.first['money'].containsKey('assistant'), isFalse, reason: 'reading creates nothing');
    expect(a.questionFor('summary', now: day1)?.id, 'family');
    expect(a.questionFor('insights', now: day1), isNull);

    a.answer(q('family'), 'זוג עם ילדים', now: day1);
    expect(a.facts.single.text, 'מצב משפחתי: זוג עם ילדים');
    expect(a.facts.single.questionID, 'family');
    expect(a.questionFor('summary', now: day1), isNull, reason: 'already asked today');
    expect(a.questionFor('trends', now: DateTime(2026, 11, 15, 23, 59)), isNull, reason: 'on every screen');
    expect(a.questionFor('summary', now: day2)?.id, 'goal', reason: 'the next day, the next question');

    a.postpone(now: day2);
    expect(a.questionFor('summary', now: day2), isNull);
    expect(a.questionFor('summary', now: DateTime(2026, 11, 17, 8))?.id, 'goal', reason: '"לא עכשיו" comes back');

    a.skip(q('goal'), now: DateTime(2026, 11, 17, 8));
    expect(a.skipped, ['goal']);
    expect(a.questionFor('summary', now: DateTime(2026, 11, 18, 8))?.id, 'housing', reason: '"אל תשאל שוב" never comes back');

    // Answering again replaces the earlier answer.
    a.answer(q('family'), 'הורה יחיד', now: DateTime(2026, 11, 19));
    expect(a.facts.map((f) => f.text), ['מצב משפחתי: הורה יחיד']);
  });

  test('facts: add in your own words, no duplicates, delete; a deleted answer is not asked about again', () {
    final (_, file) = fresh();
    final a = file.money.assistant;
    expect(a.remember('  חוסכים לחתונה בקיץ '), isTrue);
    expect(a.remember('חוסכים לחתונה, בקיץ!'), isFalse, reason: 'the same thing');
    expect(a.remember('   '), isFalse);
    expect(a.remember('א' * 500), isTrue);
    expect(a.facts.last.text.length, AssistantProfile.maxFactLength);
    expect(a.facts.first.text, 'חוסכים לחתונה בקיץ');
    expect(a.lastAskedAt, isNull, reason: 'writing a fact is not a question');

    a.answer(q('car'), 'רכב אחד', now: DateTime(2026, 11, 15));
    a.forget(a.facts.last.id);
    expect(a.skipped, ['car']);
    expect(a.questionFor('expenses', now: DateTime(2026, 11, 20))?.id, 'housing');

    expect(a.forgetMatching('חתונה בקיץ'), isTrue);
    expect(a.forgetMatching('משהו שלא קיים'), isFalse);
    expect(a.facts.length, 1);
  });

  test('the model can ask to remember and to forget, and the user approves', () {
    final (_, file) = fresh();
    final plan = AIActionPlan.decode(
        '{"summary":"x","actions":[{"type":"remember_fact","fact":"מתכננים לעבור דירה באביב"},{"type":"forget_fact","fact":"לעבור דירה"}]}')!;
    expect(plan.actions.map((x) => x.title), ['לזכור עליך: מתכננים לעבור דירה באביב', 'לשכוח: לעבור דירה']);
    applyAIAction(plan.actions[0], file);
    expect(file.money.assistant.facts.single.text, 'מתכננים לעבור דירה באביב');
    applyAIAction(plan.actions[1], file);
    expect(file.money.assistant.facts, isEmpty);
    expect(() => applyAIAction(plan.actions[1], file), throwsA(isA<AIActionError>()));
    expect(() => applyAIAction(AIAction(0, 'remember_fact', {}), file), throwsA(isA<AIActionError>()));
    expect(InsightsEngine.systemPrompt, contains('remember_fact'));
    expect(InsightsEngine.systemPrompt, contains('## הטון שלך'));
  });

  test('Swift reads the profile this app wrote, asks the same questions, and has the same list', () {
    final (doc, file) = fresh();
    final a = file.money.assistant;
    final now = DateTime(2026, 11, 20, 10);
    a.answer(q('family'), 'זוג בלי ילדים', now: DateTime(2026, 11, 15, 9));
    a.remember('חוסכים לחתונה בקיץ', now: DateTime(2026, 11, 15, 9));
    a.skip(q('goal'), now: DateTime(2026, 11, 16, 9));
    final f = File('${Directory.systemTemp.createTempSync('assistant').path}/doc.json')..writeAsStringSync(jsonEncode(doc));
    final r = Process.runSync('tool/swift_check.sh', [f.path, '${dateTimeToSwift(now)}']);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final out = jsonDecode((r.stdout as String).trim().split('\n').last) as Map<String, dynamic>;
    final s = (out['files'] as Map).values.first['assistant'] as Map<String, dynamic>;
    expect(s['facts'], a.facts.map((x) => x.text));
    expect(s['questionIDs'], a.facts.map((x) => x.questionID ?? ''));
    expect(s['skipped'], a.skipped);
    expect(s['asked'], isTrue);
    expect(s['next'], [for (final screen in screens) a.questionFor(screen, now: now)?.id ?? '']);
    expect(s['questions'], [for (final x in AssistantQuestion.all) [x.id, x.label, x.text, ...x.answers, ...x.screens]]);
  }, skip: canRun ? false : 'needs swiftc (macOS)');
}
