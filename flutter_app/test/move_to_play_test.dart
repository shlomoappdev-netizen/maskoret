import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/ui/app_prompts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the move to Google Play is asked at first, then again only after a few days', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime(2026, 11, 10, 12);
    expect(MoveToPlay.due(prefs, now: now), isTrue);
    await MoveToPlay.markAsked(prefs, now: now);
    expect(MoveToPlay.due(prefs, now: now.add(const Duration(days: 1))), isFalse);
    expect(MoveToPlay.due(prefs, now: now.add(MoveToPlay.every)), isTrue);
  });
}
