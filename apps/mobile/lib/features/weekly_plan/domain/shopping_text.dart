/// Normalizzazione dei nomi degli ingredienti per la lista della spesa.
///
/// Due ricette che scrivono lo stesso alimento in modo diverso («Pomodori»,
/// «pomodoro», «Pomodorì») devono finire sulla STESSA riga della spesa: la
/// chiave la decide qui [ShoppingText.ingredientKey], che è anche l'id stabile
/// usato per ricordare le spunte.
///
/// Scelta di fondo: **prudenza**. Unire due alimenti diversi è un errore che si
/// vede (compri metà della roba), non unirne due uguali è solo una riga in più.
/// Per questo i plurali femminili passano da una tabella esplicita e NON da una
/// regola generica `-e → -a`: quella regola unirebbe «pesce» e «pesca».
library;

abstract final class ShoppingText {
  /// Lettere accentate e loro versione piatta, in coppia posizionale con
  /// [_plain]: la lista della spesa non deve inciampare su «però»/«pero».
  static const String _accented = 'àáâãäèéêëìíîïòóôõöùúûüçñ';
  static const String _plain = 'aaaaaeeeeiiiiooooouuuucn';

  static final RegExp _keepable = RegExp('[a-z0-9]');
  static final RegExp _spaces = RegExp(r'\s+');

  /// Parole di servizio: spariscono dalla chiave così che «olio di oliva» e
  /// «olio d'oliva» siano la stessa voce.
  static const Set<String> _stopWords = {
    'a',
    'agli',
    'ai',
    'al',
    'alla',
    'alle',
    'allo',
    'con',
    'd',
    'da',
    'dal',
    'dalla',
    'dallo',
    'degli',
    'dei',
    'del',
    'della',
    'delle',
    'dello',
    'di',
    'e',
    'ed',
    'gli',
    'i',
    'il',
    'in',
    'la',
    'le',
    'lo',
    'nel',
    'nella',
    'o',
    'per',
    'su',
    'sul',
    'sulla',
    'un',
    'una',
    'uno',
  };

  /// Parole che finiscono in -i ma sono già singolari: la regola generica le
  /// storpierebbe («kiwi» → «kiwo»).
  static const Set<String> _invariable = {
    'basmati',
    'chili',
    'kiwi',
    'muesli',
    'nori',
    'sushi',
    'tahini',
    'thai',
    'wasabi',
  };

  /// Plurali (e varianti di genere) che le regole generiche non prendono.
  /// Sono tutti casi visti davvero in un ricettario italiano.
  static const Map<String, String> _singulars = {
    'albicocche': 'albicocca',
    'arachidi': 'arachide',
    'arance': 'arancia',
    'asparagi': 'asparago',
    'banane': 'banana',
    'barbabietole': 'barbabietola',
    'bietole': 'bietola',
    'carote': 'carota',
    'castagne': 'castagna',
    'ceci': 'cece',
    'ciliegie': 'ciliegia',
    'cipolle': 'cipolla',
    'confezioni': 'confezione',
    'cozze': 'cozza',
    'cucchiai': 'cucchiaio',
    'erbe': 'erba',
    'farfalle': 'farfalla',
    'fave': 'fava',
    'fette': 'fetta',
    'foglie': 'foglia',
    'formaggi': 'formaggio',
    'fragole': 'fragola',
    'gallette': 'galletta',
    'gocce': 'goccia',
    'insalate': 'insalata',
    'lamponi': 'lampone',
    'lasagne': 'lasagna',
    'lattughe': 'lattuga',
    'lenticchie': 'lenticchia',
    'limoni': 'limone',
    'mandorle': 'mandorla',
    'mele': 'mela',
    'melanzane': 'melanzana',
    'meloni': 'melone',
    'more': 'mora',
    'nocciole': 'nocciola',
    'noci': 'noce',
    'oli': 'olio',
    'olii': 'olio',
    'olive': 'oliva',
    'patate': 'patata',
    'penne': 'penna',
    'peperoni': 'peperone',
    'pere': 'pera',
    'pesci': 'pesce',
    'prugne': 'prugna',
    'rape': 'rapa',
    'rigatoni': 'rigatone',
    'salmoni': 'salmone',
    'salsicce': 'salsiccia',
    'salse': 'salsa',
    'sarde': 'sarda',
    'scatole': 'scatola',
    'spezie': 'spezia',
    'susine': 'susina',
    'uova': 'uovo',
    'uve': 'uva',
    'verdure': 'verdura',
    'vongole': 'vongola',
    'zucchina': 'zucchina',
    'zucchine': 'zucchina',
    'zucchini': 'zucchina',
    'zucchino': 'zucchina',
  };

  /// Minuscolo, senza accenti, senza punteggiatura, spazi compattati.
  static String normalize(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      final character = String.fromCharCode(rune);
      final accent = _accented.indexOf(character);
      final plain = accent >= 0 ? _plain[accent] : character;
      buffer.write(_keepable.hasMatch(plain) ? plain : ' ');
    }
    return buffer.toString().replaceAll(_spaces, ' ').trim();
  }

  /// Singolare «banale»: tabella esplicita, poi le uniche regole che in
  /// italiano non fanno danni (-chi/-ghi/-che/-ghe e il maschile -i → -o).
  static String singular(String word) {
    final known = _singulars[word];
    if (known != null) {
      return known;
    }
    if (word.length < 4 || _invariable.contains(word)) {
      return word;
    }
    for (final (suffix, replacement) in const [
      ('chi', 'co'),
      ('ghi', 'go'),
      ('che', 'ca'),
      ('ghe', 'ga'),
    ]) {
      if (word.endsWith(suffix)) {
        return '${word.substring(0, word.length - suffix.length)}$replacement';
      }
    }
    if (word.endsWith('i')) {
      return '${word.substring(0, word.length - 1)}o';
    }
    return word;
  }

  /// Chiave di aggregazione: è l'identità della voce di spesa.
  static String ingredientKey(String value) {
    final normalized = normalize(value);
    if (normalized.isEmpty) {
      return '';
    }
    final words = [
      for (final word in normalized.split(' '))
        if (word.isNotEmpty && !_stopWords.contains(word)) singular(word),
    ];
    return words.isEmpty ? normalized : words.join(' ');
  }

  /// Parole utili alla classificazione per reparto: sia la forma scritta sia
  /// il singolare, così una regola prende «piselli», «pisello» e «piselli».
  static Set<String> tokens(String value) {
    final result = <String>{};
    for (final word in normalize(value).split(' ')) {
      if (word.isEmpty) {
        continue;
      }
      result
        ..add(word)
        ..add(singular(word));
    }
    return result;
  }
}
