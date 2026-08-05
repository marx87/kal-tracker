/// La settimana unificata: un giorno, i suoi pasti e il suo allenamento.
///
/// Le due metà nascono in posti diversi e restano tali — i pasti in
/// `weekly_plan_slots` (li compone il Mac), gli allenamenti in
/// `routine_weekly_plan` (li ha decisi Marco nelle schede, giorno ISO →
/// scheda) — ma per chi guarda sono una cosa sola: mercoledì.
///
/// Il montaggio è una funzione pura: niente database, niente Flutter. È
/// anche la ragione per cui la settimana resta leggibile col Mac spento e
/// SENZA piano generato — gli allenamenti ci sono lo stesso, e il giorno si
/// mostra con quello che ha.
library;

import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

/// L'allenamento previsto in un giorno della settimana.
///
/// [routineId] è nullo quando la scheda è stata cancellata dopo essere stata
/// messa in settimana: il nome resta (lo scatto salvato) e il giorno continua
/// a dire «qui ti allenavi», ma non c'è più niente da avviare. Nell'export di
/// Gym succede davvero: il giorno 3 punta a una scheda che non esiste più.
class PlannedWorkout {
  const PlannedWorkout({
    required this.weekday,
    required this.routineName,
    this.routineId,
    this.isCircuit = false,
    this.exerciseCount = 0,
  });

  /// Giorno ISO, 1 = lunedì … 7 = domenica.
  final int weekday;

  final String? routineId;
  final String routineName;

  /// Tutta la scheda è un circuito a tempo: cambia il tipo di sessione, non
  /// solo il contenuto, quindi si dice.
  final bool isCircuit;

  /// Quanti esercizi ha il blocco principale. Zero anche quando la scheda non
  /// c'è più: in quel caso non è «una scheda vuota», è «una scheda che manca».
  final int exerciseCount;

  /// La scheda non è più nel database: si mostra, non si avvia.
  bool get isMissing => routineId == null;
}

/// Una giornata della settimana unificata.
class PlanWeekDay {
  PlanWeekDay({
    required DateTime date,
    this.workout,
    Iterable<WeeklyPlanSlot> meals = const <WeeklyPlanSlot>[],
  }) : date = PlanDate.normalize(date),
       meals = List.unmodifiable(meals);

  final DateTime date;

  /// L'allenamento previsto, o null se è un giorno di riposo.
  final PlannedWorkout? workout;

  /// I pasti pianificati, già in ordine di pasto.
  final List<WeeklyPlanSlot> meals;

  /// Giorno senza niente: né pasti né allenamento.
  bool get isEmpty => workout == null && meals.isEmpty;

  bool get hasWorkout => workout != null;
}

abstract final class PlanWeek {
  /// Quanti giorni si mostrano quando non c'è ancora un piano dei pasti.
  static const int fallbackDays = 7;

  /// Le date da mostrare senza piano: da oggi in avanti, perché la settimana
  /// degli allenamenti non ha un «inizio» proprio come ce l'ha il piano.
  static List<DateTime> upcomingDates(
    DateTime today, {
    int days = fallbackDays,
  }) {
    final start = PlanDate.normalize(today);
    return List.unmodifiable([
      for (var offset = 0; offset < days; offset++)
        PlanDate.addDays(start, offset),
    ]);
  }

  /// Monta i giorni: le date comandano, pasti e allenamenti si appoggiano.
  ///
  /// Gli allenamenti si agganciano per giorno della settimana (è così che
  /// `routine_weekly_plan` li conserva: la stessa scheda torna ogni
  /// mercoledì), i pasti per data esatta.
  static List<PlanWeekDay> build({
    required Iterable<DateTime> dates,
    WeeklyPlan? plan,
    Iterable<PlannedWorkout> workouts = const <PlannedWorkout>[],
  }) {
    final byWeekday = {
      for (final workout in workouts) workout.weekday: workout,
    };
    return List.unmodifiable([
      for (final date in dates.map(PlanDate.normalize))
        PlanWeekDay(
          date: date,
          workout: byWeekday[date.weekday],
          meals: plan?.slotsFor(date) ?? const <WeeklyPlanSlot>[],
        ),
    ]);
  }
}
