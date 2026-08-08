import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// **Le serie da cui la doppia progressione parte.**
///
/// `load_progression.dart` non tocca il database di proposito: sa dire cosa
/// proporre a partire da serie già lette. Quelle serie però non gliele
/// passava nessuno, ed è il motivo per cui quel dominio è rimasto acceso e
/// senza chiamanti. Questo è il pezzo che mancava.
///
/// Solo lettura, e una lettura sola: per ogni esercizio chiesto, le serie
/// dell'ULTIMA seduta in cui compare.
class LoadProgressionRepository {
  LoadProgressionRepository(this._database);

  final AppDatabase _database;

  /// Le serie di lavoro dell'ultima seduta di ognuno degli esercizi chiesti,
  /// per `exercise_ref_id`. Un esercizio mai allenato semplicemente non
  /// compare nella mappa.
  ///
  /// **Cosa resta fuori, e perché.** Le sedute ancora aperte (`ended_at`
  /// nullo) non sono un allenamento finito: leggerle farebbe proporre un
  /// gradino su una seduta in corso. I blocchi di riscaldamento e di
  /// defaticamento non sono lavoro, e lì non c'è niente da far progredire —
  /// mentre le SERIE di riscaldamento dentro un blocco di lavoro arrivano
  /// eccome, perché sia `LoadProgression.advise` a scartarle dichiarandolo.
  ///
  /// Delle cinque metriche si leggono solo le quattro che la progressione
  /// guarda (carico, ripetizioni, sforzo, spunta): durata e distanza non
  /// entrano in nessuna sua regola, e portarsele dietro darebbe l'idea che
  /// qualcuno le stia usando.
  Future<Map<String, List<WorkoutSet>>> lastWorkSets({
    required String profileId,
    required Iterable<String> exerciseRefIds,
  }) async {
    final ids = {...exerciseRefIds}.toList(growable: false);
    if (ids.isEmpty) {
      return const {};
    }

    // Niente sottoquery correlata per trovare la seduta più recente: le righe
    // arrivano già dalla più nuova alla più vecchia e si tiene la prima
    // seduta di ogni esercizio. Costa una scansione dello storico di quegli
    // esercizi — che sono quelli di una scheda, non il catalogo — e in cambio
    // la query resta leggibile.
    final placeholders = [
      for (var index = 0; index < ids.length; index++) '?${index + 2}',
    ].join(', ');
    final rows = await _database
        .customSelect(
          '''
SELECT
  we.exercise_ref_id AS exercise_ref_id,
  we.workout_id      AS workout_id,
  s.weight_kg        AS weight_kg,
  s.reps             AS reps,
  s.rpe              AS rpe,
  s.is_warmup        AS is_warmup,
  s.completed        AS completed
FROM workout_exercises we
JOIN workouts w ON w.id = we.workout_id
JOIN workout_sets s ON s.workout_exercise_id = we.id
WHERE w.profile_id = ?1
  AND w.deleted_at IS NULL
  AND w.ended_at IS NOT NULL
  AND we.is_warmup = 0
  AND we.is_cooldown = 0
  AND we.exercise_ref_id IN ($placeholders)
ORDER BY w.started_at DESC, we.workout_id, we.position, s.position''',
          variables: [
            Variable<String>(profileId),
            for (final id in ids) Variable<String>(id),
          ],
          readsFrom: {
            _database.workouts,
            _database.workoutExercises,
            _database.workoutSets,
          },
        )
        .get();

    final sets = <String, List<WorkoutSet>>{};
    // Quale seduta è «l'ultima» si decide alla prima riga che nomina
    // l'esercizio, e da lì non cambia: due sedute con lo stesso istante di
    // inizio fonderebbero le loro serie in un conto solo, e quel conto direbbe
    // «tutte le serie in cima» su una seduta che non è mai esistita.
    final chosen = <String, String>{};
    for (final row in rows) {
      final exerciseRefId = row.read<String>('exercise_ref_id');
      final workoutId = row.read<String>('workout_id');
      final last = chosen.putIfAbsent(exerciseRefId, () => workoutId);
      if (last != workoutId) {
        continue;
      }
      (sets[exerciseRefId] ??= <WorkoutSet>[]).add(
        WorkoutSet(
          weightKg: row.readNullable<double>('weight_kg'),
          reps: row.readNullable<int>('reps'),
          rpe: row.readNullable<int>('rpe'),
          isWarmup: row.read<bool>('is_warmup'),
          completed: row.read<bool>('completed'),
        ),
      );
    }
    return sets;
  }
}
