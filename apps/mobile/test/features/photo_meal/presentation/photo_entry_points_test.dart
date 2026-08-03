import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_jobs_gateway.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_local_store.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_providers.dart';

import 'photo_meal_fakes.dart';

/// La snackbar dura 8 secondi: la revisione deve restare raggiungibile
/// anche dopo, dal badge nel diario e dalla riga di stato del pasto.
Widget _app({
  required AppDatabase database,
  required FakePhotoJobsGateway gateway,
  required InMemoryPhotoReviewLocalStore store,
  InMemoryPhotoMealJobStore? jobStore,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    photoJobsEnabledProvider.overrideWithValue(true),
    photoJobsGatewayProvider.overrideWithValue(gateway),
    photoReviewLocalStoreProvider.overrideWithValue(store),
    // Sempre in memoria: il file store reale non risolve nei test widget.
    photoMealJobStoreProvider.overrideWithValue(
      jobStore ?? InMemoryPhotoMealJobStore(),
    ),
  ],
  child: const KalTrackerApp(),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

void main() {
  testWidgets('il badge nel diario porta alla revisione anche a snackbar '
      'scaduta', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [buildReviewJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    // La snackbar sparisce da sola: il badge invece resta finché la
    // proposta non viene gestita.
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();

    final badge = find.byKey(const Key('photo_proposals_badge'));
    expect(badge, findsOneWidget);
    await tester.ensureVisible(badge);
    await tester.pumpAndSettle();
    await tester.tap(badge);
    await tester.pumpAndSettle();

    expect(find.text('Rivedi la proposta'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la riga «proposta pronta» sotto il pasto apre la revisione', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [buildReviewJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    final jobStore = InMemoryPhotoMealJobStore([buildLocalJob()]);

    await tester.pumpWidget(
      _app(
        database: database,
        gateway: gateway,
        store: store,
        jobStore: jobStore,
      ),
    );
    await tester.pumpAndSettle();

    // Snackbar scaduta: la riga di stato resta l'ingresso alla revisione.
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();

    // Risultato vecchio senza per100g: etichetta di stato come oggi.
    expect(find.text('Foto: proposta pronta da rivedere'), findsOneWidget);

    final row = find.byKey(const Key('photo_job_open_job-1'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Rivedi la proposta'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la riga «proposta pronta» mostra il totale stimato quando '
      'le stime per 100 g ci sono', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [buildReviewJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    // Copia grezza del risultato del worker nuovo nel registro locale:
    // 130 kcal/100 g × 150 g suggeriti = 195 kcal, calcolate dall'app.
    final jobStore = InMemoryPhotoMealJobStore([
      buildLocalJob(
        analysisResult: {
          'foods': [
            {
              'name': 'Riso basmati',
              'alternatives': ['Riso venere'],
              'minimumGrams': 100,
              'suggestedGrams': 150,
              'maximumGrams': 250,
              'confidence': 0.8,
              'preparation': 'boiled',
              'per100g': {
                'energyKcal': 130,
                'proteinG': 2.6,
                'carbsG': 28,
                'fatG': 0.4,
              },
              'hiddenIngredients': ['olio'],
              'uncertainty': 'Porzione stimata.',
            },
          ],
          'questions': <Object?>[],
          'overallConfidence': 0.7,
          'notes': '',
        },
      ),
    ]);

    await tester.pumpWidget(
      _app(
        database: database,
        gateway: gateway,
        store: store,
        jobStore: jobStore,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Foto: ≈ 195 kcal da rivedere'), findsOneWidget);

    await _disposeApp(tester, database);
  });
}
