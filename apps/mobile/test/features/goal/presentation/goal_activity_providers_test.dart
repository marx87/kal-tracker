import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/data/activity_settings_store.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/activity_multiplier.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';

import '../../workouts/live/fake_live_workout_repository.dart';
import '../marco.dart';

/// Stesso «adesso» fisso del test del dominio: le finestre sono sette giorni
/// a ritroso da qui, e un test che dipende da che giorno è oggi fallisce di
/// lunedì e passa di martedì.
final DateTime now = DateTime(2026, 8, 7, 20);

final double marcoBasal = BodyComposition.basalMetabolicRate(marcoFatFreeMass);

BodyState get marcoBody => BodyState(
  latest: WeightPoint(at: now, weightKg: marcoWeight),
  fatFreeMassKg: marcoFatFreeMass,
  fatFreeMassMeasuredAt: now,
  sevenDayAverageKg: marcoWeight,
);

Goal get marcoGoal => Goal(
  id: 'goal-1',
  targetWeightKg: 85,
  targetLevel: DefinitionLevel.defined,
  paceKgPerWeek: 0.5,
  startedAt: now.subtract(const Duration(days: 30)),
  startWeightKg: 98,
  startFatFreeMassKg: marcoFatFreeMass,
);

/// Una sessione come la consegnerebbe il repository: kcal LORDE e il MET
/// medio con cui sono state calcolate.
TrainingSessionKcal session(int daysAgo, double kcal) => TrainingSessionKcal(
  endedAt: now.subtract(Duration(days: daysAgo)),
  kcal: kcal,
  averageMet: 5,
  muscleGroupsComplete: true,
);

/// Tre settimane da tre sedute che portano il derivato a ~1,48: è l'esempio
/// della roadmap, quello che deve far comparire la domanda.
ActivityTrainingHistory get threeWeeksOfTraining => (
  sessions: [
    for (var week = 0; week < 3; week++)
      for (final offset in const [1, 3, 5]) session(week * 7 + offset, 1568),
  ],
  firstRecordedAt: now.subtract(const Duration(days: 120)),
);

/// Una sessione chiusa come la scrive la palestra: un esercizio con il suo
/// gruppo congelato, un'ora piena, e le kcal della chiusura solo se le aveva.
Workout closedWorkout({
  required int daysAgo,
  int minutes = 60,
  MuscleGroup? group = MuscleGroup.gambe,
  double? totalKcal,
}) {
  final endedAt = now.subtract(Duration(days: daysAgo));
  return Workout(
    id: 'w-$daysAgo',
    startedAt: endedAt.subtract(Duration(minutes: minutes)),
    endedAt: endedAt,
    finalDurationSeconds: minutes * 60,
    totalKcal: totalKcal,
    exercises: [
      WorkoutExercise(
        exerciseId: 'squat',
        exerciseName: 'Squat',
        muscleGroup: group,
        sets: const [WorkoutSet(weightKg: 80, reps: 8, completed: true)],
      ),
    ],
  );
}

/// Il repository della palestra con dentro delle sessioni vere e l'ultima
/// pesata di Marco.
FakeLiveWorkoutRepository gymWith(List<Workout> closed) =>
    FakeLiveWorkoutRepository(
      closedHistory: closed,
      bodyWeights: [BodyWeightSample(measuredAt: now, kg: marcoWeight)],
    );

