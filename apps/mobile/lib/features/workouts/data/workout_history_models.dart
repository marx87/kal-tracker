/// I modelli di sola lettura dello storico allenamenti.
///
/// Sono la forma in cui Gym Tracker registrava le sessioni, riletta dalle
/// tabelle di Kal. Qui non si corregge e non si ricalcola niente che il dato
/// non dica già: le due regole delicate — la durata e il volume — restano
/// quelle di Gym parola per parola, perché lo storico deve continuare a
/// mostrare gli stessi numeri che Marco ha guardato per un anno.
///
/// Nessun import di Flutter: le etichette e le icone stanno nella
/// presentazione, qui c'è solo la forma dei dati.
library;

/// Come Gym misurava una serie. Il nome è il `.name` dell'enum originale,
/// che è la stringa davvero persistita in `workout_exercises.tracking_mode`.
enum WorkoutTrackingMode {
  weightReps,
  bodyweightReps,
  timeOnly,
  timed,
  distanceTime;

  /// Il fallback è `weightReps` come in Gym: una modalità che non riconosco
  /// non deve far sparire la serie dallo schermo.
  static WorkoutTrackingMode fromName(String? name) => values.firstWhere(
    (mode) => mode.name == name,
    orElse: () => WorkoutTrackingMode.weightReps,
  );
}

/// I quattro blocchi esclusivi di una sessione. In tabella sono tre booleani
/// (`is_warmup`, `is_finisher`, `is_cooldown`) con un CHECK che ne ammette al
/// massimo uno: qui tornano a essere l'unica cosa che sono, un blocco solo.
enum WorkoutBlock { warmup, main, finisher, cooldown }

/// Il tipo di sessione, dedotto dalla sua forma. È la regola di `_kindOf`
/// portata da Gym: serve a dare un'icona riconoscibile alla scheda, mai a
/// dire da sola un'informazione (accanto c'è sempre la parola).
enum WorkoutKind { strength, hiit, cardio, mobility, manual, mixed }

/// Una serie registrata.
class WorkoutSetEntry {
  const WorkoutSetEntry({
    required this.position,
    this.weightKg,
    this.reps,
    this.durationSec,
    this.distanceM,
    this.rpe,
    this.isWarmup = false,
    this.completed = false,
  });

  /// Numero di serie, denso da 0: in Gym la posizione nella lista ERA
  /// l'identità della serie.
  final int position;

  final double? weightKg;
  final int? reps;
  final int? durationSec;
  final double? distanceM;
  final int? rpe;
  final bool isWarmup;
  final bool completed;

  /// Volume = kg × ripetizioni, zero per le serie di riscaldamento.
  ///
  /// Regola di Gym invariata: NON richiede che la serie sia completata, e i
  /// campi mancanti valgono zero. Aggiungere qui il filtro «solo completate»
  /// abbasserebbe di colpo tutti i totali storici.
  double get volume => isWarmup ? 0 : (weightKg ?? 0) * (reps ?? 0);
}

/// Una riga della sessione: un esercizio con le sue serie.
class WorkoutExerciseEntry {
  const WorkoutExerciseEntry({
    required this.id,
    required this.position,
    required this.name,
    required this.trackingMode,
    required this.block,
    required this.sets,
    this.muscleGroup,
    this.restSeconds,
    this.exerciseDeleted = false,
    this.inSupersetWithPrevious = false,
    this.intervalSegmentIndex,
  });

  final String id;

  /// Posizione nella sessione. L'ordine è quello di Gym: prima le righe
  /// base, poi quelle appese dai blocchi a tempo.
  final int position;

  /// Il nome congelato al momento della sessione: sopravvive alle rinomine
  /// e agli esercizi cancellati.
  final String name;

  final WorkoutTrackingMode trackingMode;
  final WorkoutBlock block;
  final List<WorkoutSetEntry> sets;
  final String? muscleGroup;
  final int? restSeconds;

  /// L'esercizio non esiste più in catalogo (la FK è diventata NULL): il
  /// nome che vedi è quello storico, non un errore.
  final bool exerciseDeleted;

  /// «Incatenato alla riga precedente»: è la superserie di Gym, dove
  /// `supersetIndices` conteneva l'indice i per dire «i segue i-1».
  final bool inSupersetWithPrevious;

  /// Riga appesa da un blocco a tempo (circuito). Null per le righe base.
  final int? intervalSegmentIndex;

  double get volume => sets.fold<double>(0, (total, set) => total + set.volume);

  int get completedSets => sets.where((set) => set.completed).length;

  bool get isEmpty => sets.isEmpty;
}

/// I marcatori di un blocco a tempo. Completato e parziale NON sono
/// esclusivi: in Gym erano due liste indipendenti e lo stesso indice poteva
/// stare in entrambe.
class WorkoutCircuitMarker {
  const WorkoutCircuitMarker({
    required this.segmentIndex,
    required this.completed,
    required this.partial,
  });

  final int segmentIndex;
  final bool completed;
  final bool partial;
}

