import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';

/// La scheda mentre viene modificata.
///
/// È immutabile: ogni operazione restituisce una bozza nuova. Serve perché il
/// riordino con le superserie non è «sposta un elemento»: sposta un GRUPPO, e
/// farlo su una lista mutabile condivisa con la UI lascia stati intermedi in
/// cui la prima riga risulta incatenata alla precedente — che il database
/// rifiuta (CHECK `in_superset_with_previous = 0 OR position > 0`).
class RoutineDraft {
  const RoutineDraft({
    required this.name,
    required this.warmup,
    required this.main,
    required this.finisher,
    required this.segments,
    this.id,
    this.notes = '',
    this.isCircuit = false,
    this.workSec = 30,
    this.shortRestSec = 30,
    this.longRestSec = 60,
    this.rounds = 3,
    this.warmupWorkSec = 30,
    this.warmupRestSec = 15,
  });

  /// Scheda nuova: nessun id, tutto vuoto, i tempi ai valori di Gym.
  factory RoutineDraft.empty() => const RoutineDraft(
    name: '',
    warmup: [],
    main: [],
    finisher: [],
    segments: [],
  );

  /// Bozza a partire da una scheda salvata. Le chiavi locali si generano qui
  /// una volta sola: sono l'identità con cui i blocchi a tempo continuano a
  /// riconoscere i propri esercizi mentre Marco li sposta.
  factory RoutineDraft.fromDetails(RoutineDetails details) {
    List<DraftExercise> convert(List<RoutineExerciseRef> rows, String prefix) =>
        [
          for (final (index, row) in rows.indexed)
            DraftExercise(
              key: '$prefix-$index',
              exerciseRefId: row.exerciseRefId,
              name: row.name,
              muscleGroup: row.muscleGroup,
              trackingMode: row.trackingMode,
              isMissing: row.isMissing,
              inSupersetWithPrevious: row.inSupersetWithPrevious,
              warmupDurationSec: row.warmupDurationSec,
              prescription: row.prescription,
            ),
        ];

    final main = convert(details.main, 'main');
    return RoutineDraft(
      id: details.id,
      name: details.name,
      notes: details.notes ?? '',
      isCircuit: details.isCircuit,
      workSec: details.workSec,
      shortRestSec: details.shortRestSec,
      longRestSec: details.longRestSec,
      rounds: details.rounds,
      warmupWorkSec: details.warmupWorkSec,
      warmupRestSec: details.warmupRestSec,
      warmup: convert(details.warmup, 'warmup'),
      main: main,
      finisher: convert(details.finisher, 'finisher'),
      segments: [
        for (final segment in details.segments)
          DraftSegment(
            memberKeys: [
              for (
                var index = segment.startIdx;
                index < segment.endIdx && index < main.length;
                index++
              )
                main[index].key,
            ],
            workSec: segment.workSec,
            restSec: segment.restSec,
            longRestSec: segment.longRestSec,
            rounds: segment.rounds,
          ),
      ],
    );
  }

  /// Nullo finché la scheda non è mai stata salvata.
  final String? id;

  final String name;
  final String notes;
  final bool isCircuit;
  final int workSec;
  final int shortRestSec;
  final int longRestSec;
  final int rounds;
  final int warmupWorkSec;
  final int warmupRestSec;

  final List<DraftExercise> warmup;
  final List<DraftExercise> main;
  final List<DraftExercise> finisher;
  final List<DraftSegment> segments;

  /// Una scheda senza nome o senza esercizi principali non si salva: sarebbe
  /// una riga che non si può né riconoscere né eseguire.
  bool get canSave => name.trim().isNotEmpty && main.isNotEmpty;

  List<DraftExercise> block(RoutineBlock which) => switch (which) {
    RoutineBlock.warmup => warmup,
    RoutineBlock.main => main,
    RoutineBlock.finisher => finisher,
  };

  /// Gli esercizi principali raggruppati per superserie: gruppo di 2+ =
  /// superserie, gruppo di 1 = esercizio singolo.
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

  /// Tutti gli id di esercizio già presenti nella scheda: il selettore li
  /// esclude, così lo stesso esercizio non finisce due volte nella stessa
  /// scheda (le prescrizioni sono per esercizio, non per riga).
  Set<String> get usedExerciseIds => {
    for (final list in [warmup, main, finisher])
      for (final exercise in list) exercise.exerciseRefId,
  };

