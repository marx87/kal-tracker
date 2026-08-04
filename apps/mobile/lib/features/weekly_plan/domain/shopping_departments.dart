/// Reparti del supermercato e classificazione DETERMINISTICA degli
/// ingredienti: nessun modello, nessuna rete, solo una tabella di parole
/// chiave in italiano letta dall'alto verso il basso.
///
/// La prima regola che corrisponde vince, quindi l'ordine È la specificità:
/// «piselli surgelati» incontra la regola del freddo prima di quella
/// dell'ortofrutta, «latte di mandorla» incontra la dispensa prima del banco
/// frigo. Le parole chiave si confrontano con [ShoppingText.tokens], cioè con
/// le parole del nome sia come sono scritte sia al singolare, e il confronto è
/// per PREFISSO di parola (così «surgelat» prende surgelati/surgelate).
library;

import 'package:kal_tracker/features/weekly_plan/domain/shopping_text.dart';

/// L'ordine di dichiarazione è l'ordine del giro fra i banchi (ed è anche
/// l'ordine in cui la lista si mostra e si esporta).
enum ShoppingDepartment {
  ortofrutta('Ortofrutta'),
  macelleria('Macelleria'),
  pescheria('Pescheria'),
  bancoFrigo('Banco frigo e latticini'),
  dispensa('Dispensa'),
  panetteria('Panetteria'),
  surgelati('Surgelati'),
  bevande('Bevande'),
  altro('Altro');

  const ShoppingDepartment(this.label);

  /// Etichetta italiana da mostrare in testa al gruppo.
  final String label;
}

abstract final class ShoppingDepartments {
  /// Reparto di un ingrediente. Non lancia mai: quello che non riconosce
  /// finisce in [ShoppingDepartment.altro], che è una risposta onesta.
  static ShoppingDepartment classify(String name) {
    final words = ShoppingText.tokens(name);
    if (words.isEmpty) {
      return ShoppingDepartment.altro;
    }
    for (final rule in _rules) {
      if (rule.matches(words)) {
        return rule.department;
      }
    }
    return ShoppingDepartment.altro;
  }

  /// Le regole nell'ordine in cui vengono provate (esposte per i test).
  static const List<ShoppingRule> rules = _rules;
}

/// Una regola: tutte le [tokens] devono comparire come prefisso di una parola
/// del nome. Più token = regola più specifica, quindi va scritta più in alto.
class ShoppingRule {
  const ShoppingRule(this.department, this.tokens);

  final ShoppingDepartment department;
  final List<String> tokens;

  bool matches(Set<String> words) =>
      tokens.every((token) => words.any((word) => word.startsWith(token)));
}