/// La sessione come si legge in lista: intestazione e totali, senza le serie.
class WorkoutSummary {
  const WorkoutSummary({
    required this.id,
    required this.startedAt,
    required this.exerciseCount,
    required this.setCount,
    required this.totalVolume,
    this.endedAt,
    this.accumulatedPauseSeconds = 0,
    this.finalDurationSeconds,
    this.durationSuspect = false,
    this.routineName,
    this.routineDeleted = false,
    this.totalKcal,
    this.notes,
    this.mood,
    this.rpe,
    this.satisfaction,
    this.feedbackNotes,
    this.xpEarned,
    this.hasTimedWork = false,
    this.hasStrengthWork = false,
    this.hasCircuitRows = false,
  });

  final String id;

  /// Istante UTC: la conversione a ora di Roma è della presentazione.
  final DateTime startedAt;
  final DateTime? endedAt;
  final int accumulatedPauseSeconds;
  final int? finalDurationSeconds;

  /// La sottrazione dell'orologio non è credibile (l'app è rimasta aperta).
  /// Il dato resta grezzo: questo flag dice soltanto di non fidarsene.
  final bool durationSuspect;

  /// Il nome della scheda al momento della sessione. Resta anche quando la
  /// scheda è stata cancellata.
  final String? routineName;

  /// La scheda citata non esiste più. Nove sessioni sono in questo stato:
  /// il nome storico è l'unica cosa vera che si può mostrare.
  final bool routineDeleted;

  final int exerciseCount;
  final int setCount;
  final double totalVolume;
  final double? totalKcal;
  final String? notes;
  final int? mood;
  final int? rpe;
  final int? satisfaction;
  final String? feedbackNotes;
  final int? xpEarned;

  /// Esiste almeno una serie a tempo senza peso fuori da riscaldamento e
  /// defaticamento (il segnale di HIIT in Gym).
  final bool hasTimedWork;

  /// Esiste almeno una serie con un peso vero fuori dal defaticamento.
  final bool hasStrengthWork;

  /// Esiste almeno una riga appesa da un blocco a tempo.
  final bool hasCircuitRows;

  bool get inProgress => endedAt == null;

  /// Sessione senza esercizi: registrata a posteriori dal modulo «sessione
  /// esterna» di Gym. Otto sessioni sono così, e non sono un errore.
  bool get withoutExercises => exerciseCount == 0;

  /// La durata come la leggeva Gym, invariata.
  ///
  /// Il tetto di 24 ore è una regola di LETTURA e vale SOLO sulla durata
  /// registrata, esattamente come nel getter originale: sul ramo
  /// dell'orologio non c'era e non lo aggiungo, altrimenti una sessione
  /// dimenticata aperta 536 ore verrebbe rettificata in silenzio.
  Duration? get duration {
    final ended = endedAt;
    if (ended == null) {
      return null;
    }
    final registered = finalDurationSeconds;
    if (registered != null) {
      return Duration(seconds: registered.clamp(0, 24 * 60 * 60));
    }
    final active =
        ended.difference(startedAt) -
        Duration(seconds: accumulatedPauseSeconds);
    return active.isNegative ? Duration.zero : active;
  }

  /// Quanto è passato fra inizio e fine sull'orologio, pause comprese.
  /// Serve a raccontare l'anomalia, non a sostituire [duration].
  Duration? get wallClockDuration => endedAt?.difference(startedAt);

  /// Quanto Gym aveva registrato come durata attiva, se lo aveva registrato.
  Duration? get registeredDuration => finalDurationSeconds == null
      ? null
      : Duration(seconds: finalDurationSeconds!);

  bool get hasFeedback =>
      mood != null ||
      rpe != null ||
      satisfaction != null ||
      (feedbackNotes != null && feedbackNotes!.isNotEmpty);

  /// Il tipo di sessione, con la regola di `_kindOf` di Gym.
  ///
  /// L'unica aggiunta è la prima riga: una sessione senza esercizi è per
  /// costruzione una sessione registrata a posteriori, e in Gym lo si
  /// deduceva solo dalle note (che però l'utente poteva riscrivere).
  WorkoutKind get kind {
    if (withoutExercises) {
      return WorkoutKind.manual;
    }
    final name = (routineName ?? '').toLowerCase();
    final note = (notes ?? '').toLowerCase();
    if (note.contains('manuale') || note.contains('esterna')) {
      return WorkoutKind.manual;
    }
    if (name.contains('hiit') ||
        name.contains('tabata') ||
        name.contains('emom') ||
        name.contains('circuit')) {
      return WorkoutKind.hiit;
    }
    if (name.contains('cardio') ||
        name.contains('corsa') ||
        name.contains('run') ||
        name.contains('bike')) {
      return WorkoutKind.cardio;
    }
    if (name.contains('yoga') ||
        name.contains('stretch') ||
        name.contains('mobilità') ||
        name.contains('mobilita')) {
      return WorkoutKind.mobility;
    }
    if (hasTimedWork && hasStrengthWork) {
      return WorkoutKind.mixed;
    }
    if (hasTimedWork) {
      return WorkoutKind.hiit;
    }
    if (hasStrengthWork) {
      return WorkoutKind.strength;
    }
    return WorkoutKind.mixed;
  }
}

