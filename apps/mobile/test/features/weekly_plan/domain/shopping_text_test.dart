import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_text.dart';

void main() {
  group('normalize', () {
    test('minuscolo, senza accenti e senza punteggiatura', () {
      expect(ShoppingText.normalize('Pomodorì  Pelàti!'), 'pomodori pelati');
      expect(ShoppingText.normalize("Olio d'oliva"), 'olio d oliva');
      expect(ShoppingText.normalize('  Riso   basmati  '), 'riso basmati');
      expect(ShoppingText.normalize('Ceci (secchi)'), 'ceci secchi');
    });

    test('un nome fatto di soli simboli diventa vuoto', () {
      expect(ShoppingText.normalize('***'), '');
      expect(ShoppingText.normalize(''), '');
    });
  });

  group('singular', () {
    test('plurali banali maschili', () {
      expect(ShoppingText.singular('pomodori'), 'pomodoro');
      expect(ShoppingText.singular('fagioli'), 'fagiolo');
      expect(ShoppingText.singular('spaghetti'), 'spaghetto');
    });

    test('le forme in -chi/-ghi/-che/-ghe non si storpiano', () {
      expect(ShoppingText.singular('funghi'), 'fungo');
      expect(ShoppingText.singular('gnocchi'), 'gnocco');
      expect(ShoppingText.singular('fichi'), 'fico');
      expect(ShoppingText.singular('pesche'), 'pesca');
      expect(ShoppingText.singular('lattughe'), 'lattuga');
    });

    test('i femminili passano dalla tabella esplicita', () {
      expect(ShoppingText.singular('uova'), 'uovo');
      expect(ShoppingText.singular('mele'), 'mela');
      expect(ShoppingText.singular('carote'), 'carota');
      expect(ShoppingText.singular('zucchine'), 'zucchina');
      expect(ShoppingText.singular('zucchini'), 'zucchina');
      expect(ShoppingText.singular('ceci'), 'cece');
      expect(ShoppingText.singular('noci'), 'noce');
      expect(ShoppingText.singular('peperoni'), 'peperone');
    });

    test('le parole corte e le invariabili restano come sono', () {
      expect(ShoppingText.singular('uva'), 'uva');
      expect(ShoppingText.singular('kiwi'), 'kiwi');
      expect(ShoppingText.singular('sushi'), 'sushi');
      expect(ShoppingText.singular('riso'), 'riso');
    });

    test('nessuna regola generica -e → -a: pesce non diventa pesca', () {
      expect(ShoppingText.singular('pesce'), 'pesce');
      expect(ShoppingText.singular('latte'), 'latte');
      expect(ShoppingText.singular('pane'), 'pane');
    });
  });

  group('ingredientKey', () {
    test('unisce le grafie dello stesso alimento', () {
      expect(
        ShoppingText.ingredientKey('Pomodori'),
        ShoppingText.ingredientKey('pomodoro'),
      );
      expect(
        ShoppingText.ingredientKey("Olio d'oliva"),
        ShoppingText.ingredientKey('Olio di oliva'),
      );
      expect(
        ShoppingText.ingredientKey('Uova'),
        ShoppingText.ingredientKey('uovo'),
      );
    });

    test('toglie articoli e preposizioni ma tiene il resto', () {
      expect(ShoppingText.ingredientKey('Petto di pollo'), 'petto pollo');
      expect(ShoppingText.ingredientKey('Latte di mandorle'), 'latte mandorla');
      expect(ShoppingText.ingredientKey('Riso basmati'), 'riso basmati');
    });

    test('non unisce alimenti diversi', () {
      expect(
        ShoppingText.ingredientKey('pesce'),
        isNot(ShoppingText.ingredientKey('pesca')),
      );
      expect(
        ShoppingText.ingredientKey('riso crudo'),
        isNot(ShoppingText.ingredientKey('riso cotto')),
      );
      expect(
        ShoppingText.ingredientKey('latte'),
        isNot(ShoppingText.ingredientKey('latte di soia')),
      );
    });

    test('un nome senza lettere non produce una chiave', () {
      expect(ShoppingText.ingredientKey('***'), '');
    });
  });

  group('tokens', () {
    test('contiene sia la parola scritta sia il suo singolare', () {
      expect(
        ShoppingText.tokens('Piselli surgelati'),
        containsAll(<String>['piselli', 'pisello', 'surgelati', 'surgelato']),
      );
    });
  });
}
