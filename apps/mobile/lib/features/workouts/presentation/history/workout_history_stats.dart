import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_formatting.dart';

/// La finestra temporale scelta in cima alla lista. Sono gli stessi cinque
/// tagli di Gym: cambiarli qui li cambia ovunque.
enum WorkoutPeriod {
  week('Settimana', Duration(days: 7)),
  month('Mese', Duration(days: 30)),
  threeMonths('3 mesi', Duration(days: 90)),
  year('Anno', Duration(days: 365)),
  all('Tutto', null);

  const WorkoutPeriod(this.label, this.window);

  final String label;

  /// Null significa «senza limite»: è il taglio «Tutto».
  final Duration? window;
}

/// I totali del periodo.
class WorkoutHistoryStats {
  const WorkoutHistoryStats({
    required this.sessions,
    required this.volume,
    required this.kcal,
    required this.time,
    required this.suspectSessions,
  });

  static const empty = WorkoutHistoryStats(
    sessions: 0,
    volume: 0,
    kcal: 0,
    time: Duration.zero,
    suspectSessions: 0,
  );

  /// Sessioni chiuse nel periodo.
  final int sessions;

  final double volume;
  final double kcal;

  /// Tempo sommato SENZA le sessioni con durata non attendibile.
  final Duration time;

  /// Quante ne sono state lasciate fuori dal tempo. Non è un dettaglio da
  /// nascondere: senza dirlo, escludere una sessione sarebbe una rettifica
  /// silenziosa esattamente come sommarne una da 536 ore.
  final int suspectSessions;

  bool get hasSuspect => suspectSessions > 0;
}

/// Le sessioni di un mese, con i suoi totali.
class WorkoutMonthGroup {
  const WorkoutMonthGroup({
    required this.key,
    required this.label,
    required this.sessions,
    required this.volume,
    required this.kcal,
  });

  final String key;
  final String label;
  final List<WorkoutSummary> sessions;
  final double volume;
  final double kcal;
}

/// Taglia la lista sulla finestra scelta, guardando l'inizio della sessione.
List<WorkoutSummary> filterByPeriod(
  List<WorkoutSummary> sessions,
  WorkoutPeriod period,
  DateTime now,
) {
  final window = period.window;
  if (window == null) {
    return sessions;
  }
  final cutoff = now.toUtc().subtract(window);
  return sessions
      .where((session) => session.startedAt.isAfter(cutoff))
      .toList(growable: false);
}

/// Somma il periodo con la regola di Gym: contano solo le sessioni chiuse.
///
/// L'unico scostamento è il tempo, che salta le sessioni marcate come
/// durata non attendibile — e lo dichiara in [WorkoutHistoryStats.suspectSessions].
/// Sommare una sessione rimasta aperta 536 ore renderebbe il totale una
/// bugia, e correggerla in silenzio pure.
WorkoutHistoryStats aggregateHistory(List<WorkoutSummary> sessions) {
  var count = 0;
  var volume = 0.0;
  var kcal = 0.0;
  var minutes = 0;
  var suspect = 0;

  for (final session in sessions) {
    if (session.inProgress) {
      continue;
    }
    count++;
    volume += session.totalVolume;
    kcal += session.totalKcal ?? 0;
    if (session.durationSuspect) {
      suspect++;
      continue;
    }
    minutes += session.duration?.inMinutes ?? 0;
  }

  return WorkoutHistoryStats(
    sessions: count,
    volume: volume,
    kcal: kcal,
    time: Duration(minutes: minutes),
    suspectSessions: suspect,
  );
}

/// Raggruppa per mese conservando l'ordine di arrivo (dal più recente).
///
/// Il mese si calcola sull'ora di Roma: sull'istante UTC una sessione del
/// primo del mese alle 00:30 finirebbe nel mese prima.
List<WorkoutMonthGroup> groupByMonth(List<WorkoutSummary> sessions) {
  final order = <String>[];
  final grouped = <String, List<WorkoutSummary>>{};

  for (final session in sessions) {
    final key = monthKey(session.startedAt);
    if (!grouped.containsKey(key)) {
      order.add(key);
      grouped[key] = <WorkoutSummary>[];
    }
    grouped[key]!.add(session);
  }

  return order
      .map((key) {
        final items = grouped[key]!;
        return WorkoutMonthGroup(
          key: key,
          label: formatMonth(items.first.startedAt),
          sessions: items,
          volume: items.fold<double>(
            0,
            (total, session) => total + session.totalVolume,
          ),
          kcal: items.fold<double>(
            0,
            (total, session) => total + (session.totalKcal ?? 0),
          ),
        );
      })
      .toList(growable: false);
}

/// L'istante «adesso» con cui tagliare i periodi. Passa da [AppTime] perché
/// l'app ragiona sempre sul fuso di Roma, anche quando confronta istanti.
DateTime historyNow() => AppTime.nowUtc();
