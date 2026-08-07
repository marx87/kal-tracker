import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/weekly_muscle_volume.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Il volume settimanale per gruppo muscolare.
///
/// I casi che contano sono due, e sono quelli che hanno motivato la
/// schermata: un gruppo dell'obiettivo rimasto a zero deve VEDERSI, e le
/// serie tenute fuori dal conteggio devono essere dichiarate invece di
/// sparire dentro un numero che sembra completo.

/// La settimana di riferimento dei test: lunedì 3 agosto 2026, ora di Roma.
final _weekStart = DateTime.utc(2026, 8, 3, 12);

WorkoutSet _set({bool completed = true, bool isWarmup = false}) => WorkoutSet(
  weightKg: 40,
  reps: 10,
  completed: completed,
  isWarmup: isWarmup,
);

WorkoutExercise _exercise({
  required String id,
  MuscleGroup? group,
  int sets = 3,
  bool completed = true,
  bool warmupSets = false,
  bool isWarmup = false,
  bool isCooldown = false,
}) => WorkoutExercise(
  exerciseId: id,
  exerciseName: id,
  muscleGroup: group,
  isWarmup: isWarmup,
  isCooldown: isCooldown,
  sets: [
    for (var index = 0; index < sets; index++)
      _set(completed: completed, isWarmup: warmupSets),
  ],
);

Workout _session({
  required String id,
  required DateTime startedAt,
  required List<WorkoutExercise> exercises,
  bool open = false,
}) => Workout(
  id: id,
  startedAt: startedAt,
  endedAt: open ? null : startedAt.add(const Duration(minutes: 50)),
  exercises: exercises,
);

WeeklyMuscleVolume _volume(
  List<Workout> workouts, {
  VolumeIntent intent = VolumeIntent.maintenance,
  Set<MuscleGroup> focus = const <MuscleGroup>{},
}) => weeklyMuscleVolume(
  workouts: workouts,
  weekStart: _weekStart,
  intent: intent,
  focus: focus,
);

