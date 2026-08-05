import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// Una pesata: peso sempre, composizione quando la bilancia l'ha letta.
class WeightPoint {
  const WeightPoint({
    required this.at,
    required this.weightKg,
    this.bodyFatPct,
  });

  final DateTime at;
  final double weightKg;

  /// Nulla quando la bilancia ha misurato il solo peso (piedi appoggiati
  /// male, oppure pesata inserita a mano).
  final double? bodyFatPct;

  bool get hasComposition => bodyFatPct != null;
}

/// Lo stato del corpo così com'è oggi, per come lo sa l'app.
///
/// Tutti i campi possono mancare: l'app deve funzionare anche il primo
/// giorno, senza una pesata e senza obiettivo.
class BodyState {
  const BodyState({
    this.latest,
    this.fatFreeMassKg,
    this.fatFreeMassMeasuredAt,
    this.sevenDayAverageKg,
    this.tdeeSample,
  });

  const BodyState.unknown()
    : latest = null,
      fatFreeMassKg = null,
      fatFreeMassMeasuredAt = null,
      sevenDayAverageKg = null,
      tdeeSample = null;

  final WeightPoint? latest;

  /// La massa magra dell'ultima pesata che l'aveva. Cambia lentamente:
  /// resta valida anche se il peso di stamattina è più recente.
  final double? fatFreeMassKg;
  final DateTime? fatFreeMassMeasuredAt;

  /// La media a 7 giorni: è questa che si confronta con la banda, non il
  /// numero di stamattina.
  final double? sevenDayAverageKg;

  final TdeeSample? tdeeSample;

  bool get hasWeight => latest != null;

  /// Senza composizione la curva non esiste: peso e definizione tornano a
  /// essere due cose scollegate, e il selettore non ha niente da collegare.
  bool get hasComposition => fatFreeMassKg != null;

  double? get weightKg => latest?.weightKg;
}

/// I calcoli che trasformano lo storico grezzo in [BodyState]. Puri e
/// testabili: il repository fa solo le query.
abstract final class BodyStateMath {
  /// Media delle pesate degli ultimi [days] giorni.
  static double? averageWithinDays({
    required List<WeightPoint> points,
    required DateTime now,
    int days = 7,
  }) {
    final from = now.toUtc().subtract(Duration(days: days));
    final recent = points.where((point) => !point.at.toUtc().isBefore(from));
    if (recent.isEmpty) {
      return null;
    }
    final total = recent.fold<double>(0, (sum, point) => sum + point.weightKg);
    return total / recent.length;
  }

  /// La massa magra più recente che si possa calcolare davvero.
  ///
  /// Peso e percentuale devono venire dalla **stessa** pesata: incrociare il
  /// peso di oggi con la percentuale di tre settimane fa produce un numero
  /// che non è mai esistito.
  static WeightPoint? latestWithComposition(List<WeightPoint> points) {
    WeightPoint? best;
    for (final point in points) {
      if (!point.hasComposition) {
        continue;
      }
      if (best == null || point.at.isAfter(best.at)) {
        best = point;
      }
    }
    return best;
  }

  /// La finestra di dati reali su cui misurare il consumo.
  ///
  /// [dailyKcal] è indicizzato per giorno civile romano (`yyyy-MM-dd`): i
  /// giorni senza diario **non** valgono zero calorie, valgono «non so», e
  /// vengono esclusi invece di abbassare la media.
  static TdeeSample? buildSample({
    required List<WeightPoint> points,
    required Map<String, double> dailyKcal,
    required String Function(DateTime) dayKeyOf,
    int minimumDays = AdaptiveTdee.minimumDays,
    int edgeDays = 3,
  }) {
    if (points.length < 2) {
      return null;
    }
    final sorted = [...points]..sort((a, b) => a.at.compareTo(b.at));
    final first = sorted.first.at.toUtc();
    final last = sorted.last.at.toUtc();
    final span = last.difference(first).inDays;
    if (span < minimumDays) {
      return null;
    }

    // Estremi mediati su qualche giorno: una singola pesata all'inizio o
    // alla fine porta dentro tutta l'oscillazione dell'acqua.
    final earlyLimit = first.add(Duration(days: edgeDays));
    final lateLimit = last.subtract(Duration(days: edgeDays));
    final early = sorted
        .where((point) => !point.at.toUtc().isAfter(earlyLimit))
        .toList(growable: false);
    final late = sorted
        .where((point) => !point.at.toUtc().isBefore(lateLimit))
        .toList(growable: false);
    final startWeight = _mean(early.map((point) => point.weightKg));
    final endWeight = _mean(late.map((point) => point.weightKg));
    if (startWeight == null || endWeight == null) {
      return null;
    }

    final kcalInWindow = <double>[];
    for (var offset = 0; offset <= span; offset++) {
      final key = dayKeyOf(first.add(Duration(days: offset)));
      final kcal = dailyKcal[key];
      if (kcal != null && kcal > 0) {
        kcalInWindow.add(kcal);
      }
    }
    if (kcalInWindow.length < minimumDays) {
      return null;
    }

    return TdeeSample(
      averageDailyKcal: _mean(kcalInWindow)!,
      weightChangeKg: endWeight - startWeight,
      days: span,
    );
  }

  /// La massa magra di una pesata completa.
  static double? fatFreeMassOf(WeightPoint? point) {
    if (point == null || !point.hasComposition) {
      return null;
    }
    return BodyComposition.fatFreeMassKg(
      weightKg: point.weightKg,
      bodyFatPct: point.bodyFatPct!,
    );
  }

  static double? _mean(Iterable<double> values) {
    if (values.isEmpty) {
      return null;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }
}
