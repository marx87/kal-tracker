import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_providers.dart';

/// La sessione rimasta aperta, se c'è.
///
/// Ne esiste al massimo una per profilo, e non è una convenzione: è l'indice
/// unico parziale `idx_workouts_one_active` sul database.
@immutable
class OpenWorkoutSession {
  const OpenWorkoutSession({
    required this.id,
    required this.startedAt,
    this.routineName,
  });

  final String id;

  /// Istante di inizio, in UTC.
  final DateTime startedAt;

  /// Il nome della scheda com'era all'avvio. Nullo per una sessione libera.
  final String? routineName;
}

/// L'allenamento che il piano settimanale prevede per oggi.
@immutable
class PlannedTraining {
  const PlannedTraining({
    required this.name,
    this.routineId,
    this.isMissing = false,
  });

  final String name;

  /// Nullo quando la scheda è stata cancellata: resta il nome congelato nel
  /// piano, ma non c'è più niente da aprire.
  final String? routineId;

  /// Vero quando la scheda del piano non esiste più. Si dice, non si
  /// nasconde: nove sessioni storiche puntano a schede cancellate e
  /// ricollegarle per nome creerebbe una falsa storia.
  final bool isMissing;
}

/// Cosa dice la palestra a proposito di oggi.
@immutable
class TodayTraining {
  const TodayTraining({
    this.openSession,
    this.planned,
    this.hasWeeklyPlan = false,
  });

  const TodayTraining.none()
    : openSession = null,
      planned = null,
      hasWeeklyPlan = false;

  final OpenWorkoutSession? openSession;
  final PlannedTraining? planned;

  /// Vero quando il piano settimanale esiste, anche se oggi è vuoto: è la
  /// differenza fra «oggi riposo» e «non hai un piano».
  final bool hasWeeklyPlan;

  /// Giorno di scarico: il piano c'è e per oggi non prevede niente.
  bool get isRestDay => openSession == null && planned == null && hasWeeklyPlan;

  /// Niente da dire: nessuna sessione aperta e nessun piano. La schermata
  /// Oggi non mostra la card del tutto — una card che dice «non c'è niente»
  /// è comunque una card in più da leggere.
  bool get isSilent => openSession == null && planned == null && !hasWeeklyPlan;
}

/// L'allenamento di oggi.
///
/// La sessione aperta arriva dal suo stream Drift; il piano usa la stessa
/// sorgente reattiva della schermata Piano. In questo modo cambiare il giorno
/// di una scheda aggiorna subito Oggi, anche quando non cambia nessuna
/// sessione.
final todayTrainingProvider = StreamProvider<TodayTraining>((ref) async* {
  final database = ref.watch(databaseProvider);
  final weekday = ref.watch(todayProvider).weekday;
  final plannedWorkouts = ref.watch(plannedWorkoutsProvider).valueOrNull;
  if (plannedWorkouts == null) {
    return;
  }
  final profile = await ref.watch(marcoProfileProvider.future);

  final openQuery = database.select(database.workouts)
    ..where(
      (row) =>
          row.profileId.equals(profile.id) &
          row.endedAt.isNull() &
          row.deletedAt.isNull(),
    )
    ..orderBy([(row) => OrderingTerm.desc(row.startedAt)])
    ..limit(1);

  yield* openQuery.watch().asyncMap(
    (rows) => _build(
      database: database,
      weekday: weekday,
      plannedWorkouts: plannedWorkouts,
      open: rows.isEmpty ? null : rows.first,
    ),
  );
});

Future<TodayTraining> _build({
  required AppDatabase database,
  required int weekday,
  required List<PlannedWorkout> plannedWorkouts,
  required LocalWorkout? open,
}) async {
  Future<LocalRoutine?> liveRoutine(String? id) async {
    if (id == null) {
      return null;
    }
    return (database.select(database.routines)
          ..where((row) => row.id.equals(id) & row.deletedAt.isNull()))
        .getSingleOrNull();
  }

  final workout = plannedWorkouts
      .where((candidate) => candidate.weekday == weekday)
      .firstOrNull;
  final planned = workout == null
      ? null
      : PlannedTraining(
          name: workout.routineName,
          routineId: workout.routineId,
          isMissing: workout.isMissing,
        );

  OpenWorkoutSession? session;
  if (open != null) {
    final routine = await liveRoutine(open.routineId);
    session = OpenWorkoutSession(
      id: open.id,
      startedAt: open.startedAt,
      routineName: open.routineNameSnapshot ?? routine?.name,
    );
  }

  return TodayTraining(
    openSession: session,
    planned: planned,
    hasWeeklyPlan: plannedWorkouts.isNotEmpty,
  );
}