/// La sessione aperta: intestazione, righe e feedback.
class WorkoutDetail {
  const WorkoutDetail({
    required this.summary,
    required this.exercises,
    this.painPoints = const [],
    this.circuitMarkers = const [],
  });

  final WorkoutSummary summary;

  /// In ordine di posizione, cioè nell'ordine in cui Gym le leggeva.
  final List<WorkoutExerciseEntry> exercises;

  final List<String> painPoints;
  final List<WorkoutCircuitMarker> circuitMarkers;

  WorkoutCircuitMarker? markerFor(int segmentIndex) {
    for (final marker in circuitMarkers) {
      if (marker.segmentIndex == segmentIndex) {
        return marker;
      }
    }
    return null;
  }
}

/// Un gruppo di esercizi consecutivi. Con più di un esercizio è una
/// superserie: si passa da uno all'altro senza riposo.
class WorkoutExerciseGroup {
  const WorkoutExerciseGroup(this.exercises);

  final List<WorkoutExerciseEntry> exercises;

  bool get isSuperset => exercises.length > 1;

  double get volume =>
      exercises.fold<double>(0, (total, entry) => total + entry.volume);
}

/// Una sezione del dettaglio: un blocco della sessione oppure un blocco a
/// tempo (circuito), che in Gym viveva in una lista sua.
class WorkoutSection {
  const WorkoutSection({
    required this.block,
    required this.groups,
    this.segmentIndex,
    this.marker,
  });

  final WorkoutBlock block;

  /// Presente solo per i circuiti: è l'indice del blocco a tempo, la chiave
  /// con cui la sessione ne registrava il completamento.
  final int? segmentIndex;

  final WorkoutCircuitMarker? marker;
  final List<WorkoutExerciseGroup> groups;

  bool get isCircuit => segmentIndex != null;

  int get exerciseCount =>
      groups.fold<int>(0, (total, group) => total + group.exercises.length);
}

/// Riorganizza le righe di una sessione come Gym le registrava: prima i
/// blocchi (riscaldamento, allenamento, finisher, defaticamento), poi le
/// catene di superserie dentro ciascuno.
///
/// Le righe con [WorkoutExerciseEntry.intervalSegmentIndex] non nullo NON
/// finiscono nel blocco che i loro flag suggerirebbero: sono le righe appese
/// da un blocco a tempo, in Firestore stavano in una lista separata
/// append-only, e mescolarle alle altre farebbe sembrare parte
/// dell'allenamento normale dei giri di circuito.
List<WorkoutSection> buildWorkoutSections(WorkoutDetail detail) {
  final byBlock = <WorkoutBlock, List<WorkoutExerciseEntry>>{};
  final bySegment = <int, List<WorkoutExerciseEntry>>{};

  for (final entry in detail.exercises) {
    final segment = entry.intervalSegmentIndex;
    if (segment != null) {
      (bySegment[segment] ??= <WorkoutExerciseEntry>[]).add(entry);
    } else {
      (byBlock[entry.block] ??= <WorkoutExerciseEntry>[]).add(entry);
    }
  }

  final sections = <WorkoutSection>[];

  void addBlock(WorkoutBlock block) {
    final entries = byBlock[block];
    if (entries == null || entries.isEmpty) {
      return;
    }
    sections.add(
      WorkoutSection(block: block, groups: _groupBySuperset(entries)),
    );
  }

  addBlock(WorkoutBlock.warmup);
  addBlock(WorkoutBlock.main);

  final segmentIndices = bySegment.keys.toList()..sort();
  for (final index in segmentIndices) {
    sections.add(
      WorkoutSection(
        block: WorkoutBlock.main,
        segmentIndex: index,
        marker: detail.markerFor(index),
        groups: _groupBySuperset(bySegment[index]!),
      ),
    );
  }

  addBlock(WorkoutBlock.finisher);
  addBlock(WorkoutBlock.cooldown);

  return sections;
}

/// Incatena le righe consecutive marcate come superserie.
///
/// Il flag significa «sono legato alla riga in posizione-1»: se quella riga
/// è finita in un'altra sezione (capita alle righe di circuito) la catena si
/// spezza e qui deve iniziare un gruppo nuovo, altrimenti mostrerei una
/// superserie fra esercizi che nella sessione non si sono mai toccati.
List<WorkoutExerciseGroup> _groupBySuperset(List<WorkoutExerciseEntry> rows) {
  final groups = <List<WorkoutExerciseEntry>>[];
  for (final entry in rows) {
    final open = groups.isEmpty ? null : groups.last;
    final previous = open?.last;
    final chained =
        entry.inSupersetWithPrevious &&
        previous != null &&
        previous.position == entry.position - 1;
    if (chained) {
      open!.add(entry);
    } else {
      groups.add(<WorkoutExerciseEntry>[entry]);
    }
  }
  return groups.map(WorkoutExerciseGroup.new).toList(growable: false);
}
