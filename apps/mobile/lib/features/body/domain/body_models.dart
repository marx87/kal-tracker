import 'package:flutter/foundation.dart';
import 'package:kal_tracker/core/time/app_time.dart';

/// Il giorno civile romano di un istante, usato come chiave di
/// raggruppamento e come ascissa dei grafici.
///
/// Torna un `DateTime.utc` a mezzanotte: non è un istante, è un'etichetta di
/// giorno. In UTC l'aritmetica sui giorni resta esatta anche a cavallo del
/// cambio d'ora, che su una serie di sei mesi capita sempre.
DateTime bodyDayOf(DateTime instant) {
  final local = AppTime.inRome(instant);
  return DateTime.utc(local.year, local.month, local.day);
}

/// Finestra temporale mostrata dalla schermata.
enum BodyRange {
  month(30, '30 giorni'),
  quarter(90, '3 mesi'),
  semester(180, '6 mesi');

  const BodyRange(this.days, this.label);

  final int days;
  final String label;
}

/// Una pesata come sta nel database: valori grezzi.
///
/// Non esistono qui — e non devono esistere — età metabolica, peso ottimale e
/// tipo di corpo: sono giudizi che la bilancia stampa sul display, non misure.
/// Il modello conserva solo ciò che è stato misurato o dichiarato.
@immutable
class BodyMeasurement {
  const BodyMeasurement({
    required this.id,
    required this.measuredAt,
    required this.weightKg,
    this.hasImpedance = false,
    this.bodyFatPct,
    this.musclePct,
    this.waterPct,
    this.impedanceOhm,
    this.source = 'manual',
    this.note,
    this.circumferences = const {},
  });

  final String id;

  /// Istante in UTC.
  final DateTime measuredAt;

  final double weightKg;
  final bool hasImpedance;
  final double? bodyFatPct;
  final double? musclePct;
  final double? waterPct;
  final double? impedanceOhm;

  /// 'manual', 'renpho_ble', 'gym_tracker', … Serve a dire da dove viene un
  /// dato, non a giudicarlo.
  final String source;

  final String? note;

  /// Circonferenze a nastro di questa pesata, per etichetta ('Vita',
  /// 'Braccio', …). L'insieme è aperto: le etichette le decide chi misura.
  final Map<String, double> circumferences;

  DateTime get day => bodyDayOf(measuredAt);

  /// Una lettura vale come «composizione» solo se porta la percentuale di
  /// grasso: senza quella non si può separare la massa grassa dalla magra, e
  /// tutto il resto (acqua, muscolo) non basta a ricostruirla.
  bool get hasComposition => bodyFatPct != null && bodyFatPct! > 0;

  double? get fatMassKg => hasComposition ? weightKg * bodyFatPct! / 100 : null;

  double? get leanMassKg => hasComposition ? weightKg - fatMassKg! : null;
}

/// Il giorno, non la singola pesata: di più letture dello stesso giorno ne
/// vale **una**, la prima utile.
///
/// Resta il primo dei due filtri contro il rumore della BIA — senza, una
/// giornata con quattro salite peserebbe quattro volte tanto nella media
/// mobile di una con una sola — ma il modo è cambiato: prima si faceva la
/// media di tutte, e quella media non corrispondeva a nessun momento della
/// giornata. Fra la mattina a digiuno e la sera dopo cena c'è cibo e acqua,
/// che è fisiologia vera e non rumore da smussare.
@immutable
class BodyDayPoint {
  const BodyDayPoint({
    required this.day,
    required this.weightKg,
    required this.measuredAt,
    required this.readings,
    required this.compositionReadings,
    this.fatMassKg,
    this.leanMassKg,
    this.waterPct,
  });

  final DateTime day;

  /// Il peso della pesata che vale per questo giorno — **non** una media.
  final double weightKg;

  /// Quando è stata fatta la pesata che vale. Serve a dirlo: «tre pesate, vale
  /// quella delle 8:12» è una frase che si può controllare, «media del giorno»
  /// no.
  final DateTime measuredAt;

  /// Quante pesate ci sono state quel giorno, contate tutte. Le altre non
  /// entrano nelle medie ma esistono, e vanno dette.
  final int readings;

  /// Quante letture del giorno portavano la composizione.
  final int compositionReadings;

