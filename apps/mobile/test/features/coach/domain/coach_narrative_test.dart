import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

import '../fixtures.dart';

final DateTime writtenAt = DateTime.utc(2026, 8, 2, 21);

CoachNarrative? parse(Object? raw) =>
    CoachNarrative.fromResult(raw, week: testWeek, writtenAt: writtenAt);

void main() {
  group('il modello scrive solo parole', () {
    test('un capoverso con una cifra sparisce, il resto resta', () {
      final narrative = parse({
        'headline': 'Settimana solida',
        'paragraphs': [
          'Hai tenuto il deficit senza svuotarti.',
          'Sei stato circa 600 kcal sotto il tuo consumo.',
          'La massa magra ha retto: continua così.',
        ],
      });

      expect(narrative, isNotNull);
      expect(narrative!.paragraphs, hasLength(2));
      expect(narrative.droppedParagraphs, 1);
      expect(narrative.paragraphs.any((text) => text.contains('600')), isFalse);
    });

    test('un titolo con una cifra sparisce da solo', () {
      final narrative = parse({
        'headline': 'Meno 0,5 kg',
        'paragraphs': ['Il deficit sta reggendo.'],
      });

      expect(narrative!.headline, isNull);
      expect(narrative.paragraphs, hasLength(1));
    });

    test('se sono tutti numerici non c\'è commento da mostrare', () {
      final narrative = parse({
        'paragraphs': ['2750 kcal di consumo.', '−0,5 kg in 7 giorni.'],
      });

      expect(narrative, isNull);
    });

    test(
      'il tetto dei capoversi vale, il resto viene contato come scartato',
      () {
        final narrative = parse({
          'paragraphs': [
            for (var index = 0; index < 8; index++)
              'Capoverso senza cifre numero ${'x' * index}.',
          ],
        });

        expect(narrative!.paragraphs, hasLength(CoachNarrative.maxParagraphs));
        expect(narrative.droppedParagraphs, 3);
      },
    );

    test('un capoverso lunghissimo viene scartato', () {
      final narrative = parse({
        'paragraphs': [
          'x' * (CoachNarrative.maxParagraphLength + 1),
          'Questo invece va bene.',
        ],
      });

      expect(narrative!.paragraphs, ['Questo invece va bene.']);
      expect(narrative.droppedParagraphs, 1);
    });
  });

  group('un risultato illeggibile', () {
    test('non lancia: vale come commento assente', () {
      expect(parse(null), isNull);
      expect(parse('una stringa'), isNull);
      expect(parse({'paragraphs': 'non una lista'}), isNull);
      expect(parse({'paragraphs': <Object?>[]}), isNull);
      expect(
        parse({
          'paragraphs': <Object?>[42, true],
        }),
        isNull,
      );
    });
  });

  group('l\'archivio', () {
    test('sopravvive a un giro di JSON', () {
      final narrative = parse({
        'headline': 'Settimana solida',
        'paragraphs': ['Il deficit sta reggendo.'],
      })!;
      final archive = const CoachArchive.empty().copyWith(
        last: narrative,
        pending: CoachPendingJob(
          jobId: 'job-1',
          week: testWeek,
          requestedAt: writtenAt,
        ),
      );

      final restored = CoachArchive.fromJson(archive.toJson());

      expect(restored.last!.paragraphs, narrative.paragraphs);
      expect(restored.last!.headline, 'Settimana solida');
      expect(restored.last!.week.end, testWeek.end);
      expect(restored.pending!.jobId, 'job-1');
      expect(restored.lastError, isNull);
    });

    test('un archivio rovinato non impedisce di aprire la schermata', () {
      final restored = CoachArchive.fromJson({
        'last': {'week_end': 'non-una-data'},
        'pending': {'job_id': 'job-1'},
        'last_error': 'Il Mac non ha risposto.',
      });

      expect(restored.last, isNull);
      expect(restored.pending, isNull);
      expect(restored.lastError, 'Il Mac non ha risposto.');
    });

    test(
      'il commento vecchio resta anche quando l\'ultimo tentativo fallisce',
      () {
        final narrative = parse({
          'paragraphs': ['Il deficit sta reggendo.'],
        })!;
        final archive = const CoachArchive.empty()
            .copyWith(last: narrative)
            .copyWith(clearPending: true, lastError: 'Il Mac non ha risposto.');

        expect(archive.last, isNotNull);
        expect(archive.pending, isNull);
        expect(archive.lastError, isNotNull);
      },
    );

    test('la settimana del commento dice se è vecchio', () {
      final narrative = parse({
        'paragraphs': ['Il deficit sta reggendo.'],
      })!;

      expect(narrative.week.end, testWeek.end);
      expect(
        narrative.week.end == CoachWeek(end: DateTime.utc(2026, 8, 9)).end,
        isFalse,
      );
    });
  });
}
