import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

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

/// L'allenamento di oggi, letto dalle tabelle che ci sono già.
///
/// **Perché la query sta qui e non in un repository.** `features/routines/`
/// e `features/workouts/` non espongono ancora una lettura del piano
/// settimanale né della sessione aperta (l'implementazione Drift di
/// `LiveWorkoutRepository` non è ancora collegata all'app), e quelle cartelle
/// sono di altri. Questa è una lettura sola, senza scritture: quando il
/// repository della palestra arriverà, questo provider gli si appoggia e la
/// query sparisce. È scritto nelle note di consegna.
final todayTrainingProvider = StreamProvider<TodayTraining>((ref) async* {
  // Tutte le `watch` sincrone prima del primo await: nel buco asincrono il
  // provider non deve perdere le dipendenze.
  final database = ref.watch(databaseProvider);
  final weekday = ref.watch(todayProvider).weekday;
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

  // Il piano settimanale si rilegge a ogni cambio della sessione aperta:
  // oggi nessuna schermata lo modifica (arriva dall'import di Gym Tracker),
  // quindi non serve un secondo stream da tenere in vita.
  yield* openQuery.watch().asyncMap(
    (rows) => _build(
      database: database,
      profileId: profile.id,
      weekday: weekday,
      open: rows.isEmpty ? null : rows.first,
    ),
  );
});

Future<TodayTraining> _build({
  required AppDatabase database,
  required String profileId,
  required int weekday,
  required LocalWorkout? open,
}) async {
  final planRows = await (database.select(
    database.routineWeeklyPlan,
  )..where((row) => row.profileId.equals(profileId))).get();
  final hasWeeklyPlan = planRows.any(
    (row) => row.routineId != null || row.routineExternalId != null,
  );

  Future<LocalRoutine?> liveRoutine(String? id) async {
    if (id == null) {
      return null;
    }
    return (database.select(database.routines)
          ..where((row) => row.id.equals(id) & row.deletedAt.isNull()))
        .getSingleOrNull();
  }

  PlannedTraining? planned;
  for (final row in planRows) {
    if (row.weekday != weekday) {
      continue;
    }
    final routine = await liveRoutine(row.routineId);
    final name = routine?.name ?? row.routineNameSnapshot;
    if (name == null) {
      // Riga del piano che non punta più a niente e non conserva il nome:
      // non c'è un allenamento da annunciare.
      continue;
    }
    planned = PlannedTraining(
      name: name,
      routineId: routine?.id,
      isMissing: routine == null,
    );
    break;
  }

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
    hasWeeklyPlan: hasWeeklyPlan,
  );
}