  /// La finestra `[start, end)` occupata da un blocco a tempo, oppure null se
  /// i suoi esercizi non sono più consecutivi (o non ci sono più).
  ({int start, int end})? rangeOf(DraftSegment segment) {
    final positions = <int>[];
    for (final key in segment.memberKeys) {
      final index = main.indexWhere((exercise) => exercise.key == key);
      if (index < 0) {
        return null;
      }
      positions.add(index);
    }
    if (positions.isEmpty) {
      return null;
    }
    positions.sort();
    for (var i = 1; i < positions.length; i++) {
      if (positions[i] != positions[i - 1] + 1) {
        return null;
      }
    }
    return (start: positions.first, end: positions.last + 1);
  }

  /// I blocchi a tempo ancora validi, in ordine di comparsa. È questa la
  /// lista che si salva: `segment_index` deve restare densa da 0.
  List<DraftSegment> get resolvedSegments {
    final valid = <({DraftSegment segment, int start})>[];
    for (final segment in segments) {
      final range = rangeOf(segment);
      if (range != null) {
        valid.add((segment: segment, start: range.start));
      }
    }
    valid.sort((a, b) => a.start.compareTo(b.start));
    return [for (final entry in valid) entry.segment];
  }

  // ─── Operazioni sul blocco principale ────────────────────────────────
  // Passano tutte per i gruppi: si smonta in blocchi, si opera sui blocchi,
  // si rimonta. Così la catena delle superserie sopravvive al riordino e la
  // prima riga non resta mai agganciata al nulla.

  /// Sposta un gruppo. [newIndex] è la posizione di destinazione NELLA lista
  /// già privata dell'elemento spostato: è la convenzione di
  /// `ReorderableListView.onReorderItem`, e tenerla identica evita la
  /// correzione «-1» sparsa a mano nei chiamanti.
  RoutineDraft reorderMainBlocks(int oldIndex, int newIndex) {
    final blocks = _idBlocks();
    if (oldIndex < 0 || oldIndex >= blocks.length) {
      return this;
    }
    final moved = blocks.removeAt(oldIndex);
    blocks.insert(newIndex.clamp(0, blocks.length), moved);
    return _withMain(_flatten(blocks));
  }

  /// Unisce il blocco [blockIndex] al successivo: diventano una superserie.
  RoutineDraft mergeBlockWithNext(int blockIndex) {
    final blocks = _idBlocks();
    if (blockIndex < 0 || blockIndex >= blocks.length - 1) {
      return this;
    }
    blocks[blockIndex] = [...blocks[blockIndex], ...blocks[blockIndex + 1]];
    blocks.removeAt(blockIndex + 1);
    return _withMain(_flatten(blocks));
  }

  /// Scioglie una superserie: gli esercizi restano dov'erano, separati.
  RoutineDraft ungroupBlock(int blockIndex) {
    final blocks = _idBlocks();
    if (blockIndex < 0 || blockIndex >= blocks.length) {
      return this;
    }
    final group = blocks.removeAt(blockIndex);
    blocks.insertAll(blockIndex, [
      for (final exercise in group) [exercise],
    ]);
    return _withMain(_flatten(blocks));
  }

  // ─── Operazioni comuni ai tre blocchi ────────────────────────────────

  RoutineDraft addExercises(RoutineBlock which, List<DraftExercise> items) {
    if (items.isEmpty) {
      return this;
    }
    final updated = [...block(which), ...items];
    return switch (which) {
      // In coda al blocco principale un esercizio nuovo è sempre singolo:
      // agganciarlo alla superserie precedente sarebbe una decisione presa
      // per conto di Marco.
      RoutineBlock.main => _withMain([
        for (final (index, exercise) in updated.indexed)
          index >= main.length
              ? exercise.copyWith(inSupersetWithPrevious: false)
              : exercise,
      ]),
      RoutineBlock.warmup => copyWith(warmup: updated),
      RoutineBlock.finisher => copyWith(finisher: updated),
    };
  }

  RoutineDraft removeAt(RoutineBlock which, int index) {
    final list = [...block(which)];
    if (index < 0 || index >= list.length) {
      return this;
    }
    final removed = list.removeAt(index);
    if (which == RoutineBlock.warmup) {
      return copyWith(warmup: list);
    }
    if (which == RoutineBlock.finisher) {
      return copyWith(finisher: list);
    }
    // Un blocco a tempo che conteneva l'esercizio non si scioglie tutto:
    // perde quella riga e continua a valere per le altre. Sciogliere l'intero
    // blocco per un esercizio tolto sarebbe una punizione sproporzionata.
    final pruned = [
      for (final segment in segments)
        if (segment.memberKeys.contains(removed.key))
          segment.copyWith(
            memberKeys: [
              for (final key in segment.memberKeys)
                if (key != removed.key) key,
            ],
          )
        else
          segment,
    ];
    // Rimontare dai gruppi ripulisce la catena: se sparisce il capofila,
    // il secondo esercizio smette di essere «incatenato al precedente».
    return copyWith(segments: pruned)._withMain(_flatten(_blocksOf(list)));
  }

