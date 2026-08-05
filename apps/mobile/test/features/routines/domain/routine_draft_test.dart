import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';

DraftExercise _exercise(
  String key, {
  bool chained = false,
  ExerciseTrackingMode mode = ExerciseTrackingMode.weightReps,
  ExercisePrescription prescription = ExercisePrescription.empty,
}) => DraftExercise(
  key: key,
  exerciseRefId: 'ex-$key',
  name: key.toUpperCase(),
  muscleGroup: MuscleGroup.petto,
  trackingMode: mode,
  inSupersetWithPrevious: chained,
  prescription: prescription,
);

RoutineDraft _draft({
  List<DraftExercise>? main,
  List<DraftSegment> segments = const [],
}) => RoutineDraft(
  id: 'routine-1',
  name: 'Scheda',
  warmup: const [],
  main: main ?? [_exercise('a'), _exercise('b'), _exercise('c')],
  finisher: const [],
  segments: segments,
);

/// Le chiavi degli esercizi principali, con «+» davanti a chi è incatenato al
/// precedente: rende leggibile in una riga sia l'ordine sia le superserie.
List<String> _shape(RoutineDraft draft) => [
  for (final exercise in draft.main)
    exercise.inSupersetWithPrevious ? '+${exercise.key}' : exercise.key,
];

