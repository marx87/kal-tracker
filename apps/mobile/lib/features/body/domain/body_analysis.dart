import 'package:kal_tracker/features/body/domain/body_models.dart';

/// La matematica della schermata Corpo, tutta in funzioni pure.
///
/// Sta separata dalla UI e dal database perché è il punto in cui si decide se
/// un numero è vero: la BIA è rumorosa (nei dati veri due letture a cinque
/// minuti di distanza differiscono di un decimo di punto di grasso), quindi
/// nessun confronto giorno-su-giorno esce mai da qui.
abstract final class BodyAnalysis {
  /// Larghezza della media mobile. Sette giorni e non cinque: copre la
  /// settimana intera, quindi il sabato e il lunedì pesano uguale.
  static const smoothingDays = 7;

  /// Giorni di dati che servono PRIMA della finestra visibile perché anche il
  /// suo primo punto sia una media piena e non un troncone.
  static const warmupDays = smoothingDays - 1;

  /// Distanza a cui si cerca il termine di paragone: una settimana fa.
  static const comparisonDays = 7;

  /// Sotto questa distanza un confronto non si fa: due medie a 7 giorni
  /// distanti due giorni condividono cinque giorni su sette, quindi la loro
  /// differenza è quasi tutta rumore.
  static const minimumComparisonDays = 4;

  /// Quanto può distare una lettura dalla prima del giorno per contare come
  /// **lo stesso momento**.
  ///
  /// Tre ore, e il numero nasce da un difetto vero. La regola «vale la prima
  /// con impedenza» era stata scritta senza limite d'orario, e così una pesata
  /// serale col contatto riuscito batteva quella del mattino senza — cioè
  /// prendeva il peso dopo cena pieno, che è esattamente il chilo e mezzo di
  /// cibo e acqua che la regola esiste per togliere. In quel caso era peggiore
  /// della vecchia media, che almeno dimezzava l'errore.
  ///
  /// Tre ore coprono ciò che serve coprire — si sale con le calze, non legge,
  /// si riprova scalzi; ci si pesa, si va in bagno, ci si ripesa — e non
  /// coprono mattina contro sera, che è tutto il punto.
  static const sameConditionWindow = Duration(hours: 3);

  /// Soglia sotto la quale una variazione delle masse si chiama «stabile».
  /// Mezzo etto di massa grassa non è un risultato, è la BIA che respira.
  static const stableToleranceKg = 0.4;

  /// Costruisce tutto quello che serve alla schermata.
  ///
  /// [measurements] deve già contenere il periodo visibile PIÙ i
  /// [warmupDays] precedenti: il repository li chiede apposta.
  static BodyInsights build({
    required List<BodyMeasurement> measurements,
    required BodyRange range,
    required DateTime now,
  }) {
    if (measurements.isEmpty) {
      return BodyInsights.empty(range);
    }

    final sorted = [...measurements]
      ..sort((a, b) => b.measuredAt.compareTo(a.measuredAt));
    final today = bodyDayOf(now);
    final visibleFrom = today.subtract(Duration(days: range.days - 1));

    final days = collapseDays(sorted);
    final smoothed = smooth(days);
    final visible = smoothed
        .where((point) => !point.day.isBefore(visibleFrom))
        .toList(growable: false);

    final latest = visible.isNotEmpty ? visible.last : null;
    final weightChange = _changeOf(smoothed, latest, (point) => point.weightKg);
    final fatChange = _changeOf(smoothed, latest, (point) => point.fatMassKg);
    final leanChange = _changeOf(smoothed, latest, (point) => point.leanMassKg);

    return BodyInsights(
      range: range,
      measurements: sorted,
      days: days,
      trend: visible,
      circumferences: circumferenceTrends(sorted),
      spread: measureSpread(sorted),
      verdict: verdictOf(fatChange: fatChange, leanChange: leanChange),
      latest: latest,
      weightChange: weightChange,
      fatChange: fatChange,
      leanChange: leanChange,
      staleDays: today.difference(bodyDayOf(sorted.first.measuredAt)).inDays,
    );
  }

