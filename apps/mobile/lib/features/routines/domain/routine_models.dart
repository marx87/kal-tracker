import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';

/// I tre blocchi di una scheda. In Gym erano tre liste separate
/// (`warmupSteps`, `exerciseIds`, `finisherExerciseIds`); qui sono lo stesso
/// tipo di riga distinto dalla colonna `block`, e `name` è il valore su disco.
enum RoutineBlock {
  warmup('Riscaldamento'),
  main('Esercizi'),
  finisher('Finisher');

  const RoutineBlock(this.label);

  final String label;

  static RoutineBlock fromStorage(String? value) =>
      RoutineBlock.values.firstWhere(
        (block) => block.name == value,
        orElse: () => RoutineBlock.main,
      );
}

/// Valori predefiniti applicati quando una prescrizione lascia un campo
/// vuoto. Stanno qui e non sparsi nelle schermate perché sono la stessa
/// promessa fatta a Marco in due posti: l'etichetta «(predefinito)» e il
/// tempo stimato della scheda devono dire lo stesso numero.
abstract final class PrescriptionDefaults {
  static const sets = 3;
  static const reps = 8;
  static const durationSec = 30;
  static const restSec = 90;

  /// Durata di lavoro usata SOLO per stimare la lunghezza della sessione di
  /// un esercizio a ripetizioni: 40 secondi è la serie media di Gym.
  static const estimatedWorkSec = 40;
}

/// Serie / ripetizioni (o durata) / recupero di un esercizio dentro una
/// scheda. Ogni campo è facoltativo: nullo significa «usa il predefinito»,
/// ed è diverso da zero — un recupero 0 è una scelta (superserie).
class ExercisePrescription {
  const ExercisePrescription({
    this.sets,
    this.reps,
    this.repsMin,
    this.repsMax,
    this.durationSec,
    this.restSec,
  });

  static const empty = ExercisePrescription();

  final int? sets;
  final int? reps;

  /// I due estremi della doppia progressione, le colonne `presc_reps_min` e
  /// `presc_reps_max`. Restano FACOLTATIVI: le schede di oggi hanno solo
  /// [reps], e continuano a valere come numero fisso.
  ///
  /// [reps] non sparisce quando l'intervallo c'è, e non è un doppione: è il
  /// numero da cui la sessione parte (`routine_to_workout` prepara le serie
  /// da lì) e sta al fondo dell'intervallo.
  final int? repsMin;
  final int? repsMax;

  final int? durationSec;
  final int? restSec;

  bool get isEmpty =>
      sets == null &&
      reps == null &&
      repsMin == null &&
      repsMax == null &&
      durationSec == null &&
      restSec == null;

  /// L'intervallo, quando i due estremi ne fanno davvero uno.
  ///
  /// La regola non si riscrive qui: è [RepRange.resolve] a dire cosa conta
  /// come banda e cosa è un numero fisso travestito (un `12-12`), e due file
  /// che rispondono a quella domanda finirebbero per non dire lo stesso.
  RepRange? get range => RepRange.resolve(min: repsMin, max: repsMax);

  /// La stessa prescrizione con l'intervallo scritto sopra; [range] nullo lo
  /// toglie e lascia il numero fisso.
  ///
  /// [reps] segue il fondo dell'intervallo perché è da lì che la sessione
  /// riparte: lasciarlo a dieci con una banda `8-12` farebbe cominciare la
  /// seduta due ripetizioni sopra il pavimento appena scelto.
  ExercisePrescription withRange(RepRange? range) => ExercisePrescription(
    sets: sets,
    reps: range?.min ?? reps,
    repsMin: range?.min,
    repsMax: range?.max,
    durationSec: durationSec,
    restSec: restSec,
  );

