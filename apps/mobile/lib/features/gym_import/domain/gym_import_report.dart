/// Rendiconto di un import di Gym Tracker.
///
/// Risponde a tre domande diverse e tenute separate apposta: quante righe sono
/// entrate (i contatori), quali dati sono storti ma sono entrati comunque
/// ([warnings]) e cosa nessuna tabella ha accolto ([notImported]). Un import
/// che scarta qualcosa in silenzio è indistinguibile da un import riuscito, e
/// questo è un travaso che si fa una volta sola: la prova che nulla è caduto
/// deve stare nel risultato, non nella memoria di chi l'ha lanciato.
class GymImportReport {
  const GymImportReport({
    required this.cooldownPresets,
    required this.exercises,
    required this.routines,
    required this.routineExercises,
    required this.routineIntervalSegments,
    required this.weeklyPlanDays,
    required this.profileStats,
    required this.achievements,
    required this.workouts,
    required this.workoutExercises,
    required this.workoutSets,
    required this.painPoints,
    required this.workoutIntervalSegments,
    required this.bodyMeasurements,
    required this.bodyMeasurementValues,
    required this.syncMutations,
    required this.warnings,
    required this.notImported,
    required this.usedFirestoreDump,
  });

  final int cooldownPresets;
  final int exercises;
  final int routines;
  final int routineExercises;
  final int routineIntervalSegments;
  final int weeklyPlanDays;

  /// 0 o 1: la riga singleton di `workout_profile_stats`.
  final int profileStats;
  final int achievements;
  final int workouts;
  final int workoutExercises;
  final int workoutSets;
  final int painPoints;
  final int workoutIntervalSegments;
  final int bodyMeasurements;
  final int bodyMeasurementValues;

  /// Righe accodate a `sync_outbox`: 0 finché `enqueueSync` resta falso.
  final int syncMutations;

  /// Dati anomali ma importati: schede cancellate ancora citate dallo storico,
  /// sessioni con la durata da orologio non credibile, riferimenti pendenti.
  final List<String> warnings;

  /// Campi presenti nelle sorgenti che nessuna colonna accoglie. Si calcola
  /// dai documenti veri (le chiavi lette meno quelle mappate), non da un
  /// elenco scritto a mano che invecchierebbe al primo cambio di schema.
  final List<String> notImported;

  /// Falso quando il dump Firestore non è stato passato: prescrizioni,
  /// blocchi a tempo e durate al netto delle pause restano fuori.
  final bool usedFirestoreDump;

  int get rowCount =>
      cooldownPresets +
      exercises +
      routines +
      routineExercises +
      routineIntervalSegments +
      weeklyPlanDays +
      profileStats +
      achievements +
      workouts +
      workoutExercises +
      workoutSets +
      painPoints +
      workoutIntervalSegments +
      bodyMeasurements +
      bodyMeasurementValues;

  /// Vero quando il secondo lancio non ha toccato niente: è la prova
  /// dell'idempotenza, quindi non deve dipendere da conteggi approssimati.
  bool get isNoop => rowCount == 0 && syncMutations == 0;

  /// Riepilogo in italiano da mostrare o da mettere a log.
  String describe() {
    final buffer = StringBuffer();
    if (isNoop) {
      buffer.writeln('Nessuna novità: lo storico di Gym Tracker era già qui.');
    } else {
      buffer
        ..writeln('Importato da Gym Tracker:')
        ..writeln(
          '- ${_n(exercises, 'esercizio', 'esercizi')} '
          '(+ $cooldownPresets di defaticamento)',
        )
        ..writeln(
          '- ${_n(routines, 'scheda', 'schede')}, '
          '${_n(routineExercises, 'riga', 'righe')}, '
          '${_n(routineIntervalSegments, 'blocco a tempo', 'blocchi a tempo')}',
        )
        ..writeln(
          '- ${_n(weeklyPlanDays, 'giorno', 'giorni')} di piano settimanale',
        )
        ..writeln(
          '- ${_n(workouts, 'sessione', 'sessioni')}, '
          '${_n(workoutExercises, 'riga', 'righe')}, '
          '${_n(workoutSets, 'serie', 'serie')}',
        )
        ..writeln(
          '- ${_n(painPoints, 'punto dolente', 'punti dolenti')}, '
          '${_n(workoutIntervalSegments, 'marcatore di blocco', 'marcatori di blocco')}',
        )
        ..writeln(
          '- ${_n(bodyMeasurements, 'pesata', 'pesate')} '
          '(${_n(bodyMeasurementValues, 'circonferenza', 'circonferenze')})',
        )
        ..writeln(
          '- ${_n(achievements, 'trofeo', 'trofei')}'
          '${profileStats == 0 ? '' : ', profilo XP'}',
        );
    }
    if (!usedFirestoreDump) {
      buffer.writeln(
        'Senza il dump Firestore: prescrizioni e blocchi a tempo delle schede '
        'non sono nel file di export e restano fuori.',
      );
    }
    for (final warning in warnings) {
      buffer.writeln('! $warning');
    }
    for (final lost in notImported) {
      buffer.writeln('~ $lost');
    }
    return buffer.toString();
  }

  static String _n(int count, String singular, String plural) =>
      '$count ${count == 1 ? singular : plural}';
}