  /// Riordino semplice, per riscaldamento e finisher: là non ci sono catene
  /// da preservare, si sposta una riga alla volta.
  RoutineDraft reorderSimple(RoutineBlock which, int oldIndex, int newIndex) {
    if (which == RoutineBlock.main) {
      return reorderMainBlocks(oldIndex, newIndex);
    }
    final list = [...block(which)];
    if (oldIndex < 0 || oldIndex >= list.length) {
      return this;
    }
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), moved);
    return which == RoutineBlock.warmup
        ? copyWith(warmup: list)
        : copyWith(finisher: list);
  }

  RoutineDraft replaceAt(
    RoutineBlock which,
    int index,
    DraftExercise Function(DraftExercise current) update,
  ) {
    final list = [...block(which)];
    if (index < 0 || index >= list.length) {
      return this;
    }
    list[index] = update(list[index]);
    return switch (which) {
      RoutineBlock.main => _withMain(list),
      RoutineBlock.warmup => copyWith(warmup: list),
      RoutineBlock.finisher => copyWith(finisher: list),
    };
  }

  // ─── Blocchi a tempo ─────────────────────────────────────────────────

  /// Aggiunge o sostituisce un blocco a tempo. I blocchi che si sovrappongono
  /// a quello nuovo vengono sciolti: due finestre sullo stesso esercizio
  /// renderebbero ambiguo con quale tempo eseguirlo.
  RoutineDraft upsertSegment(DraftSegment segment, {DraftSegment? replacing}) {
    final keys = segment.memberKeys.toSet();
    final kept = [
      for (final existing in segments)
        if (!identical(existing, replacing) &&
            !existing.memberKeys.any(keys.contains))
          existing,
    ];
    return copyWith(segments: [...kept, segment]);
  }

  RoutineDraft removeSegment(DraftSegment segment) => copyWith(
    segments: [
      for (final existing in segments)
        if (!identical(existing, segment)) existing,
    ],
  );

  // ─── Anteprima ───────────────────────────────────────────────────────

  /// La bozza letta come scheda salvata: serve alla stima dei minuti e a
  /// tutto ciò che sa già ragionare su [RoutineDetails].
  RoutineDetails preview() {
    List<RoutineExerciseRef> convert(List<DraftExercise> rows) => [
      for (final row in rows) row.toRef(),
    ];
    final resolved = resolvedSegments;
    return RoutineDetails(
      id: id ?? '',
      name: name,
      notes: notes.trim().isEmpty ? null : notes.trim(),
      isCircuit: isCircuit,
      workSec: workSec,
      shortRestSec: shortRestSec,
      longRestSec: longRestSec,
      rounds: rounds,
      warmupWorkSec: warmupWorkSec,
      warmupRestSec: warmupRestSec,
      warmup: convert(warmup),
      main: convert(main),
      finisher: convert(finisher),
      segments: [
        for (final (index, segment) in resolved.indexed)
          if (rangeOf(segment) case final range?)
            RoutineIntervalSegment(
              segmentIndex: index,
              startIdx: range.start,
              endIdx: range.end,
              workSec: segment.workSec,
              restSec: segment.restSec,
              longRestSec: segment.longRestSec,
              rounds: segment.rounds,
            ),
      ],
    );
  }

  RoutineDraft copyWith({
    String? name,
    String? notes,
    bool? isCircuit,
    int? workSec,
    int? shortRestSec,
    int? longRestSec,
    int? rounds,
    int? warmupWorkSec,
    int? warmupRestSec,
    List<DraftExercise>? warmup,
    List<DraftExercise>? main,
    List<DraftExercise>? finisher,
    List<DraftSegment>? segments,
  }) => RoutineDraft(
    id: id,
    name: name ?? this.name,
    notes: notes ?? this.notes,
    isCircuit: isCircuit ?? this.isCircuit,
    workSec: workSec ?? this.workSec,
    shortRestSec: shortRestSec ?? this.shortRestSec,
    longRestSec: longRestSec ?? this.longRestSec,
    rounds: rounds ?? this.rounds,
    warmupWorkSec: warmupWorkSec ?? this.warmupWorkSec,
    warmupRestSec: warmupRestSec ?? this.warmupRestSec,
    warmup: warmup ?? this.warmup,
    main: main ?? this.main,
    finisher: finisher ?? this.finisher,
    segments: segments ?? this.segments,
  );

  /// Ogni scrittura del blocco principale passa di qui: i blocchi a tempo
  /// rimasti senza esercizi, o con esercizi non più consecutivi, cadono
  /// invece di salvare una finestra che punta agli esercizi sbagliati.
  RoutineDraft _withMain(List<DraftExercise> updated) {
    final next = copyWith(main: updated);
    return next.copyWith(segments: next.resolvedSegments);
  }

  List<List<DraftExercise>> _idBlocks() => _blocksOf(main);

  static List<List<DraftExercise>> _blocksOf(List<DraftExercise> list) {
    final blocks = <List<DraftExercise>>[];
    for (var index = 0; index < list.length; index++) {
      if (index > 0 &&
          list[index].inSupersetWithPrevious &&
          blocks.isNotEmpty) {
        blocks.last.add(list[index]);
      } else {
        blocks.add([list[index]]);
      }
    }
    return blocks;
  }

  /// Inverso di [_blocksOf]: riscrive la catena in modo che il primo di ogni
  /// gruppo apra e gli altri seguano.
  static List<DraftExercise> _flatten(List<List<DraftExercise>> blocks) => [
    for (final group in blocks)
      for (final (index, exercise) in group.indexed)
        exercise.copyWith(inSupersetWithPrevious: index > 0),
  ];
}