  /// Un giorno, un punto: **la prima pesata utile della giornata**.
  ///
  /// Prima si faceva la media di tutte le letture del giorno, e sembrava il
  /// filtro giusto contro il rumore. Non lo era, perché quelle letture non
  /// misurano la stessa cosa: fra la mattina a digiuno e la sera dopo cena ci
  /// sono un chilo e mezzo di cibo e acqua, e sono un chilo e mezzo **vero**,
  /// non rumore. Mediarli produce un numero che non corrisponde a nessun
  /// momento della giornata e che si sposta a seconda di quante volte uno è
  /// salito sulla bilancia — un giorno con la sola pesata del mattino e uno
  /// con mattina e sera diventano incomparabili, e la media mobile a sette
  /// giorni li mette in fila come se lo fossero.
  ///
  /// La mattina a digiuno è l'unica condizione che si ripete uguale ogni
  /// giorno, ed è per questo che vale quella. Le altre pesate **non si
  /// buttano**: restano nello storico, restano nel conteggio qui sotto, e
  /// [measureSpread] continua a usarle tutte — lì servono proprio perché sono
  /// dello stesso giorno.
  ///
  /// «Utile» vuol dire con l'impedenza — ma **solo fra le letture vicine alla
  /// prima** ([sameConditionWindow]). Una pesata col contatto riuscito dice
  /// tutto quello che dice una senza, più la composizione, e a mezz'ora di
  /// distanza è la stessa pesata riuscita meglio. A quindici ore no: è
  /// un'altra condizione, e preferirla significherebbe far vincere la sera
  /// sulla mattina — il contrario di quello che questa regola serve a fare.
  static List<BodyDayPoint> collapseDays(List<BodyMeasurement> measurements) {
    final grouped = <DateTime, List<BodyMeasurement>>{};
    for (final measurement in measurements) {
      grouped.putIfAbsent(measurement.day, () => []).add(measurement);
    }

    final points = <BodyDayPoint>[];
    for (final entry in grouped.entries) {
      final readings = entry.value.toList()
        // A parità di istante decide l'identificativo, e non è pedanteria: due
        // letture possono condividere il millisecondo (un import, una doppia
        // scrittura), e senza un secondo criterio «la prima» diventerebbe
        // «quella che la query ha restituito per prima» — cioè un numero che
        // può cambiare senza che nessun dato sia cambiato.
        ..sort((a, b) {
          final istante = a.measuredAt.compareTo(b.measuredAt);
          return istante != 0 ? istante : a.id.compareTo(b.id);
        });
      final withComposition = readings
          .where((item) => item.hasComposition)
          .toList(growable: false);
      // Nessuna soglia oraria assoluta, di proposito: «prima del mattino» con
      // un taglio a mezzogiorno butterebbe via il giorno in cui ci si è pesati
      // solo la sera, e un dato tardi vale comunque più di un buco. La
      // finestra è **relativa alla prima lettura**, non all'orologio.
      final first = readings.first;
      final limite = first.measuredAt.add(sameConditionWindow);
      final chosen = withComposition.firstWhere(
        (item) => !item.measuredAt.isAfter(limite),
        orElse: () => first,
      );

      points.add(
        BodyDayPoint(
          day: entry.key,
          weightKg: chosen.weightKg,
          measuredAt: chosen.measuredAt,
          readings: readings.length,
          compositionReadings: withComposition.length,
          // Grassa e magra vengono dalla stessa lettura del peso, quindi la
          // loro somma È quel peso: la pila del grafico non può contenere una
          // contraddizione interna.
          fatMassKg: chosen.fatMassKg,
          leanMassKg: chosen.leanMassKg,
          waterPct: chosen.waterPct,
        ),
      );
    }

    points.sort((a, b) => a.day.compareTo(b.day));
    return List.unmodifiable(points);
  }