void main() {
  group('la banda', () {
    const band = WeeklyVolumeBand(lowSets: 10, highSets: 20);

    test('è un intervallo, non un numero da centrare', () {
      expect(band.label, '10 – 20 serie');
    });

    test('gli estremi sono dentro: dieci serie non sono «poche»', () {
      expect(band.statusOf(10), VolumeBandStatus.inside);
      expect(band.statusOf(15), VolumeBandStatus.inside);
      expect(band.statusOf(20), VolumeBandStatus.inside);
      expect(band.statusOf(9), VolumeBandStatus.below);
      expect(band.statusOf(21), VolumeBandStatus.above);
    });

    test('il mantenimento chiede meno della crescita', () {
      expect(
        VolumeIntent.maintenance.band.lowSets,
        lessThan(VolumeIntent.growth.band.lowSets),
      );
      expect(
        VolumeIntent.maintenance.band.highSets,
        lessThan(VolumeIntent.growth.band.highSets),
      );
    });

    test('ogni combinazione lente/stato ha una frase da leggere', () {
      for (final intent in VolumeIntent.values) {
        for (final status in VolumeBandStatus.values) {
          expect(intent.readingOf(status), isNotEmpty);
          expect(status.label, isNotEmpty);
        }
      }
    });

    test('sopra il mantenimento non è un rimprovero', () {
      final reading = VolumeIntent.maintenance.readingOf(
        VolumeBandStatus.above,
      );

      expect(reading, contains('non è un traguardo da riempire'));
    });
  });

  group('il conteggio', () {
    test('somma le serie completate nel gruppo congelato sulla riga', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 4),
            _exercise(id: 'french', group: MuscleGroup.tricipiti, sets: 3),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.bicipiti)?.sets, 4);
      expect(volume.forGroup(MuscleGroup.tricipiti)?.sets, 3);
      expect(volume.totalSets, 7);
      expect(volume.sessions, 1);
    });

    test('le serie prescritte e mai spuntate non sono stimolo', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 4),
            _exercise(
              id: 'hammer',
              group: MuscleGroup.bicipiti,
              sets: 4,
              completed: false,
            ),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.bicipiti)?.sets, 4);
    });

    test('la stessa serie in due sessioni conta due frequenze', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 5),
          ],
        ),
        _session(
          id: 's2',
          startedAt: _weekStart.add(const Duration(days: 3)),
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 5),
          ],
        ),
      ]);

      final bicipiti = volume.forGroup(MuscleGroup.bicipiti);
      expect(bicipiti?.sets, 10);
      expect(bicipiti?.sessions, 2);
      expect(volume.sessions, 2);
    });

    test('una sessione ancora aperta porta le serie già spuntate', () {
      final volume = _volume([
        _session(
          id: 'oggi',
          startedAt: _weekStart.add(const Duration(days: 2)),
          open: true,
          exercises: [
            _exercise(id: 'alzate', group: MuscleGroup.spalle, sets: 2),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.spalle)?.sets, 2);
      expect(volume.sessions, 1);
    });
  });

  group('quello che resta fuori', () {
    test('riscaldamento e defaticamento non gonfiano nessun gruppo', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(
              id: 'mobilita-spalle',
              group: MuscleGroup.spalle,
              sets: 2,
              isWarmup: true,
            ),
            _exercise(id: 'panca', group: MuscleGroup.petto, sets: 4),
            _exercise(
              id: 'stretching',
              group: MuscleGroup.petto,
              sets: 1,
              isCooldown: true,
            ),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.petto)?.sets, 4);
      expect(volume.forGroup(MuscleGroup.spalle)?.sets, 0);
      expect(volume.warmupAndCooldownSets, 3);
      expect(volume.hasExclusions, isTrue);
    });

    test('anche le serie di avvicinamento dentro un esercizio sono fuori', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(
              id: 'panca',
              group: MuscleGroup.petto,
              sets: 2,
              warmupSets: true,
            ),
            _exercise(id: 'panca-lavoro', group: MuscleGroup.petto, sets: 3),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.petto)?.sets, 3);
      expect(volume.warmupAndCooldownSets, 2);
    });

    test('le righe senza gruppo si dichiarano invece di sparire', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'sconosciuto', sets: 5),
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 3),
          ],
        ),
      ]);

      expect(volume.setsWithoutMuscleGroup, 5);
      expect(volume.totalSets, 3);
      expect(volume.hasExclusions, isTrue);
    });

    test('il full body non si spalma sui gruppi che avrebbe toccato', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'goblet', group: MuscleGroup.fullbody, sets: 6),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.gambe)?.sets, 0);
      expect(volume.forGroup(MuscleGroup.schiena)?.sets, 0);
      final fullbody = volume.forGroup(MuscleGroup.fullbody);
      expect(fullbody?.sets, 6);
      expect(fullbody?.isBanded, isFalse);
      expect(fullbody?.status, VolumeBandStatus.unbanded);
    });

    test('cardio e mobilità si contano ma non si giudicano', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'tapis', group: MuscleGroup.cardio, sets: 4),
          ],
        ),
      ]);

      expect(
        volume.forGroup(MuscleGroup.cardio)?.status,
        VolumeBandStatus.unbanded,
      );
      expect(volume.forGroup(MuscleGroup.mobilita), isNull);
    });
  });

  group('la settimana', () {
    test('sono sette giorni civili e il resto non entra', () {
      final volume = _volume([
        _session(
          id: 'dentro',
          startedAt: _weekStart.add(const Duration(days: 6)),
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 3),
          ],
        ),
        _session(
          id: 'settimana-prima',
          startedAt: _weekStart.subtract(const Duration(days: 1)),
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 9),
          ],
        ),
        _session(
          id: 'settimana-dopo',
          startedAt: _weekStart.add(const Duration(days: 7)),
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 9),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.bicipiti)?.sets, 3);
      expect(volume.firstDay, DateTime.utc(2026, 8, 3));
      expect(volume.lastDay, DateTime.utc(2026, 8, 9));
    });

    test('il giorno è quello di Roma, non quello UTC', () {
      // 22:30 UTC di domenica 2 agosto sono le 00:30 di lunedì 3 a Roma:
      // sull'istante UTC questa sessione finirebbe nella settimana prima.
      final volume = _volume([
        _session(
          id: 'notte-di-lunedi',
          startedAt: DateTime.utc(2026, 8, 2, 22, 30),
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 3),
          ],
        ),
        _session(
          id: 'notte-di-lunedi-prossimo',
          startedAt: DateTime.utc(2026, 8, 9, 22, 30),
          exercises: [
            _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 4),
          ],
        ),
      ]);

      expect(volume.forGroup(MuscleGroup.bicipiti)?.sets, 3);
    });
  });

  group('la domanda vera', () {
    test('un gruppo dell\'obiettivo svuotato si vede, a zero', () {
      // La settimana della spalla limitata: le alzate sono saltate e delle
      // spalle non è rimasto niente.
      final volume = _volume(
        [
          _session(
            id: 's1',
            startedAt: _weekStart,
            exercises: [
              _exercise(id: 'curl', group: MuscleGroup.bicipiti, sets: 6),
              _exercise(id: 'crunch', group: MuscleGroup.addome, sets: 8),
            ],
          ),
        ],
        focus: const {
          MuscleGroup.spalle,
          MuscleGroup.bicipiti,
          MuscleGroup.tricipiti,
          MuscleGroup.addome,
        },
      );

      final spalle = volume.forGroup(MuscleGroup.spalle);
      expect(spalle, isNotNull);
      expect(spalle!.isEmpty, isTrue);
      expect(spalle.status, VolumeBandStatus.below);
      expect(
        volume.emptyBandedGroups.map((entry) => entry.group),
        contains(MuscleGroup.spalle),
      );
      expect(volume.focusGroups.map((entry) => entry.group), [
        MuscleGroup.spalle,
        MuscleGroup.bicipiti,
        MuscleGroup.tricipiti,
        MuscleGroup.addome,
      ]);
    });

    test('«poche serie» e «nessuna serie» non nominano lo stesso gruppo', () {
      // Le due liste finiscono affiancate nella stessa card: se un gruppo a
      // zero stesse in tutt'e due, le spalle verrebbero nominate due volte,
      // una come «sotto la banda» e una come «vuoto».
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'panca', group: MuscleGroup.petto, sets: 2),
            _exercise(id: 'crunch', group: MuscleGroup.addome, sets: 8),
          ],
        ),
      ]);

      final poche = volume.belowBand.map((entry) => entry.group).toSet();
      final vuoti = volume.emptyBandedGroups
          .map((entry) => entry.group)
          .toSet();

      expect(poche.intersection(vuoti), isEmpty);
      expect(poche, contains(MuscleGroup.petto));
      expect(vuoti, contains(MuscleGroup.spalle));
      expect(vuoti, isNot(contains(MuscleGroup.petto)));
      // Il gruppo vuoto resta «sotto la banda» come stato: è la lista a
      // sceglierne uno solo, non la banda a cambiare risposta.
      expect(
        volume.forGroup(MuscleGroup.spalle)?.status,
        VolumeBandStatus.below,
      );
    });

    test('tutti i gruppi con banda ci sono sempre, anche a zero', () {
      final volume = _volume(const []);

      expect(
        volume.groups.map((entry) => entry.group).toSet(),
        bandedMuscleGroups,
      );
      expect(volume.totalSets, 0);
      expect(volume.hasExclusions, isFalse);
    });

    test('la stessa settimana cambia lettura con la lente', () {
      final workouts = [
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'alzate', group: MuscleGroup.spalle, sets: 8),
          ],
        ),
      ];

      final crescita = _volume(workouts, intent: VolumeIntent.growth);
      final mantenimento = _volume(workouts, intent: VolumeIntent.maintenance);

      expect(
        crescita.forGroup(MuscleGroup.spalle)?.status,
        VolumeBandStatus.below,
      );
      expect(
        mantenimento.forGroup(MuscleGroup.spalle)?.status,
        VolumeBandStatus.inside,
      );
      expect(
        mantenimento.belowBand.map((entry) => entry.group),
        isNot(contains(MuscleGroup.spalle)),
      );
    });

    test('l\'ordine dei gruppi non dipende da quante serie hanno', () {
      final volume = _volume([
        _session(
          id: 's1',
          startedAt: _weekStart,
          exercises: [
            _exercise(id: 'crunch', group: MuscleGroup.addome, sets: 12),
            _exercise(id: 'panca', group: MuscleGroup.petto, sets: 1),
          ],
        ),
      ]);

      final ordine = volume.groups.map((entry) => entry.group).toList();
      expect(
        ordine.indexOf(MuscleGroup.petto),
        lessThan(ordine.indexOf(MuscleGroup.addome)),
      );
    });
  });
}
