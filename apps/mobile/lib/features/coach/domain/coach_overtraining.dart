import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

/// I quattro segnali del sovrallenamento.
///
/// Nessuno di loro da solo vuol dire niente: uno sforzo percepito più alto è
/// una settimana pesante, un calo rapido è una settimana di sale in meno. È
/// il fatto che arrivino **insieme** a fare la diagnosi.
enum OvertrainingSignal {
  risingEffort(
    label: 'Sforzo percepito in salita',
    firedDescription: 'Gli stessi allenamenti ti stanno costando di più.',
  ),
  fastWeightLoss(
    label: 'Calo di peso rapido',
    firedDescription: 'Stai scendendo più in fretta del limite di sicurezza.',
  ),
  lowProtein(
    label: 'Proteine sotto target',
    firedDescription: 'Con queste proteine il muscolo non si difende.',
  ),
  fallingBodyWater(
    label: 'Acqua corporea in calo',
    firedDescription: 'La percentuale di acqua sta scendendo.',
  );

  const OvertrainingSignal({
    required this.label,
    required this.firedDescription,
  });

  final String label;
  final String firedDescription;
}

/// Cosa dice un segnale. **`unknown` non è `quiet`**: nello storico reale di
/// Marco l'RPE è compilato in 17 sessioni su 29, e trattare quel buco come
/// «tutto bene» sarebbe una bugia con la faccia rassicurante.
enum SignalReading { fired, quiet, unknown }

/// Il colore del semaforo.
enum OvertrainingLevel {
  clear(label: 'Nessun allarme'),
  watch(label: 'Tieni d\'occhio'),
  deload(label: 'Settimana di scarico');

  const OvertrainingLevel({required this.label});

  final String label;
}

/// Il semaforo del sovrallenamento.
@immutable
class OvertrainingLight {
  const OvertrainingLight({required this.readings});

  final Map<OvertrainingSignal, SignalReading> readings;

  Iterable<OvertrainingSignal> get fired => [
    for (final signal in OvertrainingSignal.values)
      if (readings[signal] == SignalReading.fired) signal,
  ];

  Iterable<OvertrainingSignal> get unknown => [
    for (final signal in OvertrainingSignal.values)
      if ((readings[signal] ?? SignalReading.unknown) == SignalReading.unknown)
        signal,
  ];

  int get firedCount => fired.length;

  /// Quanti segnali si riescono a leggere davvero.
  int get knownCount => OvertrainingSignal.values.length - unknown.length;

  OvertrainingLevel get level {
    if (firedCount >= CoachOvertraining.deloadThreshold) {
      return OvertrainingLevel.deload;
    }
    if (firedCount >= CoachOvertraining.watchThreshold) {
      return OvertrainingLevel.watch;
    }
    return OvertrainingLevel.clear;
  }

  int get _total => OvertrainingSignal.values.length;

  /// La frase del semaforo, deterministica.
  String get headline => switch (level) {
    OvertrainingLevel.deload =>
      'Sono accesi $firedCount segnali su $_total: questa è una settimana di '
          'scarico, non una in cui spingere.',
    OvertrainingLevel.watch =>
      'Ci sono $firedCount segnali accesi su $_total: non è un allarme, ma '
          'la prossima settimana guardali.',
    OvertrainingLevel.clear when knownCount == 0 =>
      'Non ho abbastanza dati per accendere il semaforo: manca lo sforzo '
          'percepito e mancano le pesate.',
    OvertrainingLevel.clear => 'Nessun segnale acceso.',
  };

  /// Le ragioni, una per segnale acceso.
  List<String> get reasons => [
    for (final signal in fired) signal.firedDescription,
  ];

  /// Cosa non si è potuto leggere, detto apertamente.
  String? get missingDataNote {
    final missing = unknown.toList(growable: false);
    if (missing.isEmpty) {
      return null;
    }
    final names = missing
        .map((signal) => signal.label.toLowerCase())
        .join(', ');
    return 'Non ho letto: $names.';
  }
}