const List<ShoppingRule> _rules = [
  // 1. Il freddo vince su tutto: «piselli surgelati» non è ortofrutta.
  ShoppingRule(ShoppingDepartment.surgelati, ['surgelat']),
  ShoppingRule(ShoppingDepartment.surgelati, ['congelat']),
  ShoppingRule(ShoppingDepartment.surgelati, ['gelato']),
  ShoppingRule(ShoppingDepartment.surgelati, ['ghiaccio']),

  // 2. Le trappole: sembrano frigo o pescheria, ma stanno sullo scaffale.
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'mandorla']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'soia']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'riso']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'avena']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'cocco']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'nocciola']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'condensat']),
  ShoppingRule(ShoppingDepartment.dispensa, ['latte', 'polvere']),
  ShoppingRule(ShoppingDepartment.dispensa, ['bevanda', 'vegetal']),
  ShoppingRule(ShoppingDepartment.dispensa, ['burro', 'arachide']),
  ShoppingRule(ShoppingDepartment.dispensa, ['burro', 'mandorla']),
  ShoppingRule(ShoppingDepartment.dispensa, ['burro', 'cacao']),
  ShoppingRule(ShoppingDepartment.dispensa, ['tonno', 'scatola']),
  ShoppingRule(ShoppingDepartment.dispensa, ['tonno', 'natural']),
  ShoppingRule(ShoppingDepartment.dispensa, ['tonno', 'sott']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pomodoro', 'pelat']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pomodoro', 'scatola']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pomodoro', 'secc']),
  ShoppingRule(ShoppingDepartment.dispensa, ['passata']),
  // Solo la polpa di pomodoro: «polpa di manzo» è un'altra cosa e un'altra
  // corsia.
  ShoppingRule(ShoppingDepartment.dispensa, ['polpa', 'pomodoro']),
  ShoppingRule(ShoppingDepartment.dispensa, ['concentrato']),
  ShoppingRule(ShoppingDepartment.dispensa, ['sugo']),
  ShoppingRule(ShoppingDepartment.dispensa, ['fagiolo', 'scatola']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cec', 'scatola']),

  // 3. Macelleria e salumi.
  ShoppingRule(ShoppingDepartment.macelleria, ['pollo']),
  ShoppingRule(ShoppingDepartment.macelleria, ['tacchino']),
  ShoppingRule(ShoppingDepartment.macelleria, ['manzo']),
  ShoppingRule(ShoppingDepartment.macelleria, ['vitello']),
  ShoppingRule(ShoppingDepartment.macelleria, ['maiale']),
  ShoppingRule(ShoppingDepartment.macelleria, ['agnello']),
  ShoppingRule(ShoppingDepartment.macelleria, ['coniglio']),
  ShoppingRule(ShoppingDepartment.macelleria, ['carne']),
  ShoppingRule(ShoppingDepartment.macelleria, ['macinat']),
  ShoppingRule(ShoppingDepartment.macelleria, ['hamburger']),
  ShoppingRule(ShoppingDepartment.macelleria, ['bistecca']),
  ShoppingRule(ShoppingDepartment.macelleria, ['tagliata']),
  ShoppingRule(ShoppingDepartment.macelleria, ['petto']),
  ShoppingRule(ShoppingDepartment.macelleria, ['fesa']),
  ShoppingRule(ShoppingDepartment.macelleria, ['cotoletta']),
  ShoppingRule(ShoppingDepartment.macelleria, ['salsiccia']),
  ShoppingRule(ShoppingDepartment.macelleria, ['wurstel']),
  ShoppingRule(ShoppingDepartment.macelleria, ['prosciutto']),
  ShoppingRule(ShoppingDepartment.macelleria, ['bresaola']),
  ShoppingRule(ShoppingDepartment.macelleria, ['speck']),
  ShoppingRule(ShoppingDepartment.macelleria, ['salame']),
  ShoppingRule(ShoppingDepartment.macelleria, ['mortadella']),
  ShoppingRule(ShoppingDepartment.macelleria, ['pancetta']),
  ShoppingRule(ShoppingDepartment.macelleria, ['guanciale']),

  // 4. Pescheria (il pesce in scatola è già finito in dispensa).
  ShoppingRule(ShoppingDepartment.pescheria, ['pesce']),
  ShoppingRule(ShoppingDepartment.pescheria, ['tonno']),
  ShoppingRule(ShoppingDepartment.pescheria, ['salmone']),
  ShoppingRule(ShoppingDepartment.pescheria, ['merluzzo']),
  ShoppingRule(ShoppingDepartment.pescheria, ['nasello']),
  ShoppingRule(ShoppingDepartment.pescheria, ['orata']),
  ShoppingRule(ShoppingDepartment.pescheria, ['branzino']),
  ShoppingRule(ShoppingDepartment.pescheria, ['spigola']),
  ShoppingRule(ShoppingDepartment.pescheria, ['sogliola']),
  ShoppingRule(ShoppingDepartment.pescheria, ['platessa']),
  ShoppingRule(ShoppingDepartment.pescheria, ['trota']),
  ShoppingRule(ShoppingDepartment.pescheria, ['sgombro']),
  ShoppingRule(ShoppingDepartment.pescheria, ['acciuga']),
  ShoppingRule(ShoppingDepartment.pescheria, ['alici']),
  ShoppingRule(ShoppingDepartment.pescheria, ['sarda']),
  ShoppingRule(ShoppingDepartment.pescheria, ['gamber']),
  ShoppingRule(ShoppingDepartment.pescheria, ['scampo']),
  ShoppingRule(ShoppingDepartment.pescheria, ['calamaro']),
  ShoppingRule(ShoppingDepartment.pescheria, ['seppia']),
  ShoppingRule(ShoppingDepartment.pescheria, ['polpo']),
  ShoppingRule(ShoppingDepartment.pescheria, ['cozza']),
  ShoppingRule(ShoppingDepartment.pescheria, ['vongola']),
  ShoppingRule(ShoppingDepartment.pescheria, ['granchio']),
  ShoppingRule(ShoppingDepartment.pescheria, ['baccala']),
  ShoppingRule(ShoppingDepartment.pescheria, ['surimi']),

  // 5. Banco frigo e latticini (le uova stanno qui: si prendono insieme).
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['latte']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['yogurt']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['yoghurt']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['skyr']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['kefir']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['ricotta']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['mozzarella']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['burrata']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['parmigiano']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['grana']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['pecorino']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['formaggio']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['stracchino']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['crescenza']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['robiola']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['scamorza']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['provola']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['gorgonzola']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['emmental']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['cheddar']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['feta']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['quark']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['fiocchi', 'latte']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['burro']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['panna']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['mascarpone']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['uovo']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['albume']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['tofu']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['seitan']),
  ShoppingRule(ShoppingDepartment.bancoFrigo, ['tempeh']),

  // 6. Panetteria.
  ShoppingRule(ShoppingDepartment.panetteria, ['pane']),
  ShoppingRule(ShoppingDepartment.panetteria, ['panin']),
  ShoppingRule(ShoppingDepartment.panetteria, ['piadina']),
  ShoppingRule(ShoppingDepartment.panetteria, ['focaccia']),
  ShoppingRule(ShoppingDepartment.panetteria, ['baguette']),
  ShoppingRule(ShoppingDepartment.panetteria, ['ciabatta']),
  ShoppingRule(ShoppingDepartment.panetteria, ['grissino']),
  ShoppingRule(ShoppingDepartment.panetteria, ['brioche']),
  ShoppingRule(ShoppingDepartment.panetteria, ['cornetto']),

  // 7. Bevande.
  ShoppingRule(ShoppingDepartment.bevande, ['acqua']),
  ShoppingRule(ShoppingDepartment.bevande, ['vino']),
  ShoppingRule(ShoppingDepartment.bevande, ['birra']),
  ShoppingRule(ShoppingDepartment.bevande, ['succo']),
  ShoppingRule(ShoppingDepartment.bevande, ['spremuta']),
  ShoppingRule(ShoppingDepartment.bevande, ['bibita']),
  ShoppingRule(ShoppingDepartment.bevande, ['aranciata']),
  ShoppingRule(ShoppingDepartment.bevande, ['limonata']),
  ShoppingRule(ShoppingDepartment.bevande, ['prosecco']),
  ShoppingRule(ShoppingDepartment.bevande, ['spumante']),

  // 8. Ortofrutta.
  ShoppingRule(ShoppingDepartment.ortofrutta, ['pomodoro']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['insalata']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['lattuga']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['rucola']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['spinacio']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['radicchio']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['valeriana']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['zucchina']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['melanzana']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['peperone']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['cipolla']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['aglio']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['carota']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['patata']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['sedano']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['finocchio']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['broccolo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['cavolfiore']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['cavolo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['verza']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['zucca']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['cetriolo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['fungo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['champignon']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['porro']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['scalogno']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['asparago']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['carciofo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['fagiolino']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['pisello']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['bietola']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['barbabietola']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['ravanello']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['prezzemolo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['basilico']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['rosmarino']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['salvia']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['menta']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['zenzero']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['limone']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['arancia']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['mandarino']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['clementina']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['pompelmo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['mela']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['pera']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['banana']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['fragola']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['mirtillo']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['lampone']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['kiwi']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['ananas']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['mango']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['avocado']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['uva']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['pesca']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['albicocca']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['prugna']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['susina']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['melone']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['anguria']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['ciliegia']),
  ShoppingRule(ShoppingDepartment.ortofrutta, ['fico']),

  // 9. Dispensa: lo scaffale lungo, provato per ultimo.
  ShoppingRule(ShoppingDepartment.dispensa, ['riso']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pasta']),
  ShoppingRule(ShoppingDepartment.dispensa, ['spaghetto']),
  ShoppingRule(ShoppingDepartment.dispensa, ['penna']),
  ShoppingRule(ShoppingDepartment.dispensa, ['fusillo']),
  ShoppingRule(ShoppingDepartment.dispensa, ['farfalla']),
  ShoppingRule(ShoppingDepartment.dispensa, ['rigatone']),
  ShoppingRule(ShoppingDepartment.dispensa, ['lasagna']),
  ShoppingRule(ShoppingDepartment.dispensa, ['couscous']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cuscus']),
  ShoppingRule(ShoppingDepartment.dispensa, ['quinoa']),
  ShoppingRule(ShoppingDepartment.dispensa, ['orzo']),
  ShoppingRule(ShoppingDepartment.dispensa, ['farro']),
  ShoppingRule(ShoppingDepartment.dispensa, ['avena']),
  ShoppingRule(ShoppingDepartment.dispensa, ['muesli']),
  ShoppingRule(ShoppingDepartment.dispensa, ['granola']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cereal']),
  ShoppingRule(ShoppingDepartment.dispensa, ['fiocchi']),
  ShoppingRule(ShoppingDepartment.dispensa, ['farina']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pangrattato']),
  ShoppingRule(ShoppingDepartment.dispensa, ['galletta']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cracker']),
  ShoppingRule(ShoppingDepartment.dispensa, ['biscott']),
  ShoppingRule(ShoppingDepartment.dispensa, ['zucchero']),
  ShoppingRule(ShoppingDepartment.dispensa, ['sale']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pepe']),
  ShoppingRule(ShoppingDepartment.dispensa, ['origano']),
  ShoppingRule(ShoppingDepartment.dispensa, ['curcuma']),
  ShoppingRule(ShoppingDepartment.dispensa, ['curry']),
  ShoppingRule(ShoppingDepartment.dispensa, ['paprika']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cannella']),
  ShoppingRule(ShoppingDepartment.dispensa, ['spezia']),
  ShoppingRule(ShoppingDepartment.dispensa, ['olio']),
  ShoppingRule(ShoppingDepartment.dispensa, ['aceto']),
  ShoppingRule(ShoppingDepartment.dispensa, ['oliva']),
  ShoppingRule(ShoppingDepartment.dispensa, ['passata']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pelat']),
  ShoppingRule(ShoppingDepartment.dispensa, ['concentrato']),
  ShoppingRule(ShoppingDepartment.dispensa, ['dado']),
  ShoppingRule(ShoppingDepartment.dispensa, ['brodo']),
  ShoppingRule(ShoppingDepartment.dispensa, ['salsa']),
  ShoppingRule(ShoppingDepartment.dispensa, ['maionese']),
  ShoppingRule(ShoppingDepartment.dispensa, ['senape']),
  ShoppingRule(ShoppingDepartment.dispensa, ['legume']),
  ShoppingRule(ShoppingDepartment.dispensa, ['fagiolo']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cec']),
  ShoppingRule(ShoppingDepartment.dispensa, ['lenticchia']),
  ShoppingRule(ShoppingDepartment.dispensa, ['mais']),
  ShoppingRule(ShoppingDepartment.dispensa, ['mandorla']),
  ShoppingRule(ShoppingDepartment.dispensa, ['nocciola']),
  ShoppingRule(ShoppingDepartment.dispensa, ['noce']),
  ShoppingRule(ShoppingDepartment.dispensa, ['pistacchio']),
  ShoppingRule(ShoppingDepartment.dispensa, ['arachide']),
  ShoppingRule(ShoppingDepartment.dispensa, ['anacardo']),
  ShoppingRule(ShoppingDepartment.dispensa, ['uvetta']),
  ShoppingRule(ShoppingDepartment.dispensa, ['dattero']),
  ShoppingRule(ShoppingDepartment.dispensa, ['miele']),
  ShoppingRule(ShoppingDepartment.dispensa, ['marmellata']),
  ShoppingRule(ShoppingDepartment.dispensa, ['confettura']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cacao']),
  ShoppingRule(ShoppingDepartment.dispensa, ['cioccolat']),
  ShoppingRule(ShoppingDepartment.dispensa, ['caffe']),
  ShoppingRule(ShoppingDepartment.dispensa, ['tisana']),
  ShoppingRule(ShoppingDepartment.dispensa, ['camomilla']),
  ShoppingRule(ShoppingDepartment.dispensa, ['lievito']),
  ShoppingRule(ShoppingDepartment.dispensa, ['proteine']),
  ShoppingRule(ShoppingDepartment.dispensa, ['semi']),
];
