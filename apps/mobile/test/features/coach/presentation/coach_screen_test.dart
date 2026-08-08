import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/coach/data/coach_gateway.dart';
import 'package:kal_tracker/features/coach/data/coach_store.dart';
import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';
import 'package:kal_tracker/features/coach/presentation/coach_providers.dart';
import 'package:kal_tracker/features/coach/presentation/coach_screen.dart';

import '../fixtures.dart';

final DateTime sunday = DateTime.utc(2026, 8, 2);

/// Gateway muto: il Mac non risponde mai. È lo stato che questa schermata
/// deve saper reggere, quindi è anche il default dei test.
class SilentCoachGateway implements CoachGateway {
  Map<String, Object?>? jobRow = const {'status': 'queued'};

  @override
  Future<CoachAccount?> currentAccount() async => null;

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async =>
      localProfileId;

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {}

  @override
  Future<Map<String, Object?>?> fetchJobRow(String jobId) async => jobRow;
}

/// Una settimana vera: diario pieno, pesate con composizione, allenamenti.
CoachSnapshot fullSnapshot({
  List<CoachStrengthSet> strengthSets = const [],
  CheckInLog checkIns = const CheckInLog.empty(),
}) => CoachSnapshot(
  week: testWeek,
  diary: diaryWeek(lastDay: sunday, kcal: 2200, proteinGrams: 145, days: 14),
  weighIns: weighInSeries(
    lastDay: sunday,
    weights: const [
      95.9,
      95.8,
      95.8,
      95.7,
      95.6,
      95.6,
      95.5,
      95.4,
      95.4,
      95.3,
      95.2,
      95.1,
      95.1,
      95,
    ],
    bodyFatPcts: List.filled(14, 25),
    waterPcts: List.filled(14, 54),
  ),
  sessions: [
    session(DateTime.utc(2026, 7, 28), rpe: 7),
    session(DateTime.utc(2026, 7, 30), rpe: 7),
  ],
  strengthSets: strengthSets,
  checkIns: checkIns,
  targets: const CoachTargets(
    dailyCalories: 2200,
    dailyProtein: 143,
    weeklyWorkouts: 3,
  ),
);