  /// Riga leggibile: «3×10 · rec 75″» oppure «3×8-12 · rec 75″», e i
  /// predefiniti quando non è stata scritta. [mode] decide se il lavoro si
  /// conta in ripetizioni o in secondi.
  String summary(ExerciseTrackingMode mode) {
    final timed = mode.isTimed;
    if (isEmpty) {
      final work = timed
          ? '${PrescriptionDefaults.durationSec}″'
          : '${PrescriptionDefaults.reps}';
      return '${PrescriptionDefaults.sets}×$work · rec '
          '${PrescriptionDefaults.restSec}″ (predefinito)';
    }
    final setsText = sets ?? PrescriptionDefaults.sets;
    final work = timed
        ? '${durationSec ?? PrescriptionDefaults.durationSec}″'
        : (range?.label ?? '${reps ?? PrescriptionDefaults.reps}');
    final rest = switch (restSec) {
      null => 'rec predefinito',
      0 => 'senza recupero',
      final seconds => 'rec $seconds″',
    };
    return '$setsText×$work · $rest';
  }
}

/// Una riga di scheda già risolta sul catalogo: la scheda dice «esercizio
/// 4f2a…», questa dice «Panca piana, petto, peso × ripetizioni».
class RoutineExerciseRef {
  const RoutineExerciseRef({
    required this.exerciseRefId,
    required this.name,
    required this.muscleGroup,
    required this.trackingMode,
    required this.isMissing,
    this.inSupersetWithPrevious = false,
    this.warmupDurationSec,
    this.prescription = ExercisePrescription.empty,
  });

  /// L'id ORIGINALE dell'esercizio, mai nullo: è la chiave con cui la scheda
  /// lo cita, e resta leggibile anche quando l'esercizio non c'è più.
  final String exerciseRefId;

  /// Nome vivo se l'esercizio è ancora in catalogo, altrimenti lo scatto
  /// salvato al momento del salvataggio.
  final String name;

  final MuscleGroup muscleGroup;
  final ExerciseTrackingMode trackingMode;

  /// L'esercizio non è più nel catalogo: la riga si mostra lo stesso, con un
  /// avviso, perché cancellarla in silenzio cambierebbe la scheda alle spalle
  /// di Marco.
  final bool isMissing;

  final bool inSupersetWithPrevious;

  /// Durata del passo di riscaldamento. Ha valore solo nel blocco `warmup`,
  /// dove il database la pretende.
  final int? warmupDurationSec;

  final ExercisePrescription prescription;
}

/// Blocco a tempo dentro il blocco principale: finestra semiaperta
/// `[startIdx, endIdx)` sulle posizioni degli esercizi principali.
class RoutineIntervalSegment {
  const RoutineIntervalSegment({
    required this.segmentIndex,
    required this.startIdx,
    required this.endIdx,
    this.workSec = 40,
    this.restSec = 20,
    this.longRestSec = 0,
    this.rounds = 1,
  });

  final int segmentIndex;
  final int startIdx;
  final int endIdx;
  final int workSec;
  final int restSec;
  final int longRestSec;
  final int rounds;

  int get length => endIdx - startIdx;

  bool contains(int index) => index >= startIdx && index < endIdx;
}

/// Una scheda completa: intestazione, tre blocchi e blocchi a tempo.
class RoutineDetails {
  const RoutineDetails({
    required this.id,
    required this.name,
    required this.warmup,
    required this.main,
    required this.finisher,
    required this.segments,
    this.notes,
    this.isCircuit = false,
    this.workSec = 30,
    this.shortRestSec = 30,
    this.longRestSec = 60,
    this.rounds = 3,
    this.warmupWorkSec = 30,
    this.warmupRestSec = 15,
  });

  final String id;
  final String name;
  final String? notes;

  /// Tutta la scheda è un circuito a tempo. I sei parametri qui sotto valgono
  /// solo in quel caso, ma esistono sempre: sono la configurazione proposta.
  final bool isCircuit;
  final int workSec;
  final int shortRestSec;
  final int longRestSec;
  final int rounds;
  final int warmupWorkSec;
  final int warmupRestSec;

  final List<RoutineExerciseRef> warmup;
  final List<RoutineExerciseRef> main;
  final List<RoutineExerciseRef> finisher;
  final List<RoutineIntervalSegment> segments;

