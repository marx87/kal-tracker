import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';

/// Una pesata a un'ora romana comoda (le 8 del mattino), così i test
/// ragionano in giorni di calendario come la schermata.
BodyMeasurement measurement({
  required DateTime day,
  required double weightKg,
  double? bodyFatPct,
  int hour = 8,
  int minute = 0,
  String? id,
  Map<String, double> circumferences = const {},
}) {
  final at = AppTime.fromRomeLocal(
    DateTime(day.year, day.month, day.day, hour, minute),
  );
  return BodyMeasurement(
    id: id ?? 'm-${at.toIso8601String()}-$weightKg',
    measuredAt: at,
    weightKg: weightKg,
    hasImpedance: bodyFatPct != null,
    bodyFatPct: bodyFatPct,
    circumferences: circumferences,
  );
}

void main() {
  setUp(AppTime.initialize);

  final today = DateTime(2026, 8, 5);

  group('la pesata del giorno', () {
    test('di più pesate vale la prima, non la loro media', () {
      // **La media era il difetto.** Fra la mattina a digiuno e la sera dopo
      // cena c'è cibo e acqua: un chilo e mezzo vero, non rumore. Mediandoli
      // usciva un numero che non corrispondeva a nessun momento della
      // giornata, e che si spostava a seconda di quante volte Marco fosse
      // salito sulla bilancia — così un giorno con la sola pesata del mattino
      // e uno con mattina e sera finivano nella stessa media mobile come se
      // fossero misure della stessa cosa.
      final mattina = measurement(
        day: DateTime(2026, 8, 1),
        weightKg: 94.0,
        hour: 7,
      );
      final points = BodyAnalysis.collapseDays([
        measurement(day: DateTime(2026, 8, 1), weightKg: 95.0, hour: 20),
        mattina,
        measurement(day: DateTime(2026, 8, 2), weightKg: 96.0),
      ]);

      expect(points, hasLength(2));
      // Quella del mattino, anche se era arrivata in fondo alla lista.
      expect(points.first.weightKg, closeTo(94, 0.001));
      expect(points.first.measuredAt, mattina.measuredAt);
      // Quella delle 20 non entra nemmeno nel conteggio del giorno: è
      // un'altra condizione, e resta nello storico.
      expect(points.first.readings, 1);
      expect(points.last.weightKg, closeTo(96, 0.001));
    });

    test('vale la prima CON impedenza, non la primissima', () {
      // Una pesata col contatto riuscito dice tutto quello che dice una senza,
      // più la composizione: a parità di mattina è quella che vale. Succede
      // davvero — si sale con le calze, non legge, si riprova scalzi.
      final conImpedenza = measurement(
        day: DateTime(2026, 8, 1),
        weightKg: 94.2,
        bodyFatPct: 25,
        hour: 7,
        minute: 30,
      );
      final points = BodyAnalysis.collapseDays([
        measurement(day: DateTime(2026, 8, 1), weightKg: 94.0, hour: 7),
        conImpedenza,
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 96.0,
          bodyFatPct: 26,
          hour: 20,
        ),
      ]);

      final point = points.single;
      expect(point.weightKg, closeTo(94.2, 0.001));
      expect(point.measuredAt, conImpedenza.measuredAt);
      // Le due del mattino; quella delle 20 è fuori dalle medie.
      expect(point.readings, 2);
      expect(point.compositionReadings, 1);
    });

    test('l’impedenza della sera NON batte il peso del mattino', () async {
      // **Il difetto che questo test fissa.** «Vale la prima con impedenza»
      // era scritto senza limite d'orario: al mattino il contatto salta (piedi
      // asciutti, capita), la sera riesce, e il giorno prendeva il peso dopo
      // cena pieno — cioè il chilo e mezzo di cibo e acqua che questa regola
      // esiste per togliere. In quel caso era PEGGIO della vecchia media, che
      // almeno dimezzava l'errore.
      final mattina = measurement(
        day: DateTime(2026, 8, 1),
        weightKg: 94.0,
        hour: 7,
      );
      final points = BodyAnalysis.collapseDays([
        mattina,
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 95.4,
          bodyFatPct: 25,
          hour: 22,
        ),
      ]);

      final point = points.single;
      expect(point.weightKg, closeTo(94, 0.001));
      expect(point.measuredAt, mattina.measuredAt);
      // E il giorno resta senza composizione: prenderla dalla sera e il peso
      // dal mattino rimetterebbe nel grafico la contraddizione che si era
      // appena tolta — grassa + magra diverse dal peso mostrato.
      expect(point.hasComposition, isFalse);
      // La lettura con impedenza era delle 22: fuori dalla finestra del
      // mattino, quindi non si conta nemmeno fra quelle del giorno.
      expect(point.compositionReadings, 0);
    });

    test('se nessuna ha l’impedenza vale comunque la prima', () {
      // Un giorno di sole pesate senza contatto non diventa un buco: il peso
      // vale lo stesso, ed è il dato che muove il traguardo.
      final points = BodyAnalysis.collapseDays([
        measurement(day: DateTime(2026, 8, 1), weightKg: 94.0, hour: 7),
        measurement(day: DateTime(2026, 8, 1), weightKg: 95.0, hour: 20),
      ]);

      expect(points.single.weightKg, closeTo(94, 0.001));
      expect(points.single.hasComposition, isFalse);
    });

    test('un giorno pesato solo la sera non entra nelle medie', () {
      // **Regola invertita, e la ragione sta nei numeri.** Prima si teneva
      // anche il giorno pesato solo la sera, per non lasciare un buco nella
      // serie. Ma un punto preso dopo cena si infila fra gli altri fingendo di
      // essere confrontabile: nei dati veri fra le 09:03 e le 10:22 dello
      // stesso giorno ci sono già 0,7 kg, e nel pomeriggio la distanza cresce.
      //
      // Il buco è il male minore: la media mobile dichiara su quanti giorni è
      // calcolata, e la schermata dice quanti giorni sono rimasti fuori. Una
      // media inquinata non dichiara niente.
      final points = BodyAnalysis.collapseDays([
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 96.0,
          bodyFatPct: 26,
          hour: 21,
        ),
      ]);

      expect(points, isEmpty);
    });

    test('la schermata dice quanti giorni sono rimasti fuori', () {
      // Escludere un dato senza dichiararlo fa sembrare l'app rotta: la pesata
      // c'è, nel grafico non si vede, e nessuno spiega perché.
      final insights = BodyAnalysis.build(
        measurements: [
          measurement(day: DateTime(2026, 8, 1), weightKg: 95, hour: 7),
          measurement(day: DateTime(2026, 8, 2), weightKg: 96, hour: 19),
          measurement(day: DateTime(2026, 8, 3), weightKg: 95, hour: 21),
        ],
        range: BodyRange.month,
        now: DateTime(2026, 8, 3, 22),
      );

      expect(insights.afternoonOnlyDays, 2);
    });

    test('la pesata di mezzanotte resta nel giorno romano, non in quello '
        'UTC', () {
      // Le 00:30 di Roma sono le 22:30 del giorno prima in UTC: leggerla
      // come UTC sposterebbe la pesata al giorno sbagliato.
      final points = BodyAnalysis.collapseDays([
        measurement(
          day: DateTime(2026, 8, 2),
          weightKg: 94,
          hour: 0,
          minute: 30,
        ),
      ]);

      expect(points.single.day, DateTime.utc(2026, 8, 2));
    });

    test('grassa e magra vengono dalla stessa lettura del peso', () {
      // Prima le tre grandezze potevano venire da letture diverse: il peso era
      // la media del giorno, grassa e magra la media delle sole letture con
      // impedenza. La somma delle due non faceva il peso mostrato, e il
      // grafico ad aree impilate conteneva una contraddizione che nessuno
      // poteva spiegare guardandolo.
      final points = BodyAnalysis.collapseDays([
        // Senza impedenza: c'è, si conta, ma non è lei a valere.
        measurement(day: DateTime(2026, 8, 1), weightKg: 90, hour: 7),
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 100,
          bodyFatPct: 20,
          hour: 8,
        ),
      ]);

      final point = points.single;
      expect(point.weightKg, closeTo(100, 0.001));
      expect(point.readings, 2);
      expect(point.compositionReadings, 1);
      expect(point.fatMassKg, closeTo(20, 0.001));
      expect(point.leanMassKg, closeTo(80, 0.001));
      // 20 + 80 = 100, ed è esattamente il peso del punto. Niente scarto da
      // spiegare.
      expect(point.compositionWeightKg, closeTo(point.weightKg, 0.001));
    });
  });

  group('media mobile a 7 giorni', () {
    test('la finestra è di calendario e un giorno vale un voto, anche se ci '
        'si è pesati quattro volte', () {
      final days = BodyAnalysis.collapseDays([
        for (var index = 0; index < 4; index++)
          measurement(
            day: DateTime(2026, 8, 1),
            weightKg: 100,
            hour: 7 + index,
            id: 'primo-$index',
          ),
        measurement(day: DateTime(2026, 8, 2), weightKg: 90),
      ]);
      final smoothed = BodyAnalysis.smooth(days);

      // Se le letture pesassero una a una, la media sarebbe 98: le quattro
      // salite del primo giorno schiaccerebbero il secondo.
      expect(smoothed.last.weightKg, closeTo(95, 0.001));
      expect(smoothed.last.weightDays, 2);
    });

    test('dopo una pausa più lunga della finestra la media riparte, non '
        'finge continuità', () {
      final days = BodyAnalysis.collapseDays([
        measurement(day: DateTime(2026, 7, 1), weightKg: 100),
        measurement(day: DateTime(2026, 7, 20), weightKg: 90),
      ]);
      final smoothed = BodyAnalysis.smooth(days);

      expect(smoothed.last.weightKg, closeTo(90, 0.001));
      expect(smoothed.last.weightDays, 1);
    });

    test('la media mobile smorza il rumore della BIA', () {
      // Grasso che oscilla di ±1 punto attorno al 20% a peso fermo.
      final noisy = [
        for (var index = 0; index < 7; index++)
          measurement(
            day: DateTime(2026, 8, 1).add(Duration(days: index)),
            weightKg: 100,
            bodyFatPct: index.isEven ? 21 : 19,
          ),
      ];
      final smoothed = BodyAnalysis.smooth(BodyAnalysis.collapseDays(noisy));

      // L'ultimo giorno grezzo direbbe 21 kg di grasso; la media a 7 giorni
      // dice 20,1 e non si fa trascinare.
      expect(smoothed.last.fatMassKg, closeTo(20.14, 0.01));
      expect(smoothed.last.compositionDays, 7);
    });

    test('una lettura col contatto fallito non sposta la settimana', () {
      // Il caso vero dell'export del 6 agosto: 15,7 % di grasso e 81,3 kg di
      // massa magra, contro 25,4 % e 71,9 kg di due minuti dopo. Un contatto
      // saltato, o un'altra persona salita sul profilo.
      //
      // Da sola quella riga spostava la media settimanale della massa magra di
      // oltre un chilo — e da lì passano basale, proteine e deficit, cioè una
      // settimana intera di piano costruita su un numero sbagliato.
      final giorni = <BodyMeasurement>[
        for (var index = 0; index < 7; index++)
          measurement(
            day: DateTime(2026, 8, 1).add(Duration(days: index)),
            weightKg: 96,
            // 25 % di grasso su 96 kg: 24 grassa, 72 magra.
            bodyFatPct: index == 3 ? 15.7 : 25,
            hour: 7,
          ),
      ];
      final smoothed = BodyAnalysis.smooth(BodyAnalysis.collapseDays(giorni));
      final ultimo = smoothed.last;

      // Senza difesa la magra media sarebbe 73,3; con lo scarto resta 72.
      expect(ultimo.leanMassKg, closeTo(72, 0.05));
      // E il giorno buttato si vede nel conteggio: sei giorni su sette.
      expect(ultimo.compositionDays, 6);
    });
  });

  group('variazioni', () {
    test('confronta con la media di una settimana prima e dichiara la '
        'distanza reale', () {
      final measurements = [
        for (var index = 0; index < 21; index++)
          measurement(
            day: DateTime(2026, 7, 16).add(Duration(days: index)),
            // Cala di 100 g al giorno.
            weightKg: 100 - index * 0.1,
          ),
      ];
      final insights = BodyAnalysis.build(
        measurements: measurements,
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange, isNotNull);
      expect(insights.weightChange!.spanDays, 7);
      expect(insights.weightChange!.deltaKg, closeTo(-0.7, 0.001));
    });

    test('con una sola pesata non si inventa nessun confronto', () {
      final insights = BodyAnalysis.build(
        measurements: [measurement(day: DateTime(2026, 8, 4), weightKg: 94)],
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange, isNull);
      expect(insights.fatChange, isNull);
      expect(insights.verdict, BodyVerdict.unknown);
    });

    test('due pesate troppo vicine non bastano: le finestre si '
        'sovrappongono quasi tutte', () {
      final insights = BodyAnalysis.build(
        measurements: [
          measurement(day: DateTime(2026, 8, 3), weightKg: 95),
          measurement(day: DateTime(2026, 8, 5), weightKg: 94),
        ],
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange, isNull);
    });
  });

  group('verdetto', () {
    BodyVerdict verdictFor(double fat, double lean) => BodyAnalysis.verdictOf(
      fatChange: BodyChange(deltaKg: fat, spanDays: 7),
      leanChange: BodyChange(deltaKg: lean, spanDays: 7),
    );

    test('grasso giù e magra su è ricomposizione', () {
      expect(verdictFor(-1.2, 0.8), BodyVerdict.recomposition);
    });

    test('grasso giù e magra ferma è dimagrimento pulito', () {
      expect(verdictFor(-1.2, 0.1), BodyVerdict.cleanFatLoss);
    });

    test('giù entrambe è dimagrimento e basta', () {
      expect(verdictFor(-1.2, -0.9), BodyVerdict.weightLoss);
    });

    test('sotto la tolleranza non si chiama movimento: è la BIA che '
        'respira', () {
      expect(verdictFor(-0.3, 0.2), BodyVerdict.stable);
    });

    test('grasso su e magra giù non si addolcisce', () {
      expect(verdictFor(0.9, -0.6), BodyVerdict.adverse);
    });

    test('senza composizione il verdetto resta «non so»', () {
      expect(
        BodyAnalysis.verdictOf(
          fatChange: null,
          leanChange: const BodyChange(deltaKg: 1, spanDays: 7),
        ),
        BodyVerdict.unknown,
      );
    });

    test('una ricomposizione vera si riconosce sui dati, non sul peso', () {
      // Il peso non si muove di un grammo in tre settimane: 4 kg di grasso in
      // meno e 4 di magra in più. Guardando la sola linea del peso non sarebbe
      // successo niente.
      final measurements = [
        for (var index = 0; index < 21; index++)
          measurement(
            day: DateTime(2026, 7, 16).add(Duration(days: index)),
            weightKg: 100,
            bodyFatPct: 25 - index * 0.2,
          ),
      ];
      final insights = BodyAnalysis.build(
        measurements: measurements,
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange!.deltaKg, closeTo(0, 0.0001));
      expect(insights.fatChange!.deltaKg, lessThan(-1));
      expect(insights.leanChange!.deltaKg, greaterThan(1));
      expect(insights.verdict, BodyVerdict.recomposition);
    });
  });

  group('rumore della BIA', () {
    test(
      'si misura sui giorni con più pesate, dove il corpo era lo stesso',
      () {
        final spread = BodyAnalysis.measureSpread([
          measurement(
            day: DateTime(2026, 8, 1),
            weightKg: 100,
            bodyFatPct: 24.9,
            hour: 8,
          ),
          measurement(
            day: DateTime(2026, 8, 1),
            weightKg: 100,
            bodyFatPct: 25.3,
            hour: 8,
            minute: 5,
          ),
          // Giorno con una sola lettura: non dice niente sul rumore.
          measurement(day: DateTime(2026, 8, 2), weightKg: 100, bodyFatPct: 20),
        ]);

        expect(spread.isMeasured, isTrue);
        expect(spread.dayCount, 1);
        expect(spread.bodyFatPoints, closeTo(0.4, 0.001));
        // Tradotto nell'unità del grafico: 0,4 punti su 100 kg sono 0,4 kg.
        expect(spread.fatMassKg, closeTo(0.4, 0.001));
      },
    );

    test('senza pesate ripetute non si inventa un numero', () {
      final spread = BodyAnalysis.measureSpread([
        measurement(day: DateTime(2026, 8, 1), weightKg: 100, bodyFatPct: 25),
        measurement(day: DateTime(2026, 8, 2), weightKg: 100, bodyFatPct: 20),
      ]);

      expect(spread.isMeasured, isFalse);
      expect(spread.dayCount, 0);
    });
  });

  group('circonferenze', () {
    test(
      'confronta la prima e l’ultima del periodo, con i giorni in mezzo',
      () {
        final trends = BodyAnalysis.circumferenceTrends([
          measurement(
            day: DateTime(2026, 6, 1),
            weightKg: 100,
            circumferences: const {'Vita': 96, 'Braccio': 36},
          ),
          measurement(
            day: DateTime(2026, 7, 31),
            weightKg: 98,
            circumferences: const {'Vita': 93.5},
          ),
        ]);

        final vita = trends.firstWhere((trend) => trend.label == 'Vita');
        expect(vita.latestCm, 93.5);
        expect(vita.deltaCm, closeTo(-2.5, 0.001));
        expect(vita.spanDays, 60);
        expect(vita.samples, 2);

        // Una misura sola non produce un confronto: non c'è niente da
        // confrontare, e mostrare «0,0» sarebbe una bugia.
        final braccio = trends.firstWhere((trend) => trend.label == 'Braccio');
        expect(braccio.deltaCm, isNull);
        expect(braccio.spanDays, isNull);
        // E con due punti non si disegna nemmeno: sarebbe una retta.
        expect(vita.isDrawable, isFalse);
        expect(vita.series.map((sample) => sample.$2), [96, 93.5]);
      },
    );

    test('due misure a pochi giorni non si confrontano: è come si tiene il '
        'metro', () {
      final trends = BodyAnalysis.circumferenceTrends([
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 100,
          circumferences: const {'Vita': 96},
        ),
        measurement(
          day: DateTime(2026, 8, 4),
          weightKg: 100,
          circumferences: const {'Vita': 94},
        ),
      ]);

      expect(trends.single.deltaCm, isNull);
      expect(trends.single.latestCm, 94);
    });
  });

  group('finestra visibile', () {
    test('i punti fuori dal periodo servono alla media ma non si mostrano', () {
      // Quaranta giorni consecutivi che finiscono oggi: la finestra da 30 ne
      // mostra 30 e usa i 10 precedenti solo per riempire le medie.
      final measurements = [
        for (var index = 39; index >= 0; index--)
          measurement(day: today.subtract(Duration(days: index)), weightKg: 95),
      ];
      final insights = BodyAnalysis.build(
        measurements: measurements,
        range: BodyRange.month,
        now: today,
      );

      expect(insights.days.length, 40);
      expect(insights.trend.length, 30);
      expect(insights.trend.first.day, DateTime.utc(2026, 7, 7));
      expect(insights.trend.last.day, DateTime.utc(2026, 8, 5));
      // Il primo punto visibile è già una media piena: i giorni prima del
      // periodo sono serviti da riscaldamento.
      expect(insights.trend.first.weightDays, BodyAnalysis.smoothingDays);
      expect(insights.staleDays, 0);
    });

    test('senza pesate torna il vuoto, non un grafico di zeri', () {
      final insights = BodyAnalysis.build(
        measurements: const [],
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.isEmpty, isTrue);
      expect(insights.latest, isNull);
      expect(insights.hasCompositionSeries, isFalse);
      expect(insights.verdict, BodyVerdict.unknown);
    });
  });
}
