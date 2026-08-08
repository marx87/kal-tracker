import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/domain/neat_trend.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

import '../fixtures.dart';

void main() {
  setUp(AppTime.initialize);

  group('le medie della settimana', () {
    test('senza pesate non c\'è nessuna media, e si vede', () {
      final averages = CoachAverages.of(const [], testWeek);

      expect(averages.hasWeight, isFalse);
      expect(averages.dayCount, 0);
      expect(averages.isSolid, isFalse);
    });

    test(
      'quattro salite sulla bilancia lo stesso giorno valgono un giorno',
      () {
        final day = DateTime.utc(2026, 8, 1);
        final averages = CoachAverages.of([
          weighIn(day, weightKg: 95, id: 'a'),
          weighIn(day, weightKg: 96, id: 'b'),
          weighIn(day, weightKg: 95, id: 'c'),
          weighIn(day, weightKg: 96, id: 'd'),
          weighIn(DateTime.utc(2026, 7, 31), weightKg: 90, id: 'e'),
        ], testWeek);

        // Senza il collasso per giorno la media sarebbe 94,4: il giorno con
        // quattro letture peserebbe quattro volte tanto. Il giorno vale una
        // pesata sola — la prima — quindi 95 e 90, non la media delle quattro:
        // fra la prima salita e le successive c'è quello che si è bevuto e
        // mangiato in mezzo, che non è né grasso né rumore.
        expect(averages.dayCount, 2);
        expect(averages.weightKg, closeTo(92.5, 0.001));
      },
    );

    test('le pesate fuori settimana non entrano', () {
      final averages = CoachAverages.of([
        weighIn(DateTime.utc(2026, 8, 2), weightKg: 95),
        weighIn(DateTime.utc(2026, 7, 26), weightKg: 80),
      ], testWeek);

      expect(averages.dayCount, 1);
      expect(averages.weightKg, closeTo(95, 0.001));
    });

    test('la composizione si media solo sulle letture che ce l\'hanno', () {
      final averages = CoachAverages.of([
        weighIn(DateTime.utc(2026, 7, 30), weightKg: 96, bodyFatPct: 25),
        weighIn(DateTime.utc(2026, 7, 31), weightKg: 95),
        weighIn(DateTime.utc(2026, 8, 1), weightKg: 94, bodyFatPct: 25),
      ], testWeek);

      expect(averages.dayCount, 3);
      expect(averages.compositionDays, 2);
      expect(averages.hasComposition, isTrue);
      // (96×0,25 + 94×0,25) / 2 = 23,75
      expect(averages.fatMassKg, closeTo(23.75, 0.001));
      expect(averages.leanMassKg, closeTo(71.25, 0.001));
      // Il peso medio comprende anche la pesata senza impedenza.
      expect(averages.weightKg, closeTo(95, 0.001));
    });

    test('l\'acqua viene dalla stessa lettura di peso e masse', () {
      // Finché l'acqua era una media a parte si muoveva da sola: bastava una
      // pesata serale in più perché la percentuale settimanale saltasse senza
      // che il corpo avesse fatto niente. E quel salto finiva a spiegare i
      // movimenti del peso e ad accendere il semaforo del sovrallenamento.
      final day = DateTime.utc(2026, 8, 1);
      final averages = CoachAverages.of([
        weighIn(day, weightKg: 95, bodyFatPct: 25, waterPct: 54, id: 'a'),
        weighIn(day, weightKg: 95, bodyFatPct: 25, waterPct: 56, id: 'b'),
        weighIn(
          DateTime.utc(2026, 7, 31),
          weightKg: 95,
          bodyFatPct: 25,
          waterPct: 50,
        ),
      ], testWeek);

      // 54 e 50: la lettura scelta del primo giorno e quella del secondo.
      // Non 52,5, che sarebbe la media di 'a' e 'b' del primo giorno.
      expect(averages.bodyWaterPct, closeTo(52.0, 0.001));
    });

    test('tre giorni fanno una media solida, due no', () {
      final two = CoachAverages.of([
        weighIn(DateTime.utc(2026, 8, 1), weightKg: 95),
        weighIn(DateTime.utc(2026, 8, 2), weightKg: 95),
      ], testWeek);
      final three = CoachAverages.of([
        weighIn(DateTime.utc(2026, 7, 31), weightKg: 95),
        weighIn(DateTime.utc(2026, 8, 1), weightKg: 95),
        weighIn(DateTime.utc(2026, 8, 2), weightKg: 95),
      ], testWeek);

      expect(two.isSolid, isFalse);
      expect(three.isSolid, isTrue);
    });
  });

  group('le calorie della settimana', () {
    test('i giorni senza diario non valgono zero: non ci sono', () {
      final intake = CoachIntake.of([
        CoachDiaryDay(
          day: DateTime.utc(2026, 8, 1),
          kcal: 2000,
          proteinGrams: 140,
        ),
        CoachDiaryDay(
          day: DateTime.utc(2026, 8, 2),
          kcal: 2200,
          proteinGrams: 150,
        ),
      ]);

      expect(intake.days, 2);
      expect(intake.averageKcal, closeTo(2100, 0.001));
      expect(intake.averageProteinGrams, closeTo(145, 0.001));
    });

    test('senza nessun giorno non c\'è media da mostrare', () {
      final intake = CoachIntake.of(const []);

      expect(intake.hasData, isFalse);
      expect(intake.averageKcal, isNull);
    });
  });

  group('la fotografia', () {
    test('la massa magra è quella dell\'ultima pesata che ce l\'aveva', () {
      final snapshot = CoachSnapshot(
        week: testWeek,
        weighIns: [
          weighIn(DateTime.utc(2026, 7, 28), weightKg: 96, bodyFatPct: 25),
          // Più recente ma senza impedenza: non cancella la massa magra.
          weighIn(DateTime.utc(2026, 8, 2), weightKg: 95),
        ],
      );

      expect(snapshot.latestFatFreeMassKg, closeTo(72, 0.001));
    });

    test('senza nessuna pesata completa la massa magra manca', () {
      final snapshot = CoachSnapshot(
        week: testWeek,
        weighIns: [weighIn(DateTime.utc(2026, 8, 2), weightKg: 95)],
      );

      expect(snapshot.latestFatFreeMassKg, isNull);
    });

    test('senza check-in il movimento non ha niente da dire', () {
      // Nullo, non «zero passi»: il rapporto non deve rimproverare un campo
      // che Marco non ha mai promesso di compilare.
      expect(CoachSnapshot(week: testWeek).neat, isNull);
    });

    test('il movimento della settimana si confronta con quella prima', () {
      final snapshot = CoachSnapshot(
        week: testWeek,
        checkIns: checkInLog(
          lastDay: testWeek.end,
          steps: [...List.filled(7, 4000), ...List.filled(7, 10000)],
        ),
      );

      final neat = snapshot.neat!;
      expect(neat.current, closeTo(4000, 0.001));
      expect(neat.previous, closeTo(10000, 0.001));
      expect(neat.direction, NeatDirection.down);
      // La frase arriva già scritta dal dominio del check-in, causa compresa.
      expect(neat.line, contains('prima di togliere calorie'));
    });

    test('la misura è quella con più giorni segnati', () {
      final snapshot = CoachSnapshot(
        week: testWeek,
        checkIns: checkInLog(
          lastDay: testWeek.end,
          steps: const [8000, 8000, 8000],
          walkMinutes: const [40, 40, 40, 40, 40],
        ),
      );

      // Passi e minuti raccontano la stessa camminata: due righe darebbero lo
      // stesso fatto con due numeri diversi.
      expect(snapshot.neat!.measure, NeatMeasure.walkMinutes);
    });

    test('i giorni fuori dalle due settimane non entrano', () {
      final snapshot = CoachSnapshot(
        week: testWeek,
        checkIns: checkInLog(
          lastDay: testWeek.end,
          // Sette giorni segnati, poi il vuoto: la settimana prima non esiste
          // e il confronto sparisce invece di nascere da un giorno solo.
          steps: [
            ...List.filled(7, 4000),
            ...List.filled(7, null),
            ...List.filled(7, 10000),
          ],
        ),
      );

      final neat = snapshot.neat!;
      expect(neat.currentDays, 7);
      expect(neat.previousDays, 0);
      expect(neat.hasComparison, isFalse);
      expect(neat.direction, NeatDirection.unknown);
    });

    test('le finestre filtrano diario, sessioni e acqua', () {
      final snapshot = CoachSnapshot(
        week: testWeek,
        diary: diaryWeek(
          lastDay: DateTime.utc(2026, 8, 2),
          kcal: 2000,
          proteinGrams: 140,
          days: 14,
        ),
        sessions: [
          session(DateTime.utc(2026, 7, 28), rpe: 7),
          session(DateTime.utc(2026, 7, 21), rpe: 6),
        ],
        water: [
          CoachWaterDay(day: DateTime.utc(2026, 8, 1), milliliters: 2000),
          CoachWaterDay(day: DateTime.utc(2026, 7, 20), milliliters: 1000),
        ],
      );

      expect(snapshot.diaryIn(testWeek), hasLength(7));
      expect(snapshot.diaryIn(testWeek.previous), hasLength(7));
      expect(snapshot.sessionsIn(testWeek), hasLength(1));
      expect(snapshot.waterIn(testWeek), hasLength(1));
      expect(
        snapshot.waterIn(CoachWeek(end: DateTime.utc(2026, 7, 26))),
        hasLength(1),
      );
    });
  });
}
