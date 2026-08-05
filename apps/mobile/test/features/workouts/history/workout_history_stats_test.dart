import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_formatting.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_stats.dart';

WorkoutSummary session({
  required String id,
  required DateTime startedAt,
  Duration? length = const Duration(minutes: 60),
  int? finalDurationSeconds = 3600,
  bool suspect = false,
  double volume = 1000,
  double? kcal = 300,
  bool open = false,
}) {
  return WorkoutSummary(
    id: id,
    startedAt: startedAt,
    endedAt: open ? null : startedAt.add(length ?? Duration.zero),
    finalDurationSeconds: open ? null : finalDurationSeconds,
    durationSuspect: suspect,
    exerciseCount: 3,
    setCount: 9,
    totalVolume: volume,
    totalKcal: kcal,
  );
}

void main() {
  setUpAll(() {
    AppTime.initialize();
    // Fuori da MaterialApp nessuno carica i simboli di data italiani: in app
    // lo fa GlobalMaterialLocalizations, qui va fatto a mano.
    initializeDateFormatting('it');
  });

  group('filtro per periodo', () {
    final now = DateTime.utc(2026, 8, 5, 12);

    test('la settimana taglia via quello che sta più indietro', () {
      final sessions = [
        session(
          id: 'recente',
          startedAt: now.subtract(const Duration(days: 2)),
        ),
        session(
          id: 'vecchia',
          startedAt: now.subtract(const Duration(days: 40)),
        ),
      ];

      expect(
        filterByPeriod(sessions, WorkoutPeriod.week, now).map((s) => s.id),
        ['recente'],
      );
      expect(
        filterByPeriod(sessions, WorkoutPeriod.all, now).map((s) => s.id),
        ['recente', 'vecchia'],
      );
    });
  });

  group('totali', () {
    test('la sessione con durata non attendibile esce dal tempo ma resta '
        'nei conteggi, e viene dichiarata', () {
      final now = DateTime.utc(2026, 8, 5, 12);
      final stats = aggregateHistory([
        session(id: 'normale', startedAt: now, volume: 1000, kcal: 300),
        session(
          id: 'infinita',
          startedAt: now,
          suspect: true,
          finalDurationSeconds: 536 * 3600,
          volume: 500,
          kcal: 100,
        ),
      ]);

      expect(stats.sessions, 2);
      expect(stats.volume, 1500);
      expect(stats.kcal, 400);
      // Solo l'ora della sessione buona: le 536 ore avrebbero reso il
      // totale una barzelletta.
      expect(stats.time, const Duration(hours: 1));
      expect(stats.suspectSessions, 1);
      expect(stats.hasSuspect, isTrue);
    });

    test('una sessione ancora aperta non entra nei totali', () {
      final stats = aggregateHistory([
        session(
          id: 'aperta',
          startedAt: DateTime.utc(2026, 8, 5, 12),
          open: true,
        ),
      ]);

      expect(stats.sessions, 0);
      expect(stats.time, Duration.zero);
    });
  });

  test('il mese si calcola sull’ora di Roma, non su UTC', () {
    // 31 luglio 22:30 UTC in Italia è già il primo agosto.
    final groups = groupByMonth([
      session(id: 'mezzanotte', startedAt: DateTime.utc(2026, 7, 31, 22, 30)),
    ]);

    expect(groups.single.key, '2026-08');
    expect(groups.single.label, 'Agosto 2026');
  });

  group('formattazione', () {
    test('la durata si legge come la si dice', () {
      expect(formatDuration(null), '—');
      expect(formatDuration(const Duration(minutes: 45)), '45min');
      expect(formatDuration(const Duration(hours: 2)), '2h');
      expect(formatDuration(const Duration(hours: 1, minutes: 12)), '1h 12min');
    });

    test('data e ora sono quelle di Roma', () {
      final label = formatSessionMoment(DateTime.utc(2026, 8, 4, 20, 34));

      expect(label, contains('4 ago'));
      // Leggendo l'istante come UTC verrebbero le 20:34 del 4: due ore
      // indietro, e per le sessioni serali il giorno sbagliato.
      expect(label, contains('22:34'));
    });

    test('ogni modalità descrive la serie come faceva Gym', () {
      expect(
        describeSet(
          const WorkoutSetEntry(position: 0, weightKg: 62.5, reps: 8),
          WorkoutTrackingMode.weightReps,
        ),
        '62,5 kg × 8',
      );
      expect(
        describeSet(
          const WorkoutSetEntry(position: 0, reps: 12),
          WorkoutTrackingMode.bodyweightReps,
        ),
        '12 ripetizioni',
      );
      expect(
        describeSet(
          const WorkoutSetEntry(position: 0, durationSec: 45),
          WorkoutTrackingMode.timeOnly,
        ),
        '0:45',
      );
      expect(
        describeSet(
          const WorkoutSetEntry(position: 0, durationSec: 30, weightKg: 10),
          WorkoutTrackingMode.timed,
        ),
        '0:30 · 10 kg',
      );
      expect(
        describeSet(
          const WorkoutSetEntry(
            position: 0,
            durationSec: 1500,
            distanceM: 5000,
          ),
          WorkoutTrackingMode.distanceTime,
        ),
        '25:00 · 5.000 m',
      );
    });

    test('la serie si sente dire per esteso, sigle sciolte', () {
      final spoken = spokenSet(
        const WorkoutSetEntry(
          position: 1,
          weightKg: 60,
          reps: 8,
          rpe: 8,
          completed: true,
        ),
        WorkoutTrackingMode.weightReps,
        number: 2,
      );

      expect(spoken, contains('Serie 2'));
      expect(spoken, contains('chilogrammi'));
      expect(spoken, isNot(contains('kg')));
      expect(spoken, contains('completata'));
    });

    test('la nota sulla durata dice sempre che l’app è rimasta aperta', () {
      final started = DateTime.utc(2026, 5, 1, 9);
      final forgotten = WorkoutSummary(
        id: 'w',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 536)),
        durationSuspect: true,
        exerciseCount: 0,
        setCount: 0,
        totalVolume: 0,
      );

      final note = suspectDurationNote(forgotten);
      expect(note, isNotNull);
      expect(
        note,
        startsWith('Durata non attendibile: l\'app è rimasta aperta'),
      );
      expect(note, contains('536 ore'));

      // Con la durata registrata la nota mette a confronto i due numeri
      // veri, senza sceglierne uno al posto di Marco.
      final mismatched = WorkoutSummary(
        id: 'w2',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 3)),
        finalDurationSeconds: 3600,
        durationSuspect: true,
        exerciseCount: 0,
        setCount: 0,
        totalVolume: 0,
      );
      final second = suspectDurationNote(mismatched);
      expect(second, contains('1h'));
      expect(second, contains('3 ore'));
    });

    test('una durata attendibile non porta nessuna nota', () {
      expect(
        suspectDurationNote(
          session(id: 'ok', startedAt: DateTime.utc(2026, 8, 1, 10)),
        ),
        isNull,
      );
    });
  });
}