CoachNarrative narrativeOf(CoachWeek week) => CoachNarrative(
  week: week,
  writtenAt: week.end.add(const Duration(hours: 21)),
  paragraphs: const [
    'Il deficit sta reggendo e la massa magra non si è mossa.',
  ],
  headline: 'Settimana solida',
);

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  Widget host({
    CoachSnapshot? snapshot,
    CoachArchive archive = const CoachArchive.empty(),
    ThemeData? theme,
  }) => ProviderScope(
    overrides: [
      coachWeekProvider.overrideWithValue(testWeek),
      coachSnapshotProvider.overrideWith(
        (ref) async => snapshot ?? fullSnapshot(),
      ),
      coachStoreProvider.overrideWithValue(InMemoryCoachStore(archive)),
      coachGatewayProvider.overrideWithValue(SilentCoachGateway()),
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
      home: const CoachScreen(),
    ),
  );

  /// La lista è pigra: quello che sta sotto la piega non esiste ancora nel
  /// tree, quindi va portato dentro con uno scorrimento vero.
  /// [settle] va spento quando a schermo c'è un indicatore di attesa: quello
  /// gira per sempre e `pumpAndSettle` non tornerebbe mai.
  Future<void> scrollTo(
    WidgetTester tester,
    Finder finder, {
    bool settle = true,
  }) async {
    await tester.dragUntilVisible(
      finder,
      find.byKey(const Key('coach_list')),
      const Offset(0, -240),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  group('i numeri ci sono comunque', () {
    testWidgets('il rapporto si apre col Mac spento e senza rete', (
      tester,
    ) async {
      await tester.pumpWidget(host(theme: AppTheme.light));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coach_header_card')), findsOneWidget);
      expect(find.byKey(const Key('coach_tdee_card')), findsOneWidget);
      await scrollTo(tester, find.byKey(const Key('coach_adherence_card')));
      await scrollTo(tester, find.byKey(const Key('coach_recomposition_card')));
      await scrollTo(tester, find.byKey(const Key('coach_overtraining_card')));
    });

    testWidgets('senza obiettivo la proiezione non c\'è e il resto sì', (
      tester,
    ) async {
      await tester.pumpWidget(host(theme: AppTheme.light));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coach_projection_card')), findsNothing);
      expect(find.byKey(const Key('coach_tdee_card')), findsOneWidget);
    });

    testWidgets('una settimana vuota dice cosa manca invece di sparire', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          snapshot: CoachSnapshot(week: testWeek),
          theme: AppTheme.light,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coach_no_diary')), findsOneWidget);
    });

    testWidgets('si disegna anche dentro un MaterialApp spoglio', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('coach_header_card')), findsOneWidget);
    });
  });

  group('il movimento', () {
    /// Una settimana camminata a metà: quattromila passi contro i diecimila
    /// dei sette giorni prima.
    CoachSnapshot halvedWalking() => fullSnapshot(
      checkIns: checkInLog(
        lastDay: sunday,
        steps: [...List.filled(7, 4000), ...List.filled(7, 10000)],
      ),
    );

    testWidgets('senza un giorno segnato la card non c\'è', (tester) async {
      // Un rapporto non rimprovera un campo che nessuno era obbligato a
      // compilare: quando manca del tutto, sparisce.
      await tester.pumpWidget(host(theme: AppTheme.light));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coach_neat_card')), findsNothing);
    });

    testWidgets('il crollo si legge, con il suo quanto', (tester) async {
      await tester.pumpWidget(
        host(theme: AppTheme.light, snapshot: halvedWalking()),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_neat_card')));

      expect(find.textContaining('Ti stai muovendo di meno'), findsOneWidget);
      expect(find.text('−60'), findsOneWidget);
      expect(find.byKey(const Key('coach_neat_cause')), findsOneWidget);
    });

    testWidgets('il movimento si nomina prima del consumo', (tester) async {
      // L'ordine è il punto: al contrario il rapporto proporrebbe di togliere
      // calorie prima di aver nominato la camminata che è sparita.
      //
      // Lo schermo alto serve a tenere le due card vive insieme: la lista è
      // pigra e a 600 px il consumo non sarebbe ancora costruito, quindi
      // scorrere per raggiungerlo perderebbe proprio il confronto.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        host(theme: AppTheme.light, snapshot: halvedWalking()),
      );
      await tester.pumpAndSettle();

      final neat = tester.getTopLeft(find.byKey(const Key('coach_neat_card')));
      final tdee = tester.getTopLeft(find.byKey(const Key('coach_tdee_card')));
      expect(neat.dy, lessThan(tdee.dy));
    });

    testWidgets('quando il movimento tiene non si grida', (tester) async {
      await tester.pumpWidget(
        host(
          theme: AppTheme.light,
          snapshot: fullSnapshot(
            checkIns: checkInLog(lastDay: sunday, steps: List.filled(14, 9000)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_neat_card')));

      expect(find.textContaining('Il movimento è lo stesso'), findsOneWidget);
      // Niente percentuale e niente causa: non c'è niente da spiegare, e la
      // riga resta un dato invece di diventare un allarme.
      expect(find.byKey(const Key('coach_neat_cause')), findsNothing);
    });
  });

  group('il semaforo', () {
    testWidgets('la card annuncia cinque segnali, non quattro', (tester) async {
      await tester.pumpWidget(host(theme: AppTheme.light));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_overtraining_card')));

      expect(find.text('Cinque segnali, e quelli che non so'), findsOneWidget);
    });

    testWidgets('senza serie la forza è fra i dati che mancano', (
      tester,
    ) async {
      await tester.pumpWidget(host(theme: AppTheme.light));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_overtraining_card')));

      expect(find.textContaining('forza in calo'), findsOneWidget);
    });

    testWidgets('con lo storico la forza arriva fino alla card', (
      tester,
    ) async {
      // Il giro completo: le serie entrano nella fotografia, il motore le
      // misura e la ragione compare a schermo con il suo numero.
      await tester.pumpWidget(
        host(
          theme: AppTheme.light,
          snapshot: fullSnapshot(
            strengthSets: liftedWeeks(before: 100, now: 90),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_overtraining_card')));

      expect(find.textContaining('e1RM medio è sceso'), findsOneWidget);
      expect(find.textContaining('10,0 %'), findsOneWidget);
    });
  });

  group('il commento', () {
    testWidgets('senza commento lo dice e non si scusa', (tester) async {
      await tester.pumpWidget(host(theme: AppTheme.light));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_narrative_card')));

      expect(find.byKey(const Key('coach_narrative_empty')), findsOneWidget);
      expect(find.byKey(const Key('coach_request_button')), findsOneWidget);
    });

    testWidgets('col Mac spento resta il messaggio onesto', (tester) async {
      await tester.pumpWidget(
        host(
          theme: AppTheme.light,
          archive: const CoachArchive(
            lastError:
                'Il Mac non ha risposto: il rapporto è comunque qui, manca '
                'solo il commento.',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_narrative_card')));

      expect(find.byKey(const Key('coach_narrative_error')), findsOneWidget);
      expect(find.textContaining('Il Mac non ha risposto'), findsOneWidget);
    });

    testWidgets('l\'ultimo commento resta leggibile, con la sua settimana', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          theme: AppTheme.light,
          archive: CoachArchive(
            last: narrativeOf(testWeek.previous),
            lastError: 'Il Mac non ha risposto.',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_narrative_card')));

      expect(find.text('Settimana solida'), findsOneWidget);
      expect(find.textContaining('Il deficit sta reggendo'), findsOneWidget);
      expect(find.byKey(const Key('coach_narrative_stale')), findsOneWidget);
      expect(find.textContaining('domenica 26 luglio'), findsOneWidget);
    });

    testWidgets('il commento di questa settimana non è marcato vecchio', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          theme: AppTheme.light,
          archive: CoachArchive(last: narrativeOf(testWeek)),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coach_narrative_card')));

      expect(find.byKey(const Key('coach_narrative_stale')), findsNothing);
      expect(find.text('Chiedine uno nuovo'), findsOneWidget);
    });

    testWidgets('mentre il Mac scrive si può smettere di aspettare', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          theme: AppTheme.light,
          archive: CoachArchive(
            pending: CoachPendingJob(
              jobId: 'job-1',
              week: testWeek,
              requestedAt: AppTime.nowUtc(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await scrollTo(
        tester,
        find.byKey(const Key('coach_narrative_card')),
        settle: false,
      );

      expect(find.byKey(const Key('coach_waiting')), findsOneWidget);
      expect(find.byKey(const Key('coach_cancel_button')), findsOneWidget);
      expect(find.byKey(const Key('coach_request_button')), findsNothing);

      await tester.tap(find.byKey(const Key('coach_cancel_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('coach_waiting')), findsNothing);
      expect(find.byKey(const Key('coach_request_button')), findsOneWidget);
    });
  });
}