  /// Media mobile a 7 giorni sui giorni, non sulle letture: un giorno con
  /// quattro pesate vale quanto un giorno con una sola.
  ///
  /// La finestra è di calendario (gli ultimi 7 giorni), non «gli ultimi 7
  /// punti»: dopo due settimane di pausa la media non deve fingere continuità.
  /// I punti si producono solo nei giorni in cui ci si è pesati, così il
  /// grafico non inventa dati nei buchi.
  static List<BodyTrendPoint> smooth(List<BodyDayPoint> days) {
    final points = <BodyTrendPoint>[];
    for (var index = 0; index < days.length; index++) {
      final current = days[index];
      final from = current.day.subtract(const Duration(days: warmupDays));

      final weights = <double>[];
      final fats = <double>[];
      final leans = <double>[];
      for (var back = index; back >= 0; back--) {
        final candidate = days[back];
        if (candidate.day.isBefore(from)) {
          break;
        }
        weights.add(candidate.weightKg);
        if (candidate.hasComposition) {
          fats.add(candidate.fatMassKg!);
          leans.add(candidate.leanMassKg!);
        }
      }

      points.add(
        BodyTrendPoint(
          day: current.day,
          weightKg: _mean(weights),
          weightDays: weights.length,
          compositionDays: fats.length,
          fatMassKg: fats.isEmpty ? null : _mean(fats),
          leanMassKg: leans.isEmpty ? null : _mean(leans),
        ),
      );
    }
    return List.unmodifiable(points);
  }

  /// Lo scarto della BIA misurato sulle pesate **ravvicinate**: lì il corpo è
  /// lo stesso, quindi la differenza è tutta strumento.
  ///
  /// «Ravvicinate» e non «dello stesso giorno», ed è una correzione: fra la
  /// mattina e la sera ci sono cibo, acqua e un'idratazione diversa, cioè
  /// fisiologia vera. Contarle come ripetizioni gonfiava il rumore attribuito
  /// alla bilancia con roba che bilancia non è — e la card che dice «a corpo
  /// fermo» affermava una cosa falsa proprio mentre citava il numero come
  /// prova.
  static BiaSpread measureSpread(List<BodyMeasurement> measurements) {
    final byDay = <DateTime, List<BodyMeasurement>>{};
    for (final measurement in measurements) {
      if (!measurement.hasComposition) {
        continue;
      }
      byDay.putIfAbsent(measurement.day, () => []).add(measurement);
    }

    final spreads = <double>[];
    final weights = <double>[];
    for (final all in byDay.values) {
      if (all.length < 2) {
        continue;
      }
      final readings = all.toList()
        ..sort((a, b) => a.measuredAt.compareTo(b.measuredAt));
      // Solo le letture entro la finestra dalla prima: le altre sono un altro
      // momento del corpo, non una ripetizione della stessa misura.
      final limite = readings.first.measuredAt.add(sameConditionWindow);
      final vicine = readings
          .where((item) => !item.measuredAt.isAfter(limite))
          .toList(growable: false);
      if (vicine.length < 2) {
        continue;
      }
      final percentages = vicine
          .map((item) => item.bodyFatPct!)
          .toList(growable: false);
      percentages.sort();
      spreads.add(percentages.last - percentages.first);
      weights.add(_mean(vicine.map((item) => item.weightKg)));
    }

    if (spreads.isEmpty) {
      return const BiaSpread.unmeasured();
    }
    final median = _median(spreads);
    return BiaSpread(
      bodyFatPoints: median,
      fatMassKg: median / 100 * _mean(weights),
      dayCount: spreads.length,
    );
  }

