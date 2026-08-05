import 'package:kal_tracker/features/goal/domain/body_composition.dart';

/// Come si vuole essere, detto a parole.
///
/// L'obiettivo non si sceglie mai in percentuale di grasso: si sceglie
/// «asciutto» o «definito». La percentuale esiste solo qui dentro, come
/// parametro della formula, e non deve comparire in nessuna schermata.
///
/// I riferimenti sono per uomo adulto (fonte: `docs/ROADMAP.md`, M7.1a).
enum DefinitionLevel {
  soft(bodyFatPct: 24, label: 'Morbido'),
  normal(bodyFatPct: 20, label: 'Normale'),
  lean(bodyFatPct: 17, label: 'Asciutto'),
  athletic(bodyFatPct: 14, label: 'Atletico'),
  defined(bodyFatPct: 11, label: 'Definito'),
  veryDefined(bodyFatPct: 9, label: 'Molto definito');

  const DefinitionLevel({required this.bodyFatPct, required this.label});

  /// Il parametro della curva. Resta interno: la UI mostra [label].
  final double bodyFatPct;

  /// L'etichetta italiana, quella che l'utente legge e sceglie.
  final String label;

  /// Come si legge in una frase: «arrivare a 80,5 kg **definito**».
  String get inlineLabel => label.toLowerCase();

  /// Una riga che spiega cosa vuol dire, senza numeri.
  String get description => switch (this) {
    DefinitionLevel.soft => 'Forme piene, addome coperto.',
    DefinitionLevel.normal => 'Corporatura media, nessun rilievo marcato.',
    DefinitionLevel.lean => 'Vita più asciutta, spalle che si distinguono.',
    DefinitionLevel.athletic => 'Addome accennato, braccia disegnate.',
    DefinitionLevel.defined => 'Addome visibile, vene sugli avambracci.',
    DefinitionLevel.veryDefined =>
      'Definizione da gara: difficile da mantenere a lungo.',
  };

  /// Il più morbido della scala: l'estremo «alto» della manopola.
  static DefinitionLevel get softest => DefinitionLevel.soft;

  /// Il più asciutto: l'estremo «basso», oltre il quale l'app non accompagna
  /// più nessuno senza dire che si sta uscendo dalla scala.
  static DefinitionLevel get leanest => DefinitionLevel.veryDefined;

  static DefinitionLevel? fromStorage(String? value) {
    if (value == null) {
      return null;
    }
    for (final level in DefinitionLevel.values) {
      if (level.name == value) {
        return level;
      }
    }
    return null;
  }
}

/// Dove cade un peso rispetto alla scala delle definizioni.
enum ScalePosition {
  /// Più asciutto del livello più magro: si scenderebbe sotto la scala.
  leanerThanScale,

  /// Dentro la scala: la coppia peso + definizione è descrivibile a parole.
  onScale,

  /// Più morbido del livello più alto.
  softerThanScale,
}

/// Un punto della curva: un peso e la parola che lo descrive.
class CurvePoint {
  const CurvePoint({required this.level, required this.weightKg});

  final DefinitionLevel level;
  final double weightKg;
}

/// Come leggere un peso qualunque sulla scala, a massa magra data.
class DefinitionReading {
  const DefinitionReading({
    required this.level,
    required this.bodyFatPct,
    required this.position,
  });

  /// Il livello che descrive meglio quel peso.
  final DefinitionLevel level;

  /// La percentuale implicita. Serve ai calcoli, non alla UI.
  final double bodyFatPct;

  final ScalePosition position;

  bool get isOnScale => position == ScalePosition.onScale;
}

