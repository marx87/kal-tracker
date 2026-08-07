import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';

/// Legge e scrive il check-in del mattino.
///
/// Ogni scrittura riguarda un giorno solo e vale come sostituzione: il
/// check-in è un modulo da dieci secondi, non un registro a cui si aggiunge.
/// Chi scrive due volte lo stesso giorno lo sta correggendo.
class CheckInRepository {
  CheckInRepository(this._store);

  final CheckInStore _store;

  Future<CheckInLog> read() => _store.read();

  /// Scrive sonno, energia e movimento del giorno.
  ///
  /// I campi sono indipendenti: passare solo [energyScore] non cancella il
  /// sonno già inserito. Per togliere un valore si passa il `clear` che gli
  /// corrisponde — un `null` significa «non lo tocco», e senza questa
  /// distinzione un salvataggio parziale svuoterebbe gli altri campi.
  Future<CheckInLog> save({
    required DateTime day,
    double? sleepHours,
    int? energyScore,
    int? steps,
    int? walkMinutes,
    bool clearSleep = false,
    bool clearEnergy = false,
    bool clearSteps = false,
    bool clearWalkMinutes = false,
  }) async {
    final now = AppTime.nowUtc();
    final log = await _store.read();
    final key = checkInDayOf(day);
    final existing = log.forDay(key);
    final entry = DailyCheckIn(
      day: key,
      updatedAt: now,
      sleepHours: clearSleep
          ? null
          : DailyCheckIn.normalizeSleep(sleepHours) ?? existing?.sleepHours,
      energyScore: clearEnergy
          ? null
          : DailyCheckIn.normalizeEnergy(energyScore) ?? existing?.energyScore,
      // Lo zero passa: `normalizeSteps(0)` torna 0, che non è `null`, quindi
      // «oggi fermo» sovrascrive il valore precedente invece di ereditarlo.
      steps: clearSteps
          ? null
          : DailyCheckIn.normalizeSteps(steps) ?? existing?.steps,
      walkMinutes: clearWalkMinutes
          ? null
          : DailyCheckIn.normalizeWalkMinutes(walkMinutes) ??
                existing?.walkMinutes,
    );
    final updated = log.upsert(entry, now: now);
    await _store.write(updated);
    return updated;
  }

  /// Cancella il check-in di un giorno. Serve a chi si accorge di aver
  /// compilato il giorno sbagliato.
  Future<CheckInLog> clearDay(DateTime day) async {
    final now = AppTime.nowUtc();
    final log = await _store.read();
    final updated = log.upsert(
      DailyCheckIn(day: checkInDayOf(day), updatedAt: now),
      now: now,
    );
    await _store.write(updated);
    return updated;
  }
}
