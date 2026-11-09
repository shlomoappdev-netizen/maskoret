import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/month_picture.dart';
import 'package:maskoret/ui/theme.dart';

void main() {
  test('left in practice is what is expected to be left plus the card estimate', () {
    MonthPicture pic(double estimate) => MonthPicture(
          year: 2026, month: 11, estimatedNet: 10000, actualNet: null,
          spending: [MonthLine('שכירות', 4000)], periodic: 0, toSavings: const [], oneOffs: const [],
          card: [MonthLine('מזון', 1500), if (estimate > 0) MonthLine('עוד צפוי לפי ממוצע החודשים הקודמים', estimate)],
          cardEstimated: estimate > 0, cardEstimate: estimate,
          installments: const [], installmentsAfterThisMonth: 0);
    expect(pic(800).remaining, 3700);
    expect(pic(800).remainingActual, 4500);
    expect(pic(0).remainingActual, pic(0).remaining);
  });

  test('the tracked items average is a reserve in the expected number, not money that actually went out', () {
    final p = MonthPicture(
        year: 2026, month: 11, estimatedNet: 10000, actualNet: null,
        spending: [MonthLine('שכירות', 4000)], periodic: 300, toSavings: const [], oneOffs: const [],
        card: [MonthLine('ביגוד', 1200)], cardEstimated: false, cardEstimate: 0,
        installments: const [], installmentsAfterThisMonth: 0);
    expect(p.remaining, 4500);
    expect(p.remainingActual, 4800, reason: 'what was charged on the card is already counted');
    expect(p.actualOnly.remaining, 4800);
  });

  testWidgets('tiles in one row are the same height, short title or long', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
          width: 400,
          child: TileGrid(minWidth: 130, children: [
            StatTile(key: const Key('a'), title: 'קצר', value: '1', icon: Icons.star),
            StatTile(key: const Key('b'), title: 'כותרת ארוכה מאוד שיורדת לשתי שורות בריבוע צר', value: '2', icon: Icons.star),
            StatTile(key: const Key('c'), title: 'בינוני', value: '3', icon: Icons.star),
            StatTile(key: const Key('d'), title: 'שורה שנייה', value: '4', icon: Icons.star),
          ]),
        ),
      ),
    ));
    final heights = ['a', 'b', 'c'].map((k) => tester.getSize(find.byKey(Key(k))).height).toSet();
    expect(heights.length, 1);
    expect(tester.getSize(find.byKey(const Key('d'))).height, heights.single);
  });
}