/// **La manopola.**
///
/// A massa magra invariata peso e definizione non sono due scelte
/// indipendenti: fissata la massa magra, ogni definizione ha un solo peso
/// possibile e viceversa. Questa classe è quell'unica equazione, esposta nei
/// due versi.
///
/// Con i 71,66 kg di massa magra di Marco la curva è ≈ 94,3 morbido,
/// 89,6 normale, 86,3 asciutto, 83,3 atletico, 80,5 definito,
/// 78,7 molto definito.
abstract final class DefinitionCurve {
  /// Il peso che corrisponde a quella definizione, senza toccare il muscolo.
  static double weightFor({
    required DefinitionLevel level,
    required double fatFreeMassKg,
  }) => BodyComposition.weightAtBodyFat(
    fatFreeMassKg: fatFreeMassKg,
    bodyFatPct: level.bodyFatPct,
  );

  /// Tutta la curva, dal più morbido al più asciutto. È quello che la
  /// manopola percorre.
  static List<CurvePoint> points(double fatFreeMassKg) => [
    for (final level in DefinitionLevel.values)
      CurvePoint(
        level: level,
        weightKg: weightFor(level: level, fatFreeMassKg: fatFreeMassKg),
      ),
  ];

  /// Il peso più basso della scala (livello più asciutto).
  static double leanestWeight(double fatFreeMassKg) =>
      weightFor(level: DefinitionLevel.leanest, fatFreeMassKg: fatFreeMassKg);

  /// Il peso più alto della scala (livello più morbido).
  static double softestWeight(double fatFreeMassKg) =>
      weightFor(level: DefinitionLevel.softest, fatFreeMassKg: fatFreeMassKg);

  /// Che cosa significa quel peso, per quel corpo.
  ///
  /// Fuori dalla scala il livello restituito è l'estremo più vicino, ma
  /// [DefinitionReading.position] lo dichiara: chiamare «molto definito» un
  /// peso che richiederebbe di smontare 5 kg di muscolo sarebbe una bugia
  /// detta con una parola gentile.
  static DefinitionReading read({
    required double weightKg,
    required double fatFreeMassKg,
  }) {
    final pct = BodyComposition.bodyFatPct(
      weightKg: weightKg,
      fatFreeMassKg: fatFreeMassKg,
    );
    if (pct < DefinitionLevel.leanest.bodyFatPct) {
      return DefinitionReading(
        level: DefinitionLevel.leanest,
        bodyFatPct: pct,
        position: ScalePosition.leanerThanScale,
      );
    }
    if (pct > DefinitionLevel.softest.bodyFatPct) {
      return DefinitionReading(
        level: DefinitionLevel.softest,
        bodyFatPct: pct,
        position: ScalePosition.softerThanScale,
      );
    }

    var nearest = DefinitionLevel.values.first;
    var distance = (nearest.bodyFatPct - pct).abs();
    for (final level in DefinitionLevel.values.skip(1)) {
      final candidate = (level.bodyFatPct - pct).abs();
      if (candidate < distance) {
        nearest = level;
        distance = candidate;
      }
    }
    return DefinitionReading(
      level: nearest,
      bodyFatPct: pct,
      position: ScalePosition.onScale,
    );
  }

  /// L'escursione della manopola: la scala, allargata di [marginKg] su
  /// entrambi i lati.
  ///
  /// Il margine serve perché si deve **poter** chiedere l'impossibile: è
  /// trascinando sotto la scala che compare il verdetto «così perderesti
  /// muscolo», ed è il caso d'uso principale del coach che sa dire di no.
  static ({double minKg, double maxKg}) dialRange(
    double fatFreeMassKg, {
    double marginKg = 6,
  }) {
    // Sotto la massa magra il peso non esiste: significherebbe zero grasso.
    // Il fondo scala si ferma un chilo sopra, così la manopola può arrivare
    // all'assurdo ma non all'impossibile aritmetico.
    final floor = fatFreeMassKg + 1;
    final candidate = leanestWeight(fatFreeMassKg) - marginKg;
    return (
      minKg: candidate > floor ? candidate : floor,
      maxKg: softestWeight(fatFreeMassKg) + marginKg,
    );
  }
}