void main() {
  group('superserie', () {
    test('unire due blocchi incatena il secondo esercizio', () {
      final draft = _draft().mergeBlockWithNext(0);

      expect(_shape(draft), ['a', '+b', 'c']);
      expect(draft.mainBlocks, [
        [0, 1],
        [2],
      ]);
    });

    test('sciogliere una superserie lascia gli esercizi al loro posto', () {
      final draft = _draft().mergeBlockWithNext(0).ungroupBlock(0);

      expect(_shape(draft), ['a', 'b', 'c']);
      expect(draft.mainBlocks, [
        [0],
        [1],
        [2],
      ]);
    });

    test('il riordino sposta il gruppo intero, non la singola riga', () {
      // A+B è una superserie, C sta da solo: portare C in testa deve
      // trascinare la coppia sotto senza spezzarla.
      final draft = _draft().mergeBlockWithNext(0).reorderMainBlocks(1, 0);

      expect(_shape(draft), ['c', 'a', '+b']);
    });

    test('togliere il capofila promuove il secondo invece di lasciarlo '
        'agganciato al nulla', () {
      // È il caso che il database rifiuta: la posizione 0 non può avere
      // `in_superset_with_previous`.
      final draft = _draft()
          .mergeBlockWithNext(0)
          .removeAt(RoutineBlock.main, 0);

      expect(_shape(draft), ['b', 'c']);
      expect(draft.main.first.inSupersetWithPrevious, isFalse);
    });

    test(
      'un esercizio aggiunto in coda non eredita la superserie di prima',
      () {
        final draft = _draft().mergeBlockWithNext(0).addExercises(
          RoutineBlock.main,
          [_exercise('d', chained: true)],
        );

        expect(_shape(draft), ['a', '+b', 'c', 'd']);
      },
    );
  });

  group('blocchi a tempo', () {
    RoutineDraft withSegment() => _draft(
      segments: const [
        DraftSegment(
          memberKeys: ['b', 'c'],
          workSec: 45,
          restSec: 15,
          rounds: 3,
        ),
      ],
    );

    test('la finestra segue gli esercizi quando cambiano posizione', () {
      final draft = withSegment().reorderMainBlocks(0, 2);

      expect(_shape(draft), ['b', 'c', 'a']);
      expect(draft.rangeOf(draft.segments.single), (start: 0, end: 2));
    });

    test('si scioglie quando i suoi esercizi non sono più consecutivi', () {
      // A finisce in mezzo a B e C: la finestra non esiste più, e tenerla
      // significherebbe salvare un intervallo che comprende A.
      final draft = withSegment().reorderMainBlocks(0, 1);

      expect(_shape(draft), ['b', 'a', 'c']);
      expect(draft.segments, isEmpty);
    });

    test(
      'togliere un esercizio lo toglie dal blocco, non scioglie il blocco',
      () {
        final draft = withSegment().removeAt(RoutineBlock.main, 2);

        expect(_shape(draft), ['a', 'b']);
        expect(draft.segments.single.memberKeys, ['b']);
        expect(draft.rangeOf(draft.segments.single), (start: 1, end: 2));
      },
    );

    test('un blocco nuovo scioglie quelli che si sovrappongono', () {
      final draft = withSegment().upsertSegment(
        const DraftSegment(memberKeys: ['a', 'b']),
      );

      expect(draft.segments, hasLength(1));
      expect(draft.segments.single.memberKeys, ['a', 'b']);
    });

    test('salvati sono numerati densi da zero e in ordine di comparsa', () {
      final draft = _draft(
        main: [_exercise('a'), _exercise('b'), _exercise('c'), _exercise('d')],
        segments: const [
          DraftSegment(memberKeys: ['c', 'd']),
          DraftSegment(memberKeys: ['a']),
        ],
      );

      final segments = draft.preview().segments;

      expect(segments.map((segment) => segment.segmentIndex), [0, 1]);
      expect(segments.first.startIdx, 0);
      expect(segments.first.endIdx, 1);
      expect(segments.last.startIdx, 2);
      expect(segments.last.endIdx, 4);
    });
  });

  group('anteprima', () {
    test('la stima usa le prescrizioni scritte e i predefiniti sul resto', () {
      final draft = _draft(
        main: [
          _exercise(
            'a',
            prescription: const ExercisePrescription(
              sets: 2,
              reps: 10,
              restSec: 60,
            ),
          ),
          _exercise('b'),
        ],
      );

      // a: 2 serie × (40″ stimati + 60″ di recupero) = 200″.
      // b: predefiniti, 3 × (40 + 90) = 390″. Totale 590″ ≈ 10 minuti.
      expect(draft.preview().estimatedMinutes, 10);
    });

    test('dentro un blocco a tempo comanda il blocco, non la prescrizione', () {
      final draft = _draft(
        main: [_exercise('a'), _exercise('b')],
        segments: const [
          DraftSegment(
            memberKeys: ['a', 'b'],
            workSec: 40,
            restSec: 20,
            rounds: 3,
          ),
        ],
      );

      // Due esercizi × (40 + 20) × 3 giri = 360″ = 6 minuti.
      expect(draft.preview().estimatedMinutes, 6);
    });
  });

  group('andata e ritorno con la scheda salvata', () {
    test('una scheda letta e riletta conserva catene, tempi e finestre', () {
      final original = RoutineDetails(
        id: 'r1',
        name: 'Push',
        notes: 'Con calma',
        warmup: const [
          RoutineExerciseRef(
            exerciseRefId: 'w1',
            name: 'Cat-Cow',
            muscleGroup: MuscleGroup.mobilita,
            trackingMode: ExerciseTrackingMode.timed,
            isMissing: false,
            warmupDurationSec: 45,
          ),
        ],
        main: const [
          RoutineExerciseRef(
            exerciseRefId: 'e1',
            name: 'Panca',
            muscleGroup: MuscleGroup.petto,
            trackingMode: ExerciseTrackingMode.weightReps,
            isMissing: false,
            prescription: ExercisePrescription(sets: 4, reps: 8, restSec: 90),
          ),
          RoutineExerciseRef(
            exerciseRefId: 'e2',
            name: 'Croci',
            muscleGroup: MuscleGroup.petto,
            trackingMode: ExerciseTrackingMode.weightReps,
            isMissing: false,
            inSupersetWithPrevious: true,
          ),
          RoutineExerciseRef(
            exerciseRefId: 'e3',
            name: 'Plank',
            muscleGroup: MuscleGroup.addome,
            trackingMode: ExerciseTrackingMode.timeOnly,
            isMissing: false,
          ),
        ],
        finisher: const [],
        segments: const [
          RoutineIntervalSegment(
            segmentIndex: 0,
            startIdx: 2,
            endIdx: 3,
            workSec: 30,
            restSec: 10,
            rounds: 4,
          ),
        ],
      );

      final round = RoutineDraft.fromDetails(original).preview();

      expect(round.main.map((row) => row.name), ['Panca', 'Croci', 'Plank']);
      expect(round.main[1].inSupersetWithPrevious, isTrue);
      expect(round.main.first.prescription.sets, 4);
      expect(round.warmup.single.warmupDurationSec, 45);
      expect(round.segments.single.startIdx, 2);
      expect(round.segments.single.endIdx, 3);
      expect(round.segments.single.rounds, 4);
    });
  });

  test('non si salva senza nome o senza esercizi', () {
    expect(RoutineDraft.empty().canSave, isFalse);
    expect(_draft().copyWith(name: '   ').canSave, isFalse);
    expect(_draft().canSave, isTrue);
  });
}
