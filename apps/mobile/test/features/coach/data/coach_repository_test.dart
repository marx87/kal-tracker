import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/data/coach_gateway.dart';
import 'package:kal_tracker/features/coach/data/coach_repository.dart';
import 'package:kal_tracker/features/coach/data/coach_store.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

import '../fixtures.dart';

/// Gateway finto: nessuna rete, tutto ispezionabile.
class FakeCoachGateway implements CoachGateway {
  FakeCoachGateway({this.account = const CoachAccount(userId: 'owner-1')});

  CoachAccount? account;
  Map<String, Object?>? jobRow;
  Object? fetchError;
  Object? enqueueError;

  final List<Map<String, Object?>> enqueued = [];

  @override
  Future<CoachAccount?> currentAccount() async => account;

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async =>
      'remote-$localProfileId';

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {
    if (enqueueError case final error?) {
      throw error;
    }
    enqueued.add(row);
  }

  @override
  Future<Map<String, Object?>?> fetchJobRow(String jobId) async {
    if (fetchError case final error?) {
      throw error;
    }
    return jobRow;
  }
}

void main() {
  setUp(AppTime.initialize);

  late FakeCoachGateway gateway;
  late InMemoryCoachStore store;
  late DateTime now;

  CoachRepository repositoryOf() =>
      CoachRepository(gateway: gateway, store: store, now: () => now);

  final metrics = CoachEngine.run(
    CoachSnapshot(
      week: testWeek,
      diary: diaryWeek(
        lastDay: DateTime.utc(2026, 8, 2),
        kcal: 2200,
        proteinGrams: 145,
      ),
      weighIns: weighInSeries(
        lastDay: DateTime.utc(2026, 8, 2),
        weights: const [95.5, 95.4, 95.3, 95.2, 95.1],
        bodyFatPcts: const [25, 25, 25, 25, 25],
      ),
    ),
  );

  setUp(() {
    gateway = FakeCoachGateway();
    store = InMemoryCoachStore();
    now = DateTime.utc(2026, 8, 2, 20);
  });

  group('la richiesta', () {
    test('accoda solo le cinque colonne concesse dal grant', () async {
      await repositoryOf().requestNarrative(
        profileId: 'marco',
        metrics: metrics,
      );

      expect(gateway.enqueued, hasLength(1));
      expect(gateway.enqueued.single.keys, {
        'id',
        'owner_id',
        'profile_id',
        'request',
        'last_mutation_id',
      });
      expect(gateway.enqueued.single['profile_id'], 'remote-marco');
      expect(gateway.enqueued.single['request'], isA<Map<String, Object?>>());
    });

    test('senza accesso al cloud lo dice e non accoda niente', () async {
      gateway.account = null;

      await expectLater(
        repositoryOf().requestNarrative(profileId: 'marco', metrics: metrics),
        throwsA(
          isA<CoachException>().having(
            (error) => error.authRequired,
            'authRequired',
            isTrue,
          ),
        ),
      );
      expect(gateway.enqueued, isEmpty);
      expect((await store.read()).pending, isNull);
    });

    test('due richieste insieme no: una sola alla volta', () async {
      final repository = repositoryOf();
      await repository.requestNarrative(profileId: 'marco', metrics: metrics);

      await expectLater(
        repository.requestNarrative(profileId: 'marco', metrics: metrics),
        throwsA(isA<CoachException>()),
      );
      expect(gateway.enqueued, hasLength(1));
    });
  });

  group('l\'attesa', () {
    Future<void> enqueue() =>
        repositoryOf().requestNarrative(profileId: 'marco', metrics: metrics);

    test('un commento pronto viene archiviato ripulito dalle cifre', () async {
      await enqueue();
      gateway.jobRow = {
        'status': 'needs_review',
        'result': {
          'headline': 'Settimana solida',
          'paragraphs': [
            'Il deficit sta reggendo.',
            'Sei stato circa 600 kcal sotto.',
          ],
        },
      };

      final archive = await repositoryOf().refresh();

      expect(archive.pending, isNull);
      expect(archive.last!.paragraphs, ['Il deficit sta reggendo.']);
      expect(archive.last!.droppedParagraphs, 1);
      expect(archive.last!.week.end, testWeek.end);
      expect(archive.lastError, isNull);
    });

    test('un commento tutto numerico non diventa un commento vuoto', () async {
      await enqueue();
      gateway.jobRow = {
        'status': 'needs_review',
        'result': {
          'paragraphs': ['2750 kcal di consumo.'],
        },
      };

      final archive = await repositoryOf().refresh();

      expect(archive.last, isNull);
      expect(archive.pending, isNull);
      expect(archive.lastError, contains('numeri'));
    });

    test('finché è in coda si aspetta in silenzio', () async {
      await enqueue();
      gateway.jobRow = {'status': 'queued'};
      now = now.add(const Duration(minutes: 3));

      final archive = await repositoryOf().refresh();

      expect(archive.pending, isNotNull);
      expect(archive.lastError, isNull);
    });

    test(
      'col Mac spento, passata la finestra, il silenzio si dichiara',
      () async {
        await enqueue();
        gateway.jobRow = {'status': 'queued'};
        now = now.add(
          CoachRepository.queuedTimeout + const Duration(minutes: 1),
        );

        final archive = await repositoryOf().refresh();

        expect(archive.pending, isNull);
        expect(archive.lastError, contains('Il Mac non ha risposto'));
        expect(archive.lastError, contains('rapporto è comunque qui'));
      },
    );

    test(
      'un worker morto a metà non tiene l\'attesa aperta per sempre',
      () async {
        await enqueue();
        gateway.jobRow = {'status': 'processing'};
        now = now.add(CoachRepository.workTimeout + const Duration(minutes: 1));

        final archive = await repositoryOf().refresh();

        expect(archive.pending, isNull);
        expect(archive.lastError, contains('non ha finito'));
      },
    );

    test('un fallimento dichiarato riporta il codice del Mac', () async {
      await enqueue();
      gateway.jobRow = {
        'status': 'failed',
        'error_code': 'COACH_CLAUDE_TIMEOUT',
      };

      final archive = await repositoryOf().refresh();

      expect(archive.lastError, contains('COACH_CLAUDE_TIMEOUT'));
      expect(archive.lastError, contains('numeri qui sotto restano validi'));
    });

    test(
      'offline non si dichiara nulla: l\'errore risale e si riprova',
      () async {
        await enqueue();
        gateway.fetchError = const CoachException('rete', retryable: true);

        await expectLater(
          repositoryOf().refresh(),
          throwsA(isA<CoachException>()),
        );
        expect((await store.read()).pending, isNotNull);
      },
    );

    test(
      'ma se non si riesce a chiedere per tutta la finestra, si dice',
      () async {
        await enqueue();
        gateway.fetchError = const CoachException('rete', retryable: true);
        now = now.add(
          CoachRepository.queuedTimeout + const Duration(minutes: 1),
        );

        final archive = await repositoryOf().refresh();

        expect(archive.pending, isNull);
        expect(archive.lastError, contains('connessione'));
      },
    );

    test('senza niente in volo il giro è un no-op', () async {
      final archive = await repositoryOf().refresh();

      expect(archive.pending, isNull);
      expect(archive.lastError, isNull);
    });
  });

  group('il commento vecchio', () {
    test('sopravvive a un fallimento del tentativo nuovo', () async {
      await repositoryOf().requestNarrative(
        profileId: 'marco',
        metrics: metrics,
      );
      gateway.jobRow = {
        'status': 'needs_review',
        'result': {
          'paragraphs': ['Il deficit sta reggendo.'],
        },
      };
      await repositoryOf().refresh();

      // Seconda richiesta, questa volta il Mac tace.
      await repositoryOf().requestNarrative(
        profileId: 'marco',
        metrics: metrics,
      );
      gateway.jobRow = {'status': 'queued'};
      now = now.add(CoachRepository.queuedTimeout + const Duration(minutes: 1));
      final archive = await repositoryOf().refresh();

      expect(archive.last!.paragraphs, ['Il deficit sta reggendo.']);
      expect(archive.lastError, isNotNull);
    });
  });

  group('la rinuncia', () {
    test('smette di aspettare senza toccare il commento vecchio', () async {
      await repositoryOf().requestNarrative(
        profileId: 'marco',
        metrics: metrics,
      );

      final archive = await repositoryOf().cancelPending();

      expect(archive.pending, isNull);
      expect(archive.lastError, isNull);
    });
  });
}
