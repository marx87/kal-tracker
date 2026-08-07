/// **L'invariante: le kcal bruciate non si mangiano.**
///
/// Il TDEE misurato include già l'allenamento — nasce da «kcal mangiate meno
/// il peso che se n'è andato», e il peso che se n'è andato è anche il
/// risultato delle sessioni. Riaccreditare le calorie di una sessione
/// sull'obiettivo del giorno le conta due volte: il deficit da 550 kcal
/// diventa un pareggio, la bilancia si ferma e la colpa sembra del piano.
///
/// Questo file sta in `test/features/` e non sotto una singola cartella
/// perché l'invariante non è di nessuna area: attraversa Obiettivo (dove il
/// target nasce) e Diario (dove il rimanente si legge). Chi domani vorrà
/// «aggiustare» una delle due metà troverà l'altra che si lamenta.
///
/// Il commento che spiega il perché sta in `GoalPlanner._targetsFor`, cioè
/// nella riga che qualcuno sarebbe tentato di cambiare.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/calorie_progress_card.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_plan.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/targets/data/target_repository.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';

import 'goal/marco.dart';

/// La sessione del caso: un'ora e un quarto di sala pesi, 600 kcal stimate.
/// È il numero che il coach di MyFitnessPal restituirebbe da mangiare.
const double _kcalDellaSessione = 600;

/// Il giorno del piano. Fisso: qui non si sta misurando il calendario.
final DateTime _oggi = DateTime.utc(2026, 8, 5, 10);

/// Il consumo misurato di Marco: 2600 kcal medie mangiate e mezzo chilo in
/// meno in due settimane fanno 2875 kcal al giorno. Dentro ci sono anche gli
/// allenamenti di quelle due settimane, ed è tutto il punto.
const TdeeSample _dueSettimaneVere = TdeeSample(
  averageDailyKcal: 2600,
  weightChangeKg: -0.5,
  days: 14,
);

TdeeEstimate _tdeeMisurato() => AdaptiveTdee.resolve(
  fatFreeMassKg: marcoFatFreeMass,
  activity: ActivityLevel.moderate,
  sample: _dueSettimaneVere,
);

GoalPlan _pianoCon(GoalPhase fase) => GoalPlanner.build(
  goal: Goal(
    id: 'goal-invariante',
    targetWeightKg: 80.5,
    targetLevel: DefinitionLevel.defined,
    paceKgPerWeek: 0.5,
    startedAt: DateTime.utc(2026, 8, 5),
    startWeightKg: marcoWeight,
    startFatFreeMassKg: marcoFatFreeMass,
    phase: fase,
    phaseStartedAt: DateTime.utc(2026, 8, 5),
  ),
  currentWeightKg: marcoWeight,
  fatFreeMassKg: marcoFatFreeMass,
  tdee: _tdeeMisurato(),
  today: _oggi,
);

/// Quello che la schermata Oggi dice davvero: il riferimento del giorno, il
/// mangiato e i due numeri stampati sull'anello.
typedef _NumeriDiOggi = ({
  double riferimento,
  double mangiato,
  String anello,
  String rimanenti,
});

/// La schermata Oggi da sola, senza `app.dart`: qui interessa l'anello delle
/// calorie, non il router.
Widget _schermataOggi(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
  ],
  child: MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: const TodayDiaryScreen(),
  ),
);

