import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/weekly_plan/data/workout_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_providers.dart';

/// La settimana di allenamenti vista per giorno.
///
/// La sorgente è la STESSA che legge la schermata Piano
/// ([plannedWorkoutsProvider]): comporre la settimana da Palestra e vederla
/// nel piano unificato devono essere due facce di un dato solo, non due
/// letture che possono divergere.
///
/// La mappa ha una voce solo per i giorni con una scheda: il giorno assente è
/// riposo, ed è la stessa convenzione della tabella.
final weeklyScheduleProvider = Provider<AsyncValue<Map<int, PlannedWorkout>>>(
  (ref) => ref
      .watch(plannedWorkoutsProvider)
      .whenData(
        (workouts) => {
          for (final workout in workouts) workout.weekday: workout,
        },
      ),
);

/// Oggi in giorno ISO (1 = lunedì … 7 = domenica), nel fuso di Roma.
///
/// Provider e non `DateTime.now()` dentro il widget: così un test può fissare
/// il giorno senza toccare l'orologio di sistema.
final todayWeekdayProvider = Provider<int>(
  (ref) => AppTime.nowInRome().weekday,
);

/// Le azioni del comporre-settimana. Un solo posto per scrivere, così la
/// schermata resta senza logica e l'annulla riusa esattamente la stessa
/// strada dell'azione che sta annullando.
class WeeklyScheduleController {
  const WeeklyScheduleController(this._repository, this._profileId);

  final WorkoutPlanRepository _repository;
  final String _profileId;

  Future<void> setDay(int weekday, String routineId) => _repository.setDay(
    profileId: _profileId,
    weekday: weekday,
    routineId: routineId,
  );

  Future<void> clearDay(int weekday) =>
      _repository.clearDay(profileId: _profileId, weekday: weekday);

  /// Riporta il giorno com'era: nessuna scheda significa riposo.
  Future<void> restoreDay(int weekday, String? routineId) =>
      routineId == null ? clearDay(weekday) : setDay(weekday, routineId);
}

final weeklyScheduleControllerProvider =
    FutureProvider<WeeklyScheduleController>((ref) async {
      final profile = await ref.watch(marcoProfileProvider.future);
      return WeeklyScheduleController(
        ref.watch(workoutPlanRepositoryProvider),
        profile.id,
      );
    });
