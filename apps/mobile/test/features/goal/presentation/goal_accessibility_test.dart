import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/goal/presentation/goal_screen.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/goal_target_sheet.dart';

import '../marco.dart';

final _state = BodyState(
  latest: WeightPoint(at: DateTime.now().toUtc(), weightKg: marcoWeight),
  fatFreeMassKg: marcoFatFreeMass,
  fatFreeMassMeasuredAt: DateTime.now().toUtc(),
  sevenDayAverageKg: 95.3,
);

final _goal = Goal(
  id: 'goal-1',
  targetWeightKg: 80.5,
  targetLevel: DefinitionLevel.defined,
  paceKgPerWeek: 0.5,
  startedAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
  startWeightKg: 98,
  startFatFreeMassKg: marcoFatFreeMass,
  phaseStartedAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
);

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  Widget screen({required ThemeData theme, double textScale = 1}) =>
      ProviderScope(
        overrides: [
          goalStoreProvider.overrideWithValue(
            InMemoryGoalStore(GoalHistory(current: _goal)),
          ),
          bodyStateProvider.overrideWith((ref) => Stream.value(_state)),
        ],
        child: MaterialApp(
          theme: theme,
          locale: const Locale('it'),
          supportedLocales: const [Locale('it')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: const GoalScreen(),
          ),
        ),
      );

  testWidgets('a testo 150 % la schermata regge senza traboccare', (
    tester,
  ) async {
    await tester.pumpWidget(screen(theme: AppTheme.light, textScale: 1.5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('goal_headline')), findsOneWidget);
  });

  testWidgets('al buio si disegna con i colori del tema, non con i suoi', (
    tester,
  ) async {
    await tester.pumpWidget(screen(theme: AppTheme.dark));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // Il fondo è quello del tema scuro: nessuna card si porta dietro la
    // crema del tema chiaro.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, isNull);
    final context = tester.element(find.byType(GoalScreen));
    expect(Theme.of(context).colorScheme.brightness, Brightness.dark);
  });

  testWidgets('i bersagli tattili arrivano a 48', (tester) async {
    await tester.pumpWidget(screen(theme: AppTheme.light));
    await tester.pumpAndSettle();

    final action = find.byKey(const Key('section_card_action')).first;
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
  });

  testWidgets('anche il foglio della manopola regge il testo grande', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: GoalTargetSheet(
              currentWeightKg: marcoWeight,
              fatFreeMassKg: marcoFatFreeMass,
              paceKgPerWeek: 0.5,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Il verdetto resta leggibile: è l'informazione che non può sparire.
    expect(find.byKey(const Key('goal_feasibility')), findsOneWidget);
  });
}
