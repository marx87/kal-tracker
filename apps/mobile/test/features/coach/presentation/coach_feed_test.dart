import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/data/coach_feed_repository.dart';
import 'package:kal_tracker/features/coach/data/coach_gateway.dart';
import 'package:kal_tracker/features/coach/data/coach_store.dart';
import 'package:kal_tracker/features/coach/domain/coach_feed_item.dart';
import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';
import 'package:kal_tracker/features/coach/presentation/coach_providers.dart';
import 'package:kal_tracker/features/coach/presentation/widgets/coach_feed.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

class _CoachGateway implements CoachGateway {
  Map<String, Object?>? jobRow = const {'status': 'queued'};

  @override
  Future<CoachAccount?> currentAccount() async => null;

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {}

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async =>
      localProfileId;

  @override
  Future<Map<String, Object?>?> fetchJobRow(String jobId) async => jobRow;
}

void main() {
  setUp(AppTime.initialize);

  testWidgets('l\'ultima card apre actionPath, si legge e si può nascondere', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final repository = CoachFeedRepository(database);
    final itemId = await repository.publish(
      profileId: profile.id,
      kind: 'weekly_narrative',
      source: CoachFeedSource.ai,
      externalId: 'week:2026-08-02',
      title: 'Settimana solida',
      body: 'Il ritmo è sostenibile e coerente con il piano.',
      occurredAt: DateTime.utc(2026, 8, 2, 20),
      actionLabel: 'Leggi il rapporto',
      actionPath: '/coach',
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: CoachFeed()),
        ),
        GoRoute(
          path: '/coach',
          builder: (_, _) => const Scaffold(
            key: Key('coach_destination'),
            body: Text('Rapporto'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coach_feed_card')), findsOneWidget);
    expect(find.text('Settimana solida'), findsOneWidget);
    expect(find.text('Nascondi'), findsOneWidget);

    await tester.tap(find.byKey(const Key('coach_feed_action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coach_destination')), findsOneWidget);
    var row = await (database.select(
      database.coachFeedItems,
    )..where((item) => item.id.equals(itemId))).getSingle();
    expect(row.readAt, isNotNull);

    router.go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nascondi'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coach_feed_card')), findsNothing);
    row = await (database.select(
      database.coachFeedItems,
    )..where((item) => item.id.equals(itemId))).getSingle();
    expect(row.dismissedAt, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });

  test(
    'un nuovo commento AI viene pubblicato nel feed della settimana',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      final profile = await LocalProfileRepository(database).getOrCreateMarco();
      final week = CoachWeek(end: DateTime.utc(2026, 8, 2));
      final store = InMemoryCoachStore(
        CoachArchive(
          pending: CoachPendingJob(
            jobId: 'job-1',
            week: week,
            requestedAt: AppTime.nowUtc(),
          ),
        ),
      );
      final gateway = _CoachGateway();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          coachStoreProvider.overrideWithValue(store),
          coachGatewayProvider.overrideWithValue(gateway),
          coachPollIntervalProvider.overrideWithValue(const Duration(hours: 1)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container.read(coachControllerProvider.future);
      // Il controller fa un primo controllo automatico del job già pendente.
      // Lo lasciamo concludere prima del giro che riceve il risultato.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gateway.jobRow = const {
        'status': 'confirmed',
        'result': {
          'headline': 'Settimana solida',
          'paragraphs': ['Il ritmo è sostenibile e coerente con il piano.'],
        },
      };
      await container.read(coachControllerProvider.notifier).refreshNow();

      final rows = await database.select(database.coachFeedItems).get();
      expect(rows, hasLength(1));
      expect(rows.single.profileId, profile.id);
      expect(rows.single.source, CoachFeedSource.ai.name);
      expect(rows.single.externalId, 'week:2026-08-02');
      expect(rows.single.actionPath, '/coach');
    },
  );
}