/// [workouts] non nullo mette alla prova il provider VERO, quello che legge
/// il repository: gli altri test gli passano davanti con uno storico già
/// pronto, perché parlano di quello che succede a valle.
ProviderContainer containerWith({
  required ActivitySettingsStore store,
  BodyState? body,
  ActivityTrainingHistory? history,
  LiveWorkoutRepository? workouts,
}) {
  final container = ProviderContainer(
    overrides: [
      // Il moltiplicatore legge i passi dal check-in: senza questo override
      // la schermata aprirebbe il database vero.
      checkInStoreProvider.overrideWithValue(InMemoryCheckInStore()),
      activitySettingsStoreProvider.overrideWithValue(store),
      goalStoreProvider.overrideWithValue(
        InMemoryGoalStore(GoalHistory(current: marcoGoal)),
      ),
      bodyStateProvider.overrideWith((ref) => Stream.value(body ?? marcoBody)),
      if (workouts != null)
        liveWorkoutRepositoryProvider.overrideWithValue(workouts)
      else
        activityTrainingHistoryProvider.overrideWith(
          // Nessun allenamento: è l'app appena installata.
          (ref) async =>
              history ??
              (sessions: const <TrainingSessionKcal>[], firstRecordedAt: null),
        ),
      todayProvider.overrideWithValue(now),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Le letture che il piano aspetta: senza, `goalPlanProvider` è ancora in
/// caricamento e ogni asserzione guarderebbe il vuoto.
Future<void> settle(ProviderContainer container) async {
  await container.read(activitySettingsProvider.future);
  await container.read(goalControllerProvider.future);
  await container.read(bodyStateProvider.future);
  await container.read(activityTrainingHistoryProvider.future);
}

void main() {
  setUp(AppTime.initialize);

  group('quanto ci si muove è scritto da qualche parte', () {
    test('il livello scelto sopravvive alla chiusura dell\'app', () async {
      final store = InMemoryActivitySettingsStore();
      final container = containerWith(store: store);
      await settle(container);

      await container
          .read(activitySettingsProvider.notifier)
          .setDeclared(ActivityLevel.high);

      expect(container.read(activityLevelProvider), ActivityLevel.high);

      // La riapertura: un container nuovo sullo stesso store, come al
      // riavvio. Con la vecchia costante qui tornava «Attivo».
      final riaperto = containerWith(store: store);
      await settle(riaperto);

      expect(riaperto.read(activityLevelProvider), ActivityLevel.high);
    });

    test('anche il sì al derivato ha dove andare', () async {
      final store = InMemoryActivitySettingsStore();
      final container = containerWith(store: store);
      await settle(container);

      await container
          .read(activitySettingsProvider.notifier)
          .acceptDerivedMultiplier(1.48);

      final riaperto = containerWith(store: store);
      await settle(riaperto);

      expect(riaperto.read(acceptedActivityMultiplierProvider), 1.48);
    });

    test(
      'scegliere un livello a mano cancella il derivato accettato',
      () async {
        // Altrimenti la tendina non farebbe niente: nel TDEE il derivato vince
        // sempre, e Marco vedrebbe la sua scelta non cambiare il numero.
        final container = containerWith(store: InMemoryActivitySettingsStore());
        await settle(container);
        final notifier = container.read(activitySettingsProvider.notifier);

        await notifier.acceptDerivedMultiplier(1.48);
        await notifier.setDeclared(ActivityLevel.light);

        expect(container.read(acceptedActivityMultiplierProvider), isNull);
        expect(container.read(activityLevelProvider), ActivityLevel.light);
      },
    );

    test('un moltiplicatore che il TDEE ignorerebbe non si scrive', () async {
      final store = InMemoryActivitySettingsStore();
      final container = containerWith(store: store);
      await settle(container);

      await expectLater(
        container
            .read(activitySettingsProvider.notifier)
            .acceptDerivedMultiplier(3.4),
        throwsA(isA<FormatException>()),
      );
      expect(store.current.acceptedMultiplier, isNull);
    });
  });

  group('la proposta è collegata, ma resta una proposta', () {
    test('finché Marco non dice sì il TDEE usa il dichiarato', () async {
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        history: threeWeeksOfTraining,
      );
      await settle(container);

      final proposal = container.read(activityMultiplierProposalProvider)!;
      expect(proposal.refusal, isNull);
      expect(proposal.proposedMultiplier, closeTo(1.48, 0.005));
      expect(proposal.shouldPropose, isTrue);

      final plan = container.read(goalPlanProvider).valueOrNull!;
      expect(plan.tdee.kcal, closeTo(marcoBasal * 1.55, 0.01));
      expect(plan.tdee.multiplierWasDerived, isFalse);
    });

    test(
      'dopo il sì il TDEE cambia, e dice che il numero è ricavato',
      () async {
        final container = containerWith(
          store: InMemoryActivitySettingsStore(),
          history: threeWeeksOfTraining,
        );
        await settle(container);
        final proposal = container.read(activityMultiplierProposalProvider)!;

        await container
            .read(activitySettingsProvider.notifier)
            .acceptDerivedMultiplier(proposal.proposedMultiplier!);

        final plan = container.read(goalPlanProvider).valueOrNull!;
        expect(
          plan.tdee.kcal,
          closeTo(marcoBasal * proposal.proposedMultiplier!, 0.01),
        );
        expect(plan.tdee.multiplierWasDerived, isTrue);
        expect(
          plan.tdee.explanation,
          contains('ricavato dai tuoi allenamenti'),
        );
      },
    );

    test('senza allenamenti non si propone niente, e si dice perché', () async {
      // Nessun allenamento registrato: lo storico comincia adesso, zero
      // settimane coperte. Il rifiuto è quello giusto — non «ti alleni poco».
      final container = containerWith(store: InMemoryActivitySettingsStore());
      await settle(container);

      final proposal = container.read(activityMultiplierProposalProvider)!;
      expect(proposal.refusal, DerivedMultiplierRefusal.notEnoughHistory);
      expect(proposal.proposedMultiplier, isNull);
      expect(proposal.explanation, contains('3 settimane intere'));
      expect(proposal.question, isNull);
    });

    test('senza una pesata completa la proposta lo dichiara', () async {
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        body: const BodyState.unknown(),
        history: threeWeeksOfTraining,
      );
      await container.read(activitySettingsProvider.future);
      await container.read(bodyStateProvider.future);
      await container.read(activityTrainingHistoryProvider.future);

      final proposal = container.read(activityMultiplierProposalProvider)!;
      expect(proposal.refusal, DerivedMultiplierRefusal.noBasalMetabolicRate);
      expect(proposal.explanation, contains('pesata completa'));
    });

    test('finché gli allenamenti non sono letti non si dice niente', () {
      // Il rifiuto «non ho abbastanza storico» dato mentre la lettura è in
      // corso sarebbe una risposta sbagliata, e per giunta sulla causa.
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        workouts: gymWith([closedWorkout(daysAgo: 2)]),
      );

      expect(container.read(activityMultiplierProposalProvider), isNull);
    });
  });

  group('gli allenamenti veri arrivano dalla palestra', () {
    test('una sessione chiusa porta kcal, MET medio e affidabilità', () async {
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        workouts: gymWith([closedWorkout(daysAgo: 2)]),
      );

      final history = await container.read(
        activityTrainingHistoryProvider.future,
      );
      final session = history.sessions.single;

      // Un'ora di gambe a 6,0 MET sul peso dell'ultima pesata.
      expect(session.averageMet, 6.0);
      expect(session.kcal, closeTo(6 * marcoWeight, 0.01));
      expect(session.muscleGroupsComplete, isTrue);
      expect(session.endedAt, now.subtract(const Duration(days: 2)));
      expect(history.firstRecordedAt, closedWorkout(daysAgo: 2).startedAt);
    });

    test('le kcal della chiusura non si riscrivono col peso di oggi', () async {
      // Sono il numero che Marco ha visto in cima alla scheda, calcolato col
      // peso di quel giorno: rifarlo adesso riscriverebbe lo storico.
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        workouts: gymWith([closedWorkout(daysAgo: 2, totalKcal: 700)]),
      );

      final history = await container.read(
        activityTrainingHistoryProvider.future,
      );

      expect(history.sessions.single.kcal, 700);
      // Il MET invece si rifà: una colonna sua non ce l'ha, e senza di lui
      // dal lordo non si toglie il riposo.
      expect(history.sessions.single.averageMet, 6.0);
    });

    test('una riga senza gruppo muscolare marca la sessione', () async {
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        workouts: gymWith([closedWorkout(daysAgo: 2, group: null)]),
      );

      final history = await container.read(
        activityTrainingHistoryProvider.future,
      );

      expect(history.sessions.single.muscleGroupsComplete, isFalse);
      expect(history.sessions.single.isTrustworthy, isFalse);
    });

    test('senza allenamenti lo storico non comincia', () async {
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        workouts: gymWith(const []),
      );
      await settle(container);

      final history = await container.read(
        activityTrainingHistoryProvider.future,
      );

      expect(history.sessions, isEmpty);
      expect(history.firstRecordedAt, isNull);
      // E il rifiuto è quello vero, non più una costante vuota che lo
      // produceva per finta.
      expect(
        container.read(activityMultiplierProposalProvider)!.refusal,
        DerivedMultiplierRefusal.notEnoughHistory,
      );
    });

    test('tre settimane di palestra fanno una proposta vera', () async {
      final container = containerWith(
        store: InMemoryActivitySettingsStore(),
        workouts: gymWith([
          for (var week = 0; week < 3; week++)
            for (final offset in const [1, 3, 5])
              closedWorkout(daysAgo: week * 7 + offset),
          // Due mesi fa: fuori finestra, ma dice che quelle tre settimane
          // sono settimane vere e non l'app appena installata.
          closedWorkout(daysAgo: 60),
        ]),
      );
      await settle(container);

      final proposal = container.read(activityMultiplierProposalProvider)!;

      expect(proposal.refusal, isNull);
      expect(proposal.weeksUsed, 3);
      expect(proposal.sessionsUsed, 9);
      // Tre ore di gambe a settimana: 3 × 6,0 × 95,5 kcal lorde.
      expect(
        proposal.averageWeeklyGrossTrainingKcal,
        closeTo(3 * 6 * marcoWeight, 0.01),
      );
      expect(proposal.shouldPropose, isTrue);

      // E resta una proposta: il piano usa ancora il dichiarato.
      expect(
        container.read(goalPlanProvider).valueOrNull!.tdee.multiplierWasDerived,
        isFalse,
      );
    });
  });
}
