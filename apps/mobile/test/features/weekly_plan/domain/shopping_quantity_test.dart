import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_quantity.dart';

/// Grammi sommati dal piano → quantità da comprare.
const List<(double, String)> _grams = [
  // Sotto i 100 g: multipli di 10, e niente sparisce.
  (4, '10 g'),
  (10, '10 g'),
  (12, '10 g'),
  (15, '20 g'),
  (47, '50 g'),
  (95, '100 g'),
  // Sotto il chilo: multipli di 50.
  (100, '100 g'),
  (124, '100 g'),
  (130, '150 g'),
  (225, '250 g'),
  (487.5, '500 g'),
  (975, '1 kg'),
  // Dal chilo in su: kg con una cifra.
  (1000, '1 kg'),
  (1050, '1,1 kg'),
  (1240, '1,2 kg'),
  (1980, '2 kg'),
  (2000, '2 kg'),
  (12340, '12,3 kg'),
];

void main() {
  group('formatGrams', () {
    for (final (grams, expected) in _grams) {
      test('$grams g → $expected', () {
        expect(ShoppingQuantities.formatGrams(grams), expected);
      });
    }

    test('zero e valori assurdi non producono numeri assurdi', () {
      expect(ShoppingQuantities.formatGrams(0), '0 g');
      expect(ShoppingQuantities.formatGrams(-10), '0 g');
      expect(ShoppingQuantities.formatGrams(double.nan), '0 g');
    });
  });

  group('unità naturali', () {
    test('le uova si comprano a pezzi', () {
      final quantity = ShoppingQuantities.format(name: 'Uova', grams: 165);

      expect(quantity.display, '3 uova');
      expect(quantity.note, '≈ 165 g');
      expect(quantity.grams, 165);
    });

    test('un uovo solo resta al singolare, e non si scende sotto uno', () {
      expect(
        ShoppingQuantities.format(name: 'Uovo intero', grams: 55).display,
        '1 uovo',
      );
      expect(
        ShoppingQuantities.format(name: 'uova', grams: 12).display,
        '1 uovo',
      );
    });

    test('l\'uovo dentro un altro alimento resta a peso', () {
      // Ricette vere del ricettario: la pasta all'uovo si compra a grammi, e
      // così albumi e tuorli. «3 uova» al posto di 150 g di tagliatelle
      // manderebbe Marco al banco sbagliato.
      final pasta = ShoppingQuantities.format(
        name: "Tagliatelle all'uovo secche",
        grams: 140,
      );
      expect(pasta.display, '150 g');
      expect(pasta.note, isNull);

      final albume = ShoppingQuantities.format(
        name: "Albume d'uovo",
        grams: 300,
      );
      expect(albume.display, '300 g');
      expect(albume.note, isNull);

      expect(
        ShoppingQuantities.format(name: "Tuorlo d'uovo", grams: 34).display,
        '30 g',
      );
    });

    test('poco olio si misura a cucchiai', () {
      final quantity = ShoppingQuantities.format(
        name: 'Olio extravergine di oliva',
        grams: 20,
      );

      expect(quantity.display, '2 cucchiai');
      expect(quantity.note, '≈ 20 g');
    });

    test('un cucchiaio solo resta al singolare', () {
      expect(
        ShoppingQuantities.format(name: 'olio di semi', grams: 8).display,
        '1 cucchiaio',
      );
    });

    test('tanto olio si compra in ml', () {
      final quantity = ShoppingQuantities.format(
        name: "Olio d'oliva",
        grams: 184,
      );

      expect(quantity.display, '200 ml');
      expect(quantity.note, '≈ 184 g');
    });

    test('tutto il resto resta in grammi, senza nota', () {
      final quantity = ShoppingQuantities.format(
        name: 'Petto di pollo',
        grams: 487.5,
      );

      expect(quantity.display, '500 g');
      expect(quantity.note, isNull);
      expect(quantity.grams, 487.5);
    });
  });
}
