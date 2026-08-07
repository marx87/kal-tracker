import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

ProviderContainer containerWith({
  required ActivitySettingsStore store,
  BodyState? body,
  ActivityTrainingHistory? history,
}) {
  final container = ProviderContainer(
    overrides: [
      activitySettingsStoreProvider.overrideWithValue(store),
      goalStoreProvider.overrideWithValue(
        InMemoryGoalStore(GoalHistory(current: marcoGoal)),
      ),
      bodyStateProvider.overrideWith((ref) => Stream.value(body ?? marcoBody)),
      activityTrainingHistoryProvider.overrideWithValue(
        // Nessuna sorgente collegata: è lo stato in cui l'app si trova oggi.
        history ?? (sessions: const [], firstRecordedAt: null),
      ),
      todayProvider.overrideWithValue(now),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Le due letture che il piano aspetta: senza, `goalPlanProvider` è ancora in
/// caricamento e ogni asserzione guarderebbe il vuoto.
Future<void> settle(ProviderContainer container) async {
  await container.read(activitySettingsProvider.future);
  await container.read(goalControllerProvider.future);
  await container.read(bodyStateProvider.future);
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
      // Nessuna sorgente collegata: lo storico comincia adesso, zero
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

      final proposal = container.read(activityMultiplierProposalProvider)!;
      expect(proposal.refusal, DerivedMultiplierRefusal.noBasalMetabolicRate);
      expect(proposal.explanation, contains('pesata completa'));
    });
  });
}