  /// Andamento delle circonferenze: ultima misura contro la più vecchia del
  /// periodo, con i giorni che le separano dichiarati.
  static List<CircumferenceTrend> circumferenceTrends(
    List<BodyMeasurement> measurements,
  ) {
    // Dalla più vecchia alla più recente: così l'ultimo scritto vince come
    // «latest» e il primo resta il termine di paragone.
    final ordered = [...measurements]
      ..sort((a, b) => a.measuredAt.compareTo(b.measuredAt));

    final samples = <String, List<(DateTime, double)>>{};
    for (final measurement in ordered) {
      for (final entry in measurement.circumferences.entries) {
        samples.putIfAbsent(entry.key, () => []).add((
          measurement.measuredAt,
          entry.value,
        ));
      }
    }

    final trends = [
      for (final entry in samples.entries)
        CircumferenceTrend(
          label: entry.key,
          series: List.unmodifiable(entry.value),
        ),
    ];

    trends.sort((a, b) {
      // Prima quelle che si muovono davvero, poi in ordine alfabetico: la
      // vita interessa più del collo, ma solo se la vita si sta muovendo.
      final byDelta = (b.deltaCm?.abs() ?? -1).compareTo(
        a.deltaCm?.abs() ?? -1,
      );
      return byDelta != 0 ? byDelta : a.label.compareTo(b.label);
    });
    return List.unmodifiable(trends);
  }

  /// Ricomposizione o dimagrimento: si guarda cosa fanno le DUE masse, mai il
  /// peso da solo.
  static BodyVerdict verdictOf({
    required BodyChange? fatChange,
    required BodyChange? leanChange,
    double toleranceKg = stableToleranceKg,
  }) {
    if (fatChange == null || leanChange == null) {
      return BodyVerdict.unknown;
    }
    final fatStable = fatChange.isStable(toleranceKg);
    final leanStable = leanChange.isStable(toleranceKg);
    if (fatStable && leanStable) {
      return BodyVerdict.stable;
    }

    final fatDown = fatChange.deltaKg < 0;
    final leanUp = leanChange.deltaKg > 0;
    if (!fatStable && fatDown) {
      if (!leanStable && leanUp) {
        return BodyVerdict.recomposition;
      }
      return leanStable ? BodyVerdict.cleanFatLoss : BodyVerdict.weightLoss;
    }
    if (!fatStable && !fatDown) {
      return leanStable || !leanUp ? BodyVerdict.adverse : BodyVerdict.gain;
    }
    // Il grasso è fermo: comanda la magra.
    return leanUp ? BodyVerdict.gain : BodyVerdict.weightLoss;
  }

  /// Cerca il punto di paragone: la media più recente distante almeno
  /// [minimumComparisonDays] giorni, puntando ai [comparisonDays].
  ///
  /// Non si assume mai che il punto giusto esista: se ci si è pesati a
  /// singhiozzo si confronta con quello che c'è e si dichiara la distanza.
  static BodyChange? _changeOf(
    List<BodyTrendPoint> smoothed,
    BodyTrendPoint? latest,
    double? Function(BodyTrendPoint point) valueOf,
  ) {
    final current = latest == null ? null : valueOf(latest);
    if (latest == null || current == null) {
      return null;
    }
    final target = latest.day.subtract(const Duration(days: comparisonDays));

    BodyTrendPoint? best;
    for (final point in smoothed) {
      if (point.day.isAfter(latest.day)) {
        break;
      }
      if (valueOf(point) == null) {
        continue;
      }
      final distance = latest.day.difference(point.day).inDays;
      if (distance < minimumComparisonDays) {
        continue;
      }
      // Il candidato migliore è quello più vicino ai 7 giorni indietro; a
      // parità vince il più lontano (si scorre in avanti e non si sostituisce
      // a pari merito), perché due finestre da 7 giorni più distanti
      // condividono meno dati e la differenza è meno rumore.
      if (best == null ||
          point.day.difference(target).inDays.abs() <
              best.day.difference(target).inDays.abs()) {
        best = point;
      }
    }
    if (best == null) {
      return null;
    }
    return BodyChange(
      deltaKg: current - valueOf(best)!,
      spanDays: latest.day.difference(best.day).inDays,
    );
  }

  static double _mean(Iterable<double> values) {
    var total = 0.0;
    var count = 0;
    for (final value in values) {
      total += value;
      count++;
    }
    return count == 0 ? 0 : total / count;
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}