/// Una riga della bozza. [key] è l'identità locale: due righe possono citare
/// lo stesso esercizio in blocchi diversi, e i blocchi a tempo devono poterle
/// distinguere anche dopo un riordino.
class DraftExercise {
  const DraftExercise({
    required this.key,
    required this.exerciseRefId,
    required this.name,
    required this.muscleGroup,
    required this.trackingMode,
    this.isMissing = false,
    this.inSupersetWithPrevious = false,
    this.warmupDurationSec,
    this.prescription = ExercisePrescription.empty,
  });

  /// Riga costruita da un esercizio del catalogo appena scelto.
  factory DraftExercise.fromExercise(
    Exercise exercise, {
    required String key,
    int? warmupDurationSec,
  }) => DraftExercise(
    key: key,
    exerciseRefId: exercise.id,
    name: exercise.name,
    muscleGroup: exercise.muscleGroup,
    trackingMode: exercise.trackingMode,
    warmupDurationSec: warmupDurationSec,
    prescription: exercise.defaultRestSec == null
        ? ExercisePrescription.empty
        : ExercisePrescription(restSec: exercise.defaultRestSec),
  );

  final String key;
  final String exerciseRefId;
  final String name;
  final MuscleGroup muscleGroup;
  final ExerciseTrackingMode trackingMode;
  final bool isMissing;
  final bool inSupersetWithPrevious;
  final int? warmupDurationSec;
  final ExercisePrescription prescription;

  RoutineExerciseRef toRef() => RoutineExerciseRef(
    exerciseRefId: exerciseRefId,
    name: name,
    muscleGroup: muscleGroup,
    trackingMode: trackingMode,
    isMissing: isMissing,
    inSupersetWithPrevious: inSupersetWithPrevious,
    warmupDurationSec: warmupDurationSec,
    prescription: prescription,
  );

  DraftExercise copyWith({
    bool? inSupersetWithPrevious,
    int? warmupDurationSec,
    ExercisePrescription? prescription,
  }) => DraftExercise(
    key: key,
    exerciseRefId: exerciseRefId,
    name: name,
    muscleGroup: muscleGroup,
    trackingMode: trackingMode,
    isMissing: isMissing,
    inSupersetWithPrevious:
        inSupersetWithPrevious ?? this.inSupersetWithPrevious,
    warmupDurationSec: warmupDurationSec ?? this.warmupDurationSec,
    prescription: prescription ?? this.prescription,
  );
}

/// Un blocco a tempo in bozza. Non tiene indici ma le CHIAVI degli esercizi
/// che contiene: gli indici cambiano a ogni riordino, le chiavi no.
class DraftSegment {
  const DraftSegment({
    required this.memberKeys,
    this.workSec = 40,
    this.restSec = 20,
    this.longRestSec = 0,
    this.rounds = 1,
  });

  final List<String> memberKeys;
  final int workSec;
  final int restSec;
  final int longRestSec;
  final int rounds;

  DraftSegment copyWith({
    List<String>? memberKeys,
    int? workSec,
    int? restSec,
    int? longRestSec,
    int? rounds,
  }) => DraftSegment(
    memberKeys: memberKeys ?? this.memberKeys,
    workSec: workSec ?? this.workSec,
    restSec: restSec ?? this.restSec,
    longRestSec: longRestSec ?? this.longRestSec,
    rounds: rounds ?? this.rounds,
  );
}