  /// Grassa e magra della **stessa** lettura del peso: la loro somma è
  /// esattamente [weightKg], quindi la pila del grafico non può contraddirsi.
  final double? fatMassKg;
  final double? leanMassKg;

  /// L'acqua corporea della stessa lettura.
  ///
  /// Sta qui e non si media più altrove: restando una media del giorno mentre
  /// le masse venivano da una lettura sola, si spostava a seconda di quante
  /// volte uno era salito sulla bilancia — proprio il difetto tolto al peso. E
  /// da lì passano due decisioni vere: la spiegazione dei movimenti falsi e il
  /// semaforo del sovrallenamento.
  final double? waterPct;

  bool get hasComposition => fatMassKg != null && leanMassKg != null;

  double? get compositionWeightKg =>
      hasComposition ? fatMassKg! + leanMassKg! : null;

  double? get bodyFatPct =>
      hasComposition ? fatMassKg! / compositionWeightKg! * 100 : null;
}

/// Un punto della media mobile a 7 giorni: è questo che si legge e si mostra,
/// mai il dato del singolo giorno.
@immutable
class BodyTrendPoint {
  const BodyTrendPoint({
    required this.day,
    required this.weightKg,
    required this.weightDays,
    required this.compositionDays,
    this.fatMassKg,
    this.leanMassKg,
  });

  final DateTime day;
  final double weightKg;

  /// Giorni distinti che hanno contribuito alla media del peso (1..7).
  /// Sotto i 3 la media è ancora un dato quasi grezzo, e la UI lo dice.
  final int weightDays;

  final int compositionDays;
  final double? fatMassKg;
  final double? leanMassKg;

  bool get hasComposition => fatMassKg != null && leanMassKg != null;

  double? get compositionWeightKg =>
      hasComposition ? fatMassKg! + leanMassKg! : null;

  double? get bodyFatPct =>
      hasComposition ? fatMassKg! / compositionWeightKg! * 100 : null;
}

/// Una variazione tra due medie a 7 giorni, con la distanza reale tra loro.
///
/// I giorni non sono mai «7 per definizione»: se manca la pesata giusta si
/// confronta con quella disponibile e lo si dichiara.
@immutable
class BodyChange {
  const BodyChange({required this.deltaKg, required this.spanDays});

  final double deltaKg;
  final int spanDays;

  bool isStable(double toleranceKg) => deltaKg.abs() < toleranceKg;
}

/// Che cosa sta succedendo al corpo, letto sulle due masse insieme.
///
/// È la domanda che giustifica la schermata: il peso da solo non distingue
/// una ricomposizione da un dimagrimento.
enum BodyVerdict {
  /// Grasso giù e magra su: la combinazione che si cerca.
  recomposition('Ricomposizione', 'Massa grassa in calo e magra in crescita.'),

  /// Grasso giù, magra ferma: dimagrimento pulito.
  cleanFatLoss('Grasso in calo', 'Perdi grasso e tieni la massa magra.'),

  /// Scendono entrambe: si dimagrisce, ma non solo di grasso.
  weightLoss('Dimagrimento', 'Scendono sia la massa grassa sia la magra.'),

  /// Salgono entrambe: fase di crescita.
  gain('Crescita', 'Salgono sia la massa magra sia la grassa.'),

  /// Grasso su e magra giù.
  adverse('Grasso in crescita', 'La massa grassa sale e la magra scende.'),

  /// Dentro il rumore: nessuna delle due si muove abbastanza.
  stable('Stabile', 'Le due masse non si muovono oltre il rumore della BIA.'),

  /// Non ci sono due medie con composizione abbastanza distanti.
  unknown(
    'Dati insufficienti',
    'Servono pesate con impedenza distanti almeno qualche giorno.',
  );

  const BodyVerdict(this.label, this.description);

  final String label;
  final String description;

  bool get isKnown => this != BodyVerdict.unknown;
}

/// Quanto ballano i valori della BIA, misurato sui dati veri invece che
/// affermato.
///
/// Si guardano i giorni in cui ci si è pesati più volte: lì il corpo non è
/// cambiato, quindi tutta la differenza è rumore dello strumento. È il numero
/// che autorizza la frase «il valore assoluto è indicativo, il trend no».
@immutable
class BiaSpread {
  const BiaSpread({
    required this.bodyFatPoints,
    required this.fatMassKg,
    required this.dayCount,
  });

