import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/checkin/data/check_in_repository.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';

/// Store Drift del check-in (v7): nei test si sostituisce con quello in
/// memoria. Alla prima lettura porta dentro il vecchio file JSON e lo
/// archivia.
final checkInStoreProvider = Provider<CheckInStore>(
  (ref) => DriftCheckInStore(ref.watch(databaseProvider)),
);

final checkInRepositoryProvider = Provider<CheckInRepository>(
  (ref) => CheckInRepository(ref.watch(checkInStoreProvider)),
);

final checkInControllerProvider =
    AsyncNotifierProvider<CheckInController, CheckInLog>(CheckInController.new);

/// Lo storico dei check-in e le due sole scritture che esistono.
///
/// Ogni operazione aggiorna lo stato e poi persiste: la schermata reagisce
/// subito, il file arriva dopo. È lo stesso patto dell'Obiettivo e delle
/// impostazioni acqua — un check-in da dieci secondi non può aspettare un
/// giro di disco per mostrare il valore appena toccato.
class CheckInController extends AsyncNotifier<CheckInLog> {
  @override
  Future<CheckInLog> build() => ref.watch(checkInRepositoryProvider).read();

  Future<void> setSleepHours(DateTime day, double? hours) async {
    state = AsyncData(
      await ref
          .read(checkInRepositoryProvider)
          .save(day: day, sleepHours: hours, clearSleep: hours == null),
    );
  }

  Future<void> setEnergy(DateTime day, int? score) async {
    state = AsyncData(
      await ref
          .read(checkInRepositoryProvider)
          .save(day: day, energyScore: score, clearEnergy: score == null),
    );
  }

  Future<void> setSteps(DateTime day, int? steps) async {
    state = AsyncData(
      await ref
          .read(checkInRepositoryProvider)
          .save(day: day, steps: steps, clearSteps: steps == null),
    );
  }

  Future<void> setWalkMinutes(DateTime day, int? minutes) async {
    state = AsyncData(
      await ref
          .read(checkInRepositoryProvider)
          .save(
            day: day,
            walkMinutes: minutes,
            clearWalkMinutes: minutes == null,
          ),
    );
  }

  /// «Oggi fermo»: zero passi e zero minuti, in una scrittura sola.
  ///
  /// Serve una scorciatoia perché senza lo zero il campo non funziona — un
  /// giorno fermo e un giorno non segnato devono restare distinguibili — e
  /// arrivarci scendendo di mille passi alla volta significa non arrivarci
  /// mai. [clear] riporta i due campi a «da inserire»: il tocco per sbaglio
  /// si annulla con lo stesso tocco.
  Future<void> setStillDay(DateTime day, {bool clear = false}) async {
    state = AsyncData(
      await ref
          .read(checkInRepositoryProvider)
          .save(
            day: day,
            steps: clear ? null : 0,
            walkMinutes: clear ? null : 0,
            clearSteps: clear,
            clearWalkMinutes: clear,
          ),
    );
  }

  Future<void> clearDay(DateTime day) async {
    state = AsyncData(await ref.read(checkInRepositoryProvider).clearDay(day));
  }
}

/// Il check-in di oggi, o `null` se non è ancora stato toccato.
///
/// Nessun altro pezzo dell'app dipende da questo: senza check-in tutto il
/// resto continua a funzionare.
final todayCheckInProvider = Provider<AsyncValue<DailyCheckIn?>>((ref) {
  final today = ref.watch(todayProvider);
  return ref
      .watch(checkInControllerProvider)
      .whenData((log) => log.forDay(checkInDayOf(today)));
});

/// La pesata di oggi, se c'è.
///
/// Legge lo stato del corpo che l'app ha già (`body_measurements`): il peso
/// non viene duplicato nel check-in, perché due tabelle con lo stesso numero
/// diventano due numeri diversi il giorno in cui una delle due sbaglia.
final todayWeighInProvider = Provider<AsyncValue<WeightPoint?>>((ref) {
  final today = checkInDayOf(ref.watch(todayProvider));
  return ref.watch(bodyStateProvider).whenData((state) {
    final latest = state.latest;
    if (latest == null || checkInDayOf(latest.at) != today) {
      return null;
    }
    return latest;
  });
});
