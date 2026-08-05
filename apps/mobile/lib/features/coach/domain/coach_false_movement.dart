import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/coach/domain/coach_dates.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

/// Che cosa ha mosso la bilancia.
enum WeightMoveKind {
  /// Il numero del giorno si è mosso ma la tendenza no: è acqua.
  falseDrop,
  falseGain,

  /// Il numero del giorno e la tendenza vanno d'accordo.
  real,

  /// Non ci sono due pesate ravvicinate da confrontare.
  unknown,
}

/// **La spiegazione dei movimenti falsi.**
///
/// Serve a evitare due errori simmetrici: l'euforia per un −700 g che è
/// acqua e lo scoraggiamento per un +500 g che è la stessa acqua tornata.
/// Il criterio è sempre lo stesso del resto dell'app: conta la media a 7
/// giorni, il numero del singolo giorno è un campione rumoroso.
@immutable
class FalseMovement {
  const FalseMovement({
    required this.kind,
    this.dailyChangeKg,
    this.trendChangeKg,
    this.bodyWaterChangePoints,
    this.waterMlYesterday,
    this.typicalWaterMl,
  });

  const FalseMovement.unknown()
    : kind = WeightMoveKind.unknown,
      dailyChangeKg = null,
      trendChangeKg = null,
      bodyWaterChangePoints = null,
      waterMlYesterday = null,
      typicalWaterMl = null;

  final WeightMoveKind kind;

  /// L'ultima pesata meno quella del giorno prima con una pesata.
  final double? dailyChangeKg;

  /// La media a 7 giorni di adesso meno quella della settimana prima.
  final double? trendChangeKg;

  /// Punti percentuali di acqua corporea guadagnati o persi.
  final double? bodyWaterChangePoints;

  /// Acqua bevuta il giorno prima dell'ultima pesata.
  final int? waterMlYesterday;

  /// Quanta se ne beve di solito, sulle due settimane.
  final int? typicalWaterMl;

  bool get isFalse =>
      kind == WeightMoveKind.falseDrop || kind == WeightMoveKind.falseGain;

  /// La frase, o nulla quando non c'è niente da spiegare.
  ///
  /// I numeri qui dentro li produce il motore, non il modello: sono gli
  /// stessi che stanno nelle card sopra.
  String? get explanation {
    final daily = dailyChangeKg;
    if (!isFalse || daily == null) {
      return null;
    }
    final trend = trendChangeKg;
    final direction = kind == WeightMoveKind.falseDrop ? 'calo' : 'aumento';
    final buffer = StringBuffer()
      ..write(
        'Sulla bilancia l\'ultimo giorno segna '
        '${coachSignedNumber(daily)} kg',
      );
    if (trend != null) {
      buffer.write(
        ', ma la media a 7 giorni si è mossa di '
        '${coachSignedNumber(trend)} kg',
      );
    }
    buffer.write(': quel $direction è acqua, non grasso.');

    final cause = _cause();
    if (cause != null) {
      buffer.write(' $cause');
    }
    return buffer.toString();
  }

  String? _cause() {
    final water = bodyWaterChangePoints;
    if (water != null && water.abs() >= CoachFalseMovement.waterPointsHint) {
      return 'Anche la percentuale di acqua corporea si è mossa di '
          '${coachSignedNumber(water)} punti nella stessa direzione.';
    }
    final yesterday = waterMlYesterday;
    final typical = typicalWaterMl;
    if (yesterday != null &&
        typical != null &&
        typical > 0 &&
        (yesterday - typical).abs() >= CoachFalseMovement.waterMlHint) {
      final litres = coachNumber(yesterday / 1000);
      return yesterday < typical
          ? 'Il giorno prima avevi bevuto $litres L, meno del tuo solito.'
          : 'Il giorno prima avevi bevuto $litres L, più del tuo solito.';
    }
    return null;
  }
}

/// Il riconoscimento dei movimenti falsi. Puro.
abstract final class CoachFalseMovement {
  /// Sotto questo salto giornaliero non c'è niente da spiegare: è la
  /// bilancia, non l'acqua.
  static const double minimumDailyMoveKg = 0.5;

  /// Il movimento è «falso» quando la tendenza ne ha assorbito meno di
  /// questa frazione. Un terzo: se la media segue davvero, non è acqua.
  static const double trendShareOfRealMove = 1 / 3;

  /// Da qui in su il cambio di acqua corporea vale come causa dichiarabile.
  static const double waterPointsHint = 0.5;

  /// Da qui in su la bevuta del giorno prima vale come causa dichiarabile.
  static const int waterMlHint = 400;

  /// Quanti giorni indietro si guarda per trovare la pesata di confronto.
  /// Oltre, non è più «ieri» e il paragone non regge.
  static const int comparisonHorizonDays = 3;

  static FalseMovement detect({
    required List<BodyMeasurement> weighIns,
    required CoachAverages current,
    required CoachAverages previous,
    required List<CoachWaterDay> water,
  }) {
    final days = BodyAnalysis.collapseDays(weighIns);
    if (days.length < 2) {
      return const FalseMovement.unknown();
    }
    final latest = days.last;
    final earlier = days[days.length - 2];
    if (latest.day.difference(earlier.day).inDays > comparisonHorizonDays) {
      return const FalseMovement.unknown();
    }

    final daily = latest.weightKg - earlier.weightKg;
    final trend = (current.weightKg == null || previous.weightKg == null)
        ? null
        : current.weightKg! - previous.weightKg!;
    final waterChange =
        (current.bodyWaterPct == null || previous.bodyWaterPct == null)
        ? null
        : current.bodyWaterPct! - previous.bodyWaterPct!;

    final yesterday = latest.day.subtract(const Duration(days: 1));
    int? yesterdayMl;
    final allMl = <int>[];
    for (final day in water) {
      allMl.add(day.milliliters);
      if (day.day == yesterday) {
        yesterdayMl = day.milliliters;
      }
    }
    final typicalMl = allMl.isEmpty
        ? null
        : (allMl.reduce((a, b) => a + b) / allMl.length).round();

    final kind = _kindOf(daily: daily, trend: trend);
    return FalseMovement(
      kind: kind,
      dailyChangeKg: daily,
      trendChangeKg: trend,
      bodyWaterChangePoints: waterChange,
      waterMlYesterday: yesterdayMl,
      typicalWaterMl: typicalMl,
    );
  }

  static WeightMoveKind _kindOf({
    required double daily,
    required double? trend,
  }) {
    if (daily.abs() < minimumDailyMoveKg) {
      return WeightMoveKind.real;
    }
    if (trend == null) {
      return WeightMoveKind.unknown;
    }
    // La tendenza va nello stesso verso e ne ha assorbito abbastanza: il
    // movimento del giorno è vero.
    final followed =
        trend.sign == daily.sign &&
        trend.abs() >= daily.abs() * trendShareOfRealMove;
    if (followed) {
      return WeightMoveKind.real;
    }
    return daily < 0 ? WeightMoveKind.falseDrop : WeightMoveKind.falseGain;
  }
}
