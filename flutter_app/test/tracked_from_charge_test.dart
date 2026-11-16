import 'package:flutter_test/flutter_test.dart';
import 'package:maskoret/data/card.dart';
import 'package:maskoret/data/json.dart';
import 'package:maskoret/data/max_import.dart';
import 'package:maskoret/data/models.dart';

/// A save file with only the given card charges and one tracked item.
SaveFile _file(List<Json> charges) => SaveFile({
      'budget': {
        'trackedItems': [
          {'id': 'shoes', 'name': 'נעליים', 'emoji': '👟', 'expectedMonths': 12, 'purchases': <dynamic>[]},
        ],
      },
      'money': {'cardTransactions': charges},
    });

Json _tx(String id, DateTime date, String merchant, double amount, {double original = 0, Json extra = const {}}) => {
      'id': id,
      'date': dateTimeToSwift(date),
      'merchant': merchant,
      'amount': amount,
      'originalAmount': original,
      ...extra,
    };

void main() {
  test('the recent charges offered for a purchase: newest first, each installment purchase once, nothing already used', () {
    final file = _file([
      _tx('old', DateTime(2026, 9, 1, 12), 'חנות ספרים', 50),
      _tx('new', DateTime(2026, 11, 10, 12), 'נעלי ספורט', 400),
      // Installments 1 and 2 of one purchase repeat its date, merchant and full price.
      _tx('tv1', DateTime(2026, 8, 5, 12), 'חנות חשמל', 100, original: 600),
      _tx('tv2', DateTime(2026, 8, 5, 12), 'חנות חשמל', 100, original: 600),
      _tx('refund', DateTime(2026, 11, 11, 12), 'החזר', -80),
      _tx('ignored', DateTime(2026, 11, 12, 12), 'מתעלמים', 30, extra: {'ignored': true}),
      _tx('fixed', DateTime(2026, 11, 13, 12), 'חשמל', 300, extra: {'linkedExpenseID': 'e1'}),
      _tx('tracked', DateTime(2026, 11, 14, 12), 'מספרה', 60, extra: {'linkedTrackedID': 'hair'}),
    ]);
    final offered = CardData(file.money).recentForTracked();
    expect(offered.map((t) => t.merchant), ['נעלי ספורט', 'חנות ספרים', 'חנות חשמל']);
    expect(offered.last.purchasePrice, 600, reason: 'an installment purchase is offered at its full price');
  });

  test('saving a purchase from a charge links that charge and records one purchase, even with an edited price', () {
    final file = _file([_tx('c1', DateTime(2026, 11, 10, 12), 'נעלי ספורט', 400)]);
    final tx = CardData(file.money).recentForTracked().single;
    // What the purchase editor saves: the charge's date and merchant, with the price changed by the user.
    file.budget.addPurchase('shoes', Purchase.create(date: tx.date, price: 350, note: tx.merchant));
    CardActions(file).markAsTracked(tx.id, 'shoes');

    final linked = CardData(file.money).cardTransactions.single;
    expect(linked.linkedTrackedID, 'shoes');
    expect(linked.linkedExpenseID, isNull);
    final purchases = file.budget.trackedItems.single.purchases;
    expect(purchases.length, 1, reason: 'linking does not record the purchase a second time');
    expect(purchases.single.price, 350);
    expect(CardData(file.money).recentForTracked(), isEmpty, reason: 'a linked charge is not offered again');
  });
}
