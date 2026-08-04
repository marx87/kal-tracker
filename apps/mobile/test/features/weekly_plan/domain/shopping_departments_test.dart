import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_departments.dart';

/// Tabella dei casi: nome dell'ingrediente → reparto atteso.
/// I casi ambigui stanno tutti qui, perché sono l'unica cosa che vale la pena
/// difendere con un test: il resto è una lista di parole.
const Map<String, ShoppingDepartment> _cases = {
  // Il freddo vince su tutto.
  'Piselli surgelati': ShoppingDepartment.surgelati,
  'piselli': ShoppingDepartment.ortofrutta,
  'Verdure surgelate': ShoppingDepartment.surgelati,
  'Gamberetti surgelati': ShoppingDepartment.surgelati,
  'Spinaci congelati': ShoppingDepartment.surgelati,

  // Latte «finto»: sta sullo scaffale, non al banco frigo.
  'Latte di mandorla': ShoppingDepartment.dispensa,
  'Latte di mandorle': ShoppingDepartment.dispensa,
  'latte di soia': ShoppingDepartment.dispensa,
  'Latte di cocco': ShoppingDepartment.dispensa,
  'Latte parzialmente scremato': ShoppingDepartment.bancoFrigo,
  'Latte intero': ShoppingDepartment.bancoFrigo,

  // Burro e tonno cambiano reparto a seconda di cosa li accompagna.
  'Burro di arachidi': ShoppingDepartment.dispensa,
  'Burro': ShoppingDepartment.bancoFrigo,
  'Tonno in scatola': ShoppingDepartment.dispensa,
  'Filetto di tonno': ShoppingDepartment.pescheria,

  // Macelleria.
  'Petto di pollo': ShoppingDepartment.macelleria,
  'Fesa di tacchino': ShoppingDepartment.macelleria,
  'Macinato di manzo': ShoppingDepartment.macelleria,
  'Prosciutto crudo': ShoppingDepartment.macelleria,
  'Bresaola': ShoppingDepartment.macelleria,

  // Pescheria.
  'Salmone fresco': ShoppingDepartment.pescheria,
  'Merluzzo': ShoppingDepartment.pescheria,
  'Cozze': ShoppingDepartment.pescheria,

  // Banco frigo e latticini (le uova stanno qui).
  'Uova': ShoppingDepartment.bancoFrigo,
  'Uovo intero': ShoppingDepartment.bancoFrigo,
  'Yogurt greco 0%': ShoppingDepartment.bancoFrigo,
  'Parmigiano Reggiano': ShoppingDepartment.bancoFrigo,
  'Fiocchi di latte': ShoppingDepartment.bancoFrigo,

  // Panetteria, e la trappola del pangrattato.
  'Pane integrale': ShoppingDepartment.panetteria,
  'Pangrattato': ShoppingDepartment.dispensa,
  'Panino': ShoppingDepartment.panetteria,

  // Ortofrutta, con le coppie che si assomigliano.
  'Pomodori ciliegino': ShoppingDepartment.ortofrutta,
  'Melanzane': ShoppingDepartment.ortofrutta,
  'Mele': ShoppingDepartment.ortofrutta,
  'Funghi champignon': ShoppingDepartment.ortofrutta,
  'Insalata mista': ShoppingDepartment.ortofrutta,
  'Lattuga': ShoppingDepartment.ortofrutta,

  // Dispensa.
  'Riso basmati': ShoppingDepartment.dispensa,
  'Olio extravergine di oliva': ShoppingDepartment.dispensa,
  'Olive taggiasche': ShoppingDepartment.dispensa,
  'Passata di pomodoro': ShoppingDepartment.dispensa,
  'Pomodori pelati': ShoppingDepartment.dispensa,
  'Ceci in scatola': ShoppingDepartment.dispensa,
  'Lenticchie secche': ShoppingDepartment.dispensa,
  'Sale fino': ShoppingDepartment.dispensa,
  'Quinoa': ShoppingDepartment.dispensa,

  // Bevande.
  'Acqua': ShoppingDepartment.bevande,
  'Vino bianco': ShoppingDepartment.bevande,

  // Quello che non si riconosce si dichiara, non si indovina.
  'Preparato misterioso': ShoppingDepartment.altro,
  '***': ShoppingDepartment.altro,
};

void main() {
  group('classify', () {
    _cases.forEach((name, expected) {
      test('«$name» → ${expected.label}', () {
        expect(ShoppingDepartments.classify(name), expected);
      });
    });

    test('è insensibile a maiuscole, accenti e punteggiatura', () {
      expect(
        ShoppingDepartments.classify('PETTO DI POLLO'),
        ShoppingDepartment.macelleria,
      );
      expect(
        ShoppingDepartments.classify('petto, di pollo!'),
        ShoppingDepartment.macelleria,
      );
    });

    test('non lancia mai, nemmeno su una stringa vuota', () {
      expect(ShoppingDepartments.classify(''), ShoppingDepartment.altro);
      expect(ShoppingDepartments.classify('   '), ShoppingDepartment.altro);
    });
  });

  group('reparti', () {
    test('l’ordine è quello del giro fra i banchi', () {
      expect(ShoppingDepartment.values.map((value) => value.label), [
        'Ortofrutta',
        'Macelleria',
        'Pescheria',
        'Banco frigo e latticini',
        'Dispensa',
        'Panetteria',
        'Surgelati',
        'Bevande',
        'Altro',
      ]);
    });

    test('le regole a più parole vengono prima di quelle a una', () {
      // Se questa invariante salta, «latte di mandorla» finisce nel frigo.
      final firstSingleToken = ShoppingDepartments.rules.indexWhere(
        (rule) => rule.tokens.length == 1 && rule.tokens.first == 'latte',
      );
      final multiToken = ShoppingDepartments.rules.indexWhere(
        (rule) => rule.tokens.length > 1 && rule.tokens.first == 'latte',
      );
      expect(multiToken, lessThan(firstSingleToken));
    });
  });
}
