import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:kal_tracker/features/health/presentation/health_providers.dart';
import 'package:kal_tracker/features/health/presentation/health_screen.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';

import '../../workouts/live/fake_live_workout_repository.dart';

void main() {
  final today = DateTime.utc(2026, 8, 8);
  late AppDatabase database;
  late _FakeHealthGateway gateway;
  late FakeLiveWorkoutRepository workouts;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    await LocalProfileRepository(database).getOrCreateMarco();
    gateway = _FakeHealthGateway.notRequested();
    workouts = FakeLiveWorkoutRepository(
      closedHistory: [
        Workout(
          id: 'workout-1',
          routineName: 'Full body',
          startedAt: DateTime.utc(2026, 8, 7, 16),
          endedAt: DateTime.utc(2026, 8, 7, 17),
          finalDurationSeconds: 3600,
          totalKcal: 420,
          exercises: const [],
        ),
      ],
    );
  });

  Widget app({double textScale = 1}) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      todayProvider.overrideWithValue(today),
      healthDataGatewayProvider.overrideWithValue(gateway),
      liveWorkoutRepositoryProvider.overrideWithValue(workouts),
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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const HealthScreen(),
    ),
  );

  Widget fullApp() => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      appConfigProvider.overrideWithValue(const AppConfig.offline()),
      todayProvider.overrideWithValue(today),
      healthDataGatewayProvider.overrideWithValue(gateway),
      liveWorkoutRepositoryProvider.overrideWithValue(workouts),
    ],
    child: const KalTrackerApp(),
  );

  testWidgets(
    'connette solo al tocco, importa sette giorni ed esporta gli allenamenti',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      gateway.summaries = [
        HealthDailySummary(
          day: today.subtract(const Duration(days: 1)),
          source: 'health_connect',
          steps: 10000,
          sleepMinutes: 420,
          restingHeartRate: 56,
        ),
        HealthDailySummary(
          day: today,
          source: 'health_connect',
          steps: 12345,
          sleepMinutes: 450,
          restingHeartRate: 54,
        ),
      ];

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.text('Sorgente: Health Connect'), findsOneWidget);
      expect(gateway.authorizationRequests, isEmpty);
      expect(gateway.readCalls, 0);
      expect(
        find.byKey(const Key('health_export_workouts_button')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('health_connect_button')));
      await tester.pumpAndSettle();

      expect(gateway.authorizationRequests, hasLength(1));
      expect(
        gateway.authorizationRequests.single,
        containsAll(HealthCapability.values),
      );
      expect(
        find.byKey(const Key('health_capability_readRestingHeartRate')),
        findsOneWidget,
      );

      await _scrollTo(tester, const Key('health_import_button'));
      await tester.tap(find.byKey(const Key('health_import_button')));
      await tester.pumpAndSettle();

      expect(gateway.readCalls, 1);
      expect(gateway.lastFromDay, today.subtract(const Duration(days: 6)));
      expect(gateway.lastThroughDay, today);
      expect(find.text('22.345'), findsOneWidget);
      expect(find.text('7 h 15 min'), findsOneWidget);
      expect(find.text('54 bpm'), findsOneWidget);

      await _scrollTo(tester, const Key('health_export_workouts_button'));
      await tester.tap(find.byKey(const Key('health_export_workouts_button')));
      await tester.pumpAndSettle();

      expect(gateway.written, hasLength(1));
      expect(gateway.written.single.id, 'workout-1');
      expect(gateway.written.single.title, 'Full body');
      expect(find.textContaining('1 allenamento esportato'), findsWidgets);

      await _scrollTo(tester, const Key('health_calorie_budget_note'));
      expect(
        find.textContaining(
          'Le calorie dell\'orologio non aumentano il budget',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Huawei Health → Health Connect'),
        findsOneWidget,
      );

      await _dispose(tester, database);
    },
  );

  testWidgets('resta usabile a 320 px con testo al 150%', (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    gateway.grantAll();

    await tester.pumpWidget(app(textScale: 1.5));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('health_connect_button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _scrollTo(tester, const Key('health_import_button'));
    expect(tester.takeException(), isNull);
    await _scrollTo(tester, const Key('health_export_workouts_button'));
    expect(tester.takeException(), isNull);
    await _scrollTo(tester, const Key('health_calorie_budget_note'));
    expect(tester.takeException(), isNull);

    await _dispose(tester, database);
  });

  testWidgets('la rotta /health si apre sia da Corpo sia da Progressi', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(fullApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_body')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('body_open_health_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('health_screen_list')), findsOneWidget);
    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);

    // La schermata resta nel branch Corpo: ritoccare la voce selezionata
    // riporta alla radice del branch, come per le altre pagine di servizio.
    await tester.tap(find.byKey(const Key('nav_body')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body_open_progress_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_health_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('health_screen_list')), findsOneWidget);
    await _dispose(tester, database);
  });
}

Future<void> _scrollTo(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    260,
    scrollable: find.descendant(
      of: find.byKey(const Key('health_screen_list')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

class _FakeHealthGateway implements HealthDataGateway {
  _FakeHealthGateway(this.currentStatus);

  factory _FakeHealthGateway.notRequested() {
    final capabilities = HealthCapability.values.toSet();
    return _FakeHealthGateway(
      HealthGatewayStatus(
        source: 'health_connect',
        capabilities: capabilities,
        permissions: {
          for (final capability in capabilities)
            capability: HealthPermissionState.notRequested,
        },
        detail: 'Dati di prova dal telefono.',
      ),
    );
  }

  HealthGatewayStatus currentStatus;
  List<HealthDailySummary> summaries = const [];
  final List<Set<HealthCapability>> authorizationRequests = [];
  final List<HealthWorkoutRecord> written = [];
  int readCalls = 0;
  DateTime? lastFromDay;
  DateTime? lastThroughDay;

  void grantAll() {
    currentStatus = HealthGatewayStatus(
      source: currentStatus.source,
      capabilities: currentStatus.capabilities,
      permissions: {
        for (final capability in currentStatus.capabilities)
          capability: HealthPermissionState.granted,
      },
      detail: currentStatus.detail,
    );
  }

  @override
  Future<HealthGatewayStatus> status() async => currentStatus;

  @override
  Future<HealthGatewayStatus> requestAuthorization(
    Set<HealthCapability> capabilities,
  ) async {
    authorizationRequests.add(Set.of(capabilities));
    grantAll();
    return currentStatus;
  }

  @override
  Future<List<HealthDailySummary>> readDailySummaries({
    required DateTime fromDay,
    required DateTime throughDay,
  }) async {
    readCalls++;
    lastFromDay = fromDay;
    lastThroughDay = throughDay;
    return summaries;
  }

  @override
  Future<HealthWorkoutWriteResult> writeWorkout(
    HealthWorkoutRecord workout,
  ) async {
    written.add(workout);
    return const HealthWorkoutWriteResult(HealthWorkoutWriteState.written);
  }
}