/// **Il semaforo del sovrallenamento, e deve funzionare con i buchi.**
///
/// RPE in salita + calo di peso rapido + proteine sotto target + acqua
/// corporea in calo → scarico. Ma nei dati veri l'RPE c'è in 17 sessioni su
/// 29, la soddisfazione uguale, l'umore in 11 e le note in nessuna: un
/// semaforo che pretende quattro segnali su quattro resterebbe spento per
/// sempre. Quindi ogni segnale può valere «non lo so», e la soglia si conta
/// sugli **accesi**, non sui disponibili.
abstract final class CoachOvertraining {
  /// Tre segnali accesi: scarico. Due sono una coincidenza, tre no.
  static const int deloadThreshold = 3;

  /// Due segnali: si guarda, non si cambia niente.
  static const int watchThreshold = 2;

  /// Quanto deve salire lo sforzo percepito medio perché conti. Mezzo punto
  /// è dentro il modo in cui una persona compila la stessa scala in giorni
  /// diversi.
  static const double effortRiseThreshold = 0.75;

  /// Sessioni con RPE che servono per settimana perché la media conti.
  static const int minimumRatedSessions = 2;

  /// Il limite di sicurezza della roadmap: 0,7 % del peso a settimana. Oltre,
  /// il corpo copre la differenza anche col muscolo.
  static const double maxWeeklyFractionOfBodyWeight = 0.007;

  /// Sotto questo rapporto le proteine sono «sotto target». È la stessa
  /// soglia con cui l'aderenza chiama `off` la riga delle proteine: due
  /// numeri diversi darebbero due verdetti diversi sullo stesso dato.
  static const double proteinFloorRatio = CoachAdherence.proteinDriftingRatio;

  /// Punti percentuali di acqua corporea persi in una settimana perché conti.
  static const double bodyWaterDropPoints = 0.8;

  static OvertrainingLight assess({
    required List<CoachSession> currentSessions,
    required List<CoachSession> previousSessions,
    required CoachAverages currentAverages,
    required CoachAverages previousAverages,
    required AdherenceLine proteinLine,
  }) {
    return OvertrainingLight(
      readings: {
        OvertrainingSignal.risingEffort: _effortReading(
          currentSessions,
          previousSessions,
        ),
        OvertrainingSignal.fastWeightLoss: _weightReading(
          currentAverages,
          previousAverages,
        ),
        OvertrainingSignal.lowProtein: _proteinReading(proteinLine),
        OvertrainingSignal.fallingBodyWater: _waterReading(
          currentAverages,
          previousAverages,
        ),
      },
    );
  }

  static SignalReading _effortReading(
    List<CoachSession> current,
    List<CoachSession> previous,
  ) {
    final now = _averageRpe(current);
    final before = _averageRpe(previous);
    if (now == null || before == null) {
      return SignalReading.unknown;
    }
    return now - before >= effortRiseThreshold
        ? SignalReading.fired
        : SignalReading.quiet;
  }

  static double? _averageRpe(List<CoachSession> sessions) {
    final values = [
      for (final session in sessions)
        if (session.rpe case final rpe?) rpe.toDouble(),
    ];
    if (values.length < minimumRatedSessions) {
      return null;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }

  static SignalReading _weightReading(
    CoachAverages current,
    CoachAverages previous,
  ) {
    final now = current.weightKg;
    final before = previous.weightKg;
    if (now == null || before == null || !current.isSolid) {
      return SignalReading.unknown;
    }
    final limit = before * maxWeeklyFractionOfBodyWeight;
    return before - now > limit ? SignalReading.fired : SignalReading.quiet;
  }

  static SignalReading _proteinReading(AdherenceLine line) {
    final ratio = line.ratio;
    if (!line.isKnown || ratio == null) {
      return SignalReading.unknown;
    }
    return ratio < proteinFloorRatio
        ? SignalReading.fired
        : SignalReading.quiet;
  }

  static SignalReading _waterReading(
    CoachAverages current,
    CoachAverages previous,
  ) {
    final now = current.bodyWaterPct;
    final before = previous.bodyWaterPct;
    if (now == null || before == null) {
      return SignalReading.unknown;
    }
    return before - now >= bodyWaterDropPoints
        ? SignalReading.fired
        : SignalReading.quiet;
  }
}