  const BiaSpread.unmeasured() : bodyFatPoints = 0, fatMassKg = 0, dayCount = 0;

  /// Scarto mediano, in punti percentuali, tra le letture dello stesso giorno.
  final double bodyFatPoints;

  /// Lo stesso scarto tradotto in kg di massa grassa, che è l'unità in cui poi
  /// si legge il grafico.
  final double fatMassKg;

  /// Su quanti giorni è stato misurato lo scarto.
  final int dayCount;

  bool get isMeasured => dayCount > 0 && bodyFatPoints > 0;
}

/// Andamento di una circonferenza a nastro.
///
/// Il nastro non si media a 7 giorni: si misura ogni tanto, e mediarlo
/// cancellerebbe l'unico dato del periodo. Qui si confronta l'ultima misura
/// con la più vecchia del periodo, dichiarando quanti giorni ci sono in mezzo.
@immutable
class CircumferenceTrend {
  const CircumferenceTrend({required this.label, required this.series});

  final String label;

  /// Le misure del periodo, dalla più vecchia alla più recente.
  final List<(DateTime, double)> series;

  /// Quante misure di questa etichetta ci sono nel periodo.
  int get samples => series.length;

  double get latestCm => series.last.$2;
  DateTime get latestAt => series.last.$1;

  /// Il termine di paragone: la misura più vecchia del periodo, ma solo se
  /// dista almeno una settimana. Due misure ravvicinate differiscono per come
  /// si tiene il metro, non per il corpo.
  (DateTime, double)? get _previous {
    if (series.length < 2) {
      return null;
    }
    final first = series.first;
    final days = bodyDayOf(latestAt).difference(bodyDayOf(first.$1)).inDays;
    return days >= 7 ? first : null;
  }

  double? get previousCm => _previous?.$2;
  DateTime? get previousAt => _previous?.$1;

  double? get deltaCm => previousCm == null ? null : latestCm - previousCm!;

  int? get spanDays => previousAt == null
      ? null
      : bodyDayOf(latestAt).difference(bodyDayOf(previousAt!)).inDays;

  /// Da tre misure in su l'andamento si può disegnare: sotto, due punti sono
  /// una retta e non aggiungono niente al numero già scritto.
  bool get isDrawable => series.length >= 3;
}

/// Tutto quello che serve alla schermata Corpo, già calcolato una volta sola.
@immutable
class BodyInsights {
  const BodyInsights({
    required this.range,
    required this.measurements,
    required this.days,
    required this.trend,
    required this.circumferences,
    required this.spread,
    required this.verdict,
    this.latest,
    this.weightChange,
    this.fatChange,
    this.leanChange,
    this.staleDays,
  });

  const BodyInsights.empty(this.range)
    : measurements = const [],
      days = const [],
      trend = const [],
      circumferences = const [],
      spread = const BiaSpread.unmeasured(),
      verdict = BodyVerdict.unknown,
      latest = null,
      weightChange = null,
      fatChange = null,
      leanChange = null,
      staleDays = null;

  final BodyRange range;

  /// Pesate grezze del periodo, dalla più recente.
  final List<BodyMeasurement> measurements;

  /// Un punto per giorno — la pesata che vale — in ordine cronologico
  /// riscaldamento prima della finestra).
  final List<BodyDayPoint> days;

  /// Medie mobili a 7 giorni dentro la finestra visibile, in ordine
  /// cronologico.
  final List<BodyTrendPoint> trend;

  final List<CircumferenceTrend> circumferences;
  final BiaSpread spread;
  final BodyVerdict verdict;

  /// L'ultima media a 7 giorni: il «dove sono adesso».
  final BodyTrendPoint? latest;

  final BodyChange? weightChange;
  final BodyChange? fatChange;
  final BodyChange? leanChange;

  /// Da quanti giorni non si registra una pesata. Nullo se non ce ne sono.
  final int? staleDays;

  bool get isEmpty => measurements.isEmpty;

  /// Ci sono almeno due punti con composizione: sotto questa soglia il
  /// grafico ad aree non ha niente da mostrare.
  bool get hasCompositionSeries =>
      trend.where((point) => point.hasComposition).length >= 2;

  List<BodyTrendPoint> get compositionTrend =>
      trend.where((point) => point.hasComposition).toList(growable: false);
}
