import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_dates.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';

/// I cinque segnali del sovrallenamento.
///
/// Nessuno di loro da solo vuol dire niente: uno sforzo percepito più alto è
/// una settimana pesante, un calo rapido è una settimana di sale in meno. È
/// il fatto che arrivino **insieme** a fare la diagnosi.
///
/// I primi quattro sono indizi: dicono che il corpo *potrebbe* non stare
/// reggendo. [fallingStrength] è l'unico diretto — la forza che scende è già
/// il danno, non il suo sintomo — ed è per questo che quando è acceso decide
/// anche la lettura degli altri.
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
  ),
  fallingStrength(
    label: 'Forza in calo',
    firedDescription:
        'Sui fondamentali stai sollevando meno di tre '
        'settimane fa.',
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

/// **Da che parte arriva il guaio, perché il rimedio è opposto.**
///
/// Sovrallenamento e sottoalimentazione accendono gli stessi segnali e
/// chiedono due cose contrarie: se il carico è troppo si scarica, se il
/// deficit è troppo si mangia di più. Sbagliare verso costa doppio — togliere
/// allenamento a chi mangiava poco gli fa perdere lo stimolo *e* il muscolo.
enum OvertrainingCause {
  /// Il carico. Qui lo scarico è la risposta giusta.
  training,

  /// Il deficit. Qui fermarsi non ripara niente: si alza il piatto.
  underEating,

  /// Acceso, ma i segnali non dicono da che parte.
  unclear,

  /// Niente di acceso, niente da spiegare.
  none,
}

/// Il semaforo del sovrallenamento.
@immutable
class OvertrainingLight {
  const OvertrainingLight({
    required this.readings,
    this.strength = const StrengthTrend.unknown(),
  });

  final Map<OvertrainingSignal, SignalReading> readings;

  /// La misura dietro [OvertrainingSignal.fallingStrength]. Serve a dire di
  /// quanto e su quali esercizi: «la forza cala» senza il numero non si
  /// distingue da un'impressione.
  final StrengthTrend strength;

  bool isFired(OvertrainingSignal signal) =>
      readings[signal] == SignalReading.fired;

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

  /// Quanti segnali sono stati **letti**, non quanti esistono.
  ///
  /// Dire «3 accesi su 5» quando uno dei cinque non ha dati da leggere è
  /// falso in modo insidioso: sembra che due siano spenti mentre uno è cieco,
  /// e la stessa card poi elenca fra i mancanti proprio quello. Il quinto
  /// segnale — la forza — esiste nel dominio ma non è ancora collegato allo
  /// storico degli allenamenti, quindi in produzione oggi è sempre cieco.
  int get _total =>
      readings.values.where((r) => r != SignalReading.unknown).length;

  /// Da che parte arriva il guaio.
  ///
  /// La regola sta tutta nel caso in cui carico e dieta sono accesi insieme:
  /// lì **decide la forza**. Un e1RM che scende mentre il peso corre giù o le
  /// proteine mancano è la firma della sottoalimentazione, e in quel caso lo
  /// scarico toglie lo stimolo senza restituire il materiale per ricostruire.
  OvertrainingCause get cause {
    if (level == OvertrainingLevel.clear) {
      return OvertrainingCause.none;
    }
    final diet =
        isFired(OvertrainingSignal.fastWeightLoss) ||
        isFired(OvertrainingSignal.lowProtein);
    final load = isFired(OvertrainingSignal.risingEffort);
    if (diet && load) {
      return isFired(OvertrainingSignal.fallingStrength)
          ? OvertrainingCause.underEating
          : OvertrainingCause.unclear;
    }
    if (diet) {
      return OvertrainingCause.underEating;
    }
    if (load) {
      return OvertrainingCause.training;
    }
    return OvertrainingCause.unclear;
  }

  /// La frase del semaforo, deterministica.
  String get headline => switch (level) {
    OvertrainingLevel.deload when cause == OvertrainingCause.underEating =>
      'Sono accesi $firedCount segnali su $_total e sono quelli della dieta: '
          'non ti stai allenando troppo, stai mangiando troppo poco. Il '
          'rimedio è ridurre il deficit, non lo scarico.',
    OvertrainingLevel.deload =>
      'Sono accesi $firedCount segnali su $_total: questa è una settimana di '
          'scarico, non una in cui spingere.',
    OvertrainingLevel.watch when cause == OvertrainingCause.underEating =>
      'Ci sono $firedCount segnali accesi su $_total e puntano al piatto più '
          'che al bilanciere: prima di togliere allenamento, guarda quanto '
          'stai mangiando.',
    OvertrainingLevel.watch =>
      'Ci sono $firedCount segnali accesi su $_total: non è un allarme, ma '
          'la prossima settimana guardali.',
    OvertrainingLevel.clear when knownCount == 0 =>
      'Non ho abbastanza dati per accendere il semaforo: qui sotto c\'è cosa '
          'mi manca.',
    OvertrainingLevel.clear => 'Nessun segnale acceso.',
  };

  /// Le ragioni, una per segnale acceso.
  List<String> get reasons => [for (final signal in fired) _reasonFor(signal)];

  String _reasonFor(OvertrainingSignal signal) {
    if (signal != OvertrainingSignal.fallingStrength) {
      return signal.firedDescription;
    }
    final change = strength.change;
    if (change == null || strength.exercises.isEmpty) {
      return signal.firedDescription;
    }
    // Il numero e gli esercizi si dicono sempre: «la forza cala» da solo non
    // si distingue da un'impressione, e la media vale solo per quei
    // fondamentali lì.
    final drop = coachNumber(-change * 100);
    return 'Su ${strength.exercises.join(', ')} l\'e1RM medio è sceso del '
        '$drop % rispetto a tre settimane fa.';
  }

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
/// corporea in calo + forza in discesa → scarico. Ma nei dati veri l'RPE c'è
/// in 17 sessioni su 29, la soddisfazione uguale, l'umore in 11 e le note in
/// nessuna: un semaforo che pretende cinque segnali su cinque resterebbe
/// spento per sempre. Quindi ogni segnale può valere «non lo so», e la soglia
/// si conta sugli **accesi**, non sui disponibili.
///
/// Le soglie restano quelle di quando i segnali erano quattro: il quinto
/// aggiunge una prova, non alza l'asticella. Quello che cambia con la forza è
/// il *verso* della diagnosi, non il colore — vedi [OvertrainingCause].
abstract final class CoachOvertraining {
  /// Tre segnali accesi: scarico. Due sono una coincidenza, tre no.
  static const int deloadThreshold = 3;

  /// Due segnali: si guarda, non si cambia niente.
  static const int watchThreshold = 2;

  /// Quanto deve salire lo sforzo percepito medio perché conti.
  ///
  /// **Ritarato quando la domanda è diventata a tre bersagli.** Con la scala
  /// 1-10 lo 0,75 era mezzo punto di tremolio, cioè il modo in cui una
  /// persona compila la stessa scala in giorni diversi. Con facile/giusta/dura
  /// — 3, 6 e 9 — quel tremolio non esiste più: si tocca un bersaglio o un
  /// altro, e il gradino minimo è 3.
  ///
  /// Su una settimana da quattro sedute, **una sola** risposta che passa da
  /// «giusta» a «dura» sposta la media di 0,75 esatti. Con la vecchia soglia
  /// il segnale si accendeva per quella: non è un carico che sale, è una
  /// giornata storta. Uno e mezzo vuol dire due sedute su quattro, che è un
  /// cambio di settimana e non di umore.
  static const double effortRiseThreshold = 1.5;

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

  /// Di quanto deve scendere l'e1RM medio sui fondamentali, in frazione,
  /// perché il segnale si accenda. Il 5 % è una **soglia di partenza da
  /// tarare** sui dati veri: più in basso una serie lasciata a metà la fa
  /// scattare da sola, più in alto la forza se n'è già andata da un pezzo
  /// prima che il semaforo se ne accorga. Il confronto a tre settimane
  /// ([CoachStrength.comparisonGapDays]) è la metà del lavoro; questa è
  /// l'altra.
  static const double strengthDropRatio = 0.05;

  static OvertrainingLight assess({
    required List<CoachSession> currentSessions,
    required List<CoachSession> previousSessions,
    required CoachAverages currentAverages,
    required CoachAverages previousAverages,
    required AdherenceLine proteinLine,
    // Facoltativo perché la fotografia del coach non porta ancora lo storico
    // delle serie: finché non glielo si passa il segnale legge «non lo so»,
    // che è la verità, invece di far finta che la forza tenga.
    StrengthTrend strength = const StrengthTrend.unknown(),
  }) {
    return OvertrainingLight(
      strength: strength,
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
        OvertrainingSignal.fallingStrength: _strengthReading(strength),
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

  static SignalReading _strengthReading(StrengthTrend trend) {
    final change = trend.change;
    if (change == null) {
      return SignalReading.unknown;
    }
    return change <= -strengthDropRatio
        ? SignalReading.fired
        : SignalReading.quiet;
  }
}