/// Una giornata identica in tutto — obiettivo a 2200 kcal, 1600 kcal
/// mangiate — tranne che per la sessione chiusa nel database.
Future<_NumeriDiOggi> _giornataDiMarco(
  WidgetTester tester, {
  required double? sessioneKcal,
}) async {
  final database = AppDatabase(NativeDatabase.memory());
  final profile = await LocalProfileRepository(database).getOrCreateMarco();

  await TargetRepository(database).upsertTarget(
    profileId: profile.id,
    target: const NutritionTarget(
      calories: 2200,
      protein: 143,
      carbs: 220,
      fat: 61,
    ),
  );
  await DiaryRepository(database).addManualFood(
    profileId: profile.id,
    input: ManualFoodInput(
      foodName: 'Riso, pollo e olio',
      grams: 400,
      per100g: const Nutrients(calories: 400, protein: 12, carbs: 45, fat: 12),
      mealType: MealType.lunch,
      eatenAt: AppTime.nowInRome(),
    ),
  );

  if (sessioneKcal != null) {
    final adesso = AppTime.nowUtc();
    await database
        .into(database.workouts)
        .insert(
          WorkoutsCompanion.insert(
            id: 'sessione-di-oggi',
            profileId: profile.id,
            startedAt: adesso.subtract(const Duration(minutes: 75)),
            endedAt: Value(adesso),
            routineNameSnapshot: const Value('Giorno 1 spalle petto tricipiti'),
            totalKcal: Value(sessioneKcal),
            createdAt: adesso,
            updatedAt: adesso,
          ),
        );
  }

  await tester.pumpWidget(_schermataOggi(database));
  await tester.pumpAndSettle();

  final card = tester.widget<CalorieProgressCard>(
    find.byType(CalorieProgressCard),
  );
  final numeri = (
    riferimento: card.target.calories,
    mangiato: card.nutrients.calories,
    anello: tester.widget<Text>(find.byKey(const Key('daily_calories'))).data!,
    rimanenti: tester
        .widget<Text>(find.byKey(const Key('remaining_calories')))
        .data!,
  );

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
  return numeri;
}

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  group('il target del giorno', () {
    test('è il consumo misurato meno il deficit, e basta', () {
      final piano = _pianoCon(GoalPhase.approach);

      expect(piano.tdee.isMeasured, isTrue);
      expect(piano.tdee.kcal, closeTo(2875, 0.01));
      expect(piano.dailyDeficitKcal, closeTo(550, 0.01));
      // 2875 − 550. Non 2875 − 550 + 600: l'allenamento è già dentro i 2875,
      // e sommarlo qui trasformerebbe il deficit in un surplus da 50 kcal.
      expect(piano.targets.calories, closeTo(2325, 0.01));
      expect(
        piano.targets.calories,
        isNot(closeTo(2325 + _kcalDellaSessione, 1)),
        reason: 'le kcal della sessione non si accreditano sul target',
      );
    });

    test('in mantenimento è esattamente il consumo misurato', () {
      final piano = _pianoCon(GoalPhase.maintenance);

      // Senza deficit l'uguaglianza è nuda: il target È il TDEE. Accreditare
      // qui una sessione vorrebbe dire mangiare in surplus esattamente nei
      // giorni in cui ci si allena — il modo più efficace di non mantenere.
      expect(piano.dailyDeficitKcal, 0);
      expect(piano.targets.calories, closeTo(piano.tdee.kcal, 0.01));
      expect(piano.targets.calories, closeTo(2875, 0.01));
    });
  });

  group('il rimanente del giorno', () {
    testWidgets('una sessione da 600 kcal non sposta niente', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final conSessione = await _giornataDiMarco(
        tester,
        sessioneKcal: _kcalDellaSessione,
      );
      final senzaSessione = await _giornataDiMarco(tester, sessioneKcal: null);

      // Obiettivo 2200, mangiate 1600: ne restano 600. Se le kcal della
      // sessione venissero accreditate sul target ne resterebbero 1200, e se
      // venissero scalate dal mangiato l'anello direbbe 1000 kcal invece di
      // 1600. Sono le due facce dello stesso doppio conteggio.
      expect(conSessione.riferimento, 2200);
      expect(conSessione.mangiato, closeTo(1600, 0.01));
      expect(conSessione.anello, '1600 kcal');
      expect(conSessione.rimanenti, '600');

      // Il controllo: la giornata senza allenamento dà gli stessi identici
      // numeri. È questa riga a saltare per prima il giorno in cui qualcuno
      // collega le calorie bruciate al diario.
      expect(conSessione, senzaSessione);
    });
  });
}