  /// Il blocco principale raggruppato: ogni gruppo è una sequenza di indici
  /// consecutivi legati fra loro. Un gruppo di due o più è una superserie
  /// (A1→A2, si riposa a fine giro), uno di uno è un esercizio normale.
  List<List<int>> get mainBlocks {
    final blocks = <List<int>>[];
    for (var index = 0; index < main.length; index++) {
      if (index > 0 &&
          main[index].inSupersetWithPrevious &&
          blocks.isNotEmpty) {
        blocks.last.add(index);
      } else {
        blocks.add([index]);
      }
    }
    return blocks;
  }

  int get supersetGroupCount =>
      mainBlocks.where((block) => block.length >= 2).length;

  RoutineIntervalSegment? segmentAt(int index) {
    for (final segment in segments) {
      if (segment.contains(index)) {
        return segment;
      }
    }
    return null;
  }

  /// Durata indicativa della sessione, in minuti. Serve a dare un ordine di
  /// grandezza («~50 min») nella lista: è una stima, non una promessa, e usa
  /// i predefiniti dove la prescrizione tace.
  int get estimatedMinutes {
    var seconds = 0;
    for (final step in warmup) {
      seconds += (step.warmupDurationSec ?? warmupWorkSec) + warmupRestSec;
    }
    if (isCircuit) {
      seconds += main.length * (workSec + shortRestSec) * rounds;
      if (rounds > 1) {
        seconds += (rounds - 1) * longRestSec;
      }
      for (final exercise in finisher) {
        seconds += _exerciseSeconds(exercise);
      }
    } else {
      for (var index = 0; index < main.length; index++) {
        final segment = segmentAt(index);
        if (segment != null) {
          // Dentro un blocco a tempo comanda il blocco, non la prescrizione.
          seconds += (segment.workSec + segment.restSec) * segment.rounds;
          continue;
        }
        seconds += _exerciseSeconds(main[index]);
      }
    }
    return (seconds / 60).round();
  }

  static int _exerciseSeconds(RoutineExerciseRef exercise) {
    final prescription = exercise.prescription;
    final sets = prescription.sets ?? PrescriptionDefaults.sets;
    final rest = prescription.restSec ?? PrescriptionDefaults.restSec;
    final work =
        prescription.durationSec ?? PrescriptionDefaults.estimatedWorkSec;
    return sets * (work + rest);
  }

  /// Versione compatta per la lista delle schede.
  RoutineSummary toSummary() => RoutineSummary(
    id: id,
    name: name,
    notes: notes,
    isCircuit: isCircuit,
    warmupCount: warmup.length,
    exerciseCount: main.length,
    finisherCount: finisher.length,
    supersetGroupCount: supersetGroupCount,
    segmentCount: segments.length,
    estimatedMinutes: estimatedMinutes,
    rounds: rounds,
    workSec: workSec,
    shortRestSec: shortRestSec,
  );
}

/// Quello che serve alla lista: numeri già contati, nessuna riga da scorrere.
class RoutineSummary {
  const RoutineSummary({
    required this.id,
    required this.name,
    required this.isCircuit,
    required this.warmupCount,
    required this.exerciseCount,
    required this.finisherCount,
    required this.supersetGroupCount,
    required this.segmentCount,
    required this.estimatedMinutes,
    required this.rounds,
    required this.workSec,
    required this.shortRestSec,
    this.notes,
  });

  final String id;
  final String name;
  final String? notes;
  final bool isCircuit;
  final int warmupCount;
  final int exerciseCount;
  final int finisherCount;
  final int supersetGroupCount;
  final int segmentCount;
  final int estimatedMinutes;
  final int rounds;
  final int workSec;
  final int shortRestSec;
}

/// Dove un esercizio viene usato. Serve alla sua scheda di dettaglio: prima
/// di cancellarlo, Marco deve sapere quali schede lo citano.
class RoutineUsage {
  const RoutineUsage({
    required this.routineId,
    required this.routineName,
    required this.block,
  });

  final String routineId;
  final String routineName;
  final RoutineBlock block;
}
