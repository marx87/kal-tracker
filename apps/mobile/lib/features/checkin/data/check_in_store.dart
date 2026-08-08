import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Persistenza del check-in del mattino.
///
/// L'interfaccia è rimasta quella di sempre — leggi tutto, scrivi tutto — e a
/// cambiare è stata solo l'implementazione: dalla v7 sonno ed energia vivono
/// in `daily_check_ins`, non più in un file JSON accanto al database. Il file
/// li teneva fuori dal backup, fuori dalla sincronizzazione e invisibili al
/// coach, che invece li vuole per il semaforo del sovrallenamento.
///
/// Il patto con chi chiama non cambia: letture indulgenti, scritture best
/// effort, mai un crash. Un check-in perso è un fastidio, un'app che non si
/// apre è un disastro.
abstract class CheckInStore {
  Future<CheckInLog> read();
  Future<void> write(CheckInLog log);
}

/// Il check-in su Drift.
///
/// Una riga per giorno, con [id] DETERMINISTICO (uuid v5 di profilo + giorno):
/// due dispositivi che compilano lo stesso giorno offline scrivono la stessa
/// riga e la sincronizzazione la fonde invece di duplicarla. È la stessa
/// derivazione che `sync_gateway` usa già per gli obiettivi nutrizionali.
///
/// La finestra di [CheckInLog.historyDays] è una finestra della VISTA, non
/// dell'archivio: la tabella conserva tutto, la lettura si ferma a sei mesi
/// come fa `BodyStateRepository` con la composizione corporea. Fuori da quella
/// finestra nessuna scrittura tocca niente — è quello che impedisce alla
/// potatura del log di trasformarsi in cancellazioni vere.
///
/// **Dalla v10 il movimento tiene in piedi la riga da solo.** Fino alla v9 la
/// CHECK della tabella pretendeva sonno o energia, e questo store saltava le
/// giornate di sola camminata per non far abortire la transazione — con il
/// risultato che togliere il sonno da un giorno camminato cancellava anche i
/// passi. Adesso l'unico motivo per non scrivere una voce è che sia vuota:
/// quello che il dominio considera compilato arriva al database.
class DriftCheckInStore implements CheckInStore {
  DriftCheckInStore(
    this._database, {
    FileCheckInStore? legacy,
    Future<String> Function()? profileId,
  }) : _legacy = legacy ?? FileCheckInStore() {
    _resolveProfileId = profileId ?? _marcoProfileId;
  }

  final AppDatabase _database;
  final FileCheckInStore _legacy;
  late final Future<String> Function() _resolveProfileId;

  /// La migrazione del file JSON gira una volta sola per istanza: è la «prima
  /// apertura» di cui parlano le note di consegna.
  Future<void>? _legacyImport;

  @override
  Future<CheckInLog> read() async {
    final profileId = await _resolveProfileId();
    await _importLegacyOnce(profileId);

    final horizon = _horizon();
    final rows =
        await (_database.select(_database.dailyCheckIns)..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.deletedAt.isNull() &
                  row.day.isBiggerOrEqualValue(horizon),
            ))
            .get();

    final entries = <String, DailyCheckIn>{};
    for (final row in rows) {
      final entry = _toDomain(row);
      if (entry != null) {
        entries[entry.dayKey] = entry;
      }
    }
    return CheckInLog(Map.unmodifiable(entries));
  }

  @override
  Future<void> write(CheckInLog log) async {
    final profileId = await _resolveProfileId();
    await _importLegacyOnce(profileId);

    final now = AppTime.nowUtc();
    final horizon = _horizon(now);
    try {
      await _database.transaction(() async {
        // 1. I giorni spariti dal log si tombstonano, non si cancellano: è
        //    così che l'altro dispositivo impara che sono stati svuotati.
        //    Solo dentro la finestra, però — fuori c'è la potatura del log,
        //    che è un dimenticare, non un cancellare.
        final live =
            await (_database.select(_database.dailyCheckIns)..where(
                  (row) =>
                      row.profileId.equals(profileId) &
                      row.deletedAt.isNull() &
                      row.day.isBiggerOrEqualValue(horizon),
                ))
                .get();
        for (final row in live) {
          final key = DailyCheckIn.dayKeyOf(row.day.toUtc());
          // Il giorno rimasto di solo movimento NON si spegne più: dalla v10
          // il punto 2 lo riscrive, e spegnerlo qui vorrebbe dire cancellare i
          // passi per poi reinserirli.
          final entry = log.entries[key];
          if (entry != null && !entry.isEmpty) {
            continue;
          }
          await (_database.update(
            _database.dailyCheckIns,
          )..where((table) => table.id.equals(row.id))).write(
            DailyCheckInsCompanion(
              sleepHours: const Value(null),
              energyScore: const Value(null),
              // Anche il movimento: un tombstone con dentro i passi di ieri
              // li rimanderebbe all'altro dispositivo come se il giorno non
              // fosse mai stato cancellato.
              steps: const Value(null),
              walkMinutes: const Value(null),
              updatedAt: Value(now),
              deletedAt: Value(now),
            ),
          );
          await _appendOutbox(
            entityId: row.id,
            operation: 'delete',
            payload: {
              'id': row.id,
              'profile_id': profileId,
              'day': row.day.toUtc().toIso8601String(),
              'deleted_at': now.toIso8601String(),
              'updated_at': now.toIso8601String(),
            },
            now: now,
          );
        }

        // 2. Il resto è un upsert sulla chiave naturale: un giorno cancellato
        //    e poi ricompilato riprende la sua riga, tombstone compreso.
        for (final entry in log.entries.values) {
          // Resta fuori solo il giorno vuoto, che è il punto 1: scriverlo
          // farebbe contare come «compilato» un giorno in cui non c'è nessuna
          // risposta. Le giornate dei soli passi passano di qui dalla v10.
          if (entry.isEmpty) {
            continue;
          }
          await _upsert(profileId: profileId, entry: entry, now: now);
        }
      });
    } on Object {
      // Stesso patto del file: lo stato in memoria resta coerente per la
      // sessione e la schermata non muore in mano a Marco.
      return;
    }
  }

  Future<void> _upsert({
    required String profileId,
    required DailyCheckIn entry,
    required DateTime now,
  }) async {
    final day = _dayOf(entry);
    await _database
        .into(_database.dailyCheckIns)
        .insert(
          DailyCheckInsCompanion.insert(
            id: checkInRowId(profileId: profileId, day: day),
            profileId: profileId,
            day: day,
            createdAt: now,
            updatedAt: entry.updatedAt,
            sleepHours: Value(entry.sleepHours),
            energyScore: Value(entry.energyScore),
            steps: Value(entry.steps),
            walkMinutes: Value(entry.walkMinutes),
          ),
          onConflict: DoUpdate(
            (_) => DailyCheckInsCompanion(
              sleepHours: Value(entry.sleepHours),
              energyScore: Value(entry.energyScore),
              steps: Value(entry.steps),
              walkMinutes: Value(entry.walkMinutes),
              updatedAt: Value(entry.updatedAt),
              // Riscrivere un giorno lo riporta in vita.
              deletedAt: const Value(null),
            ),
            // Il bersaglio è la chiave naturale e non l'id: una riga scritta
            // da un'altra installazione con un id diverso resta comunque il
            // check-in di quel giorno, e va aggiornata, non duplicata.
            target: [
              _database.dailyCheckIns.profileId,
              _database.dailyCheckIns.day,
            ],
          ),
        );
    final row =
        await (_database.select(_database.dailyCheckIns)..where(
              (table) =>
                  table.profileId.equals(profileId) & table.day.equals(day),
            ))
            .getSingle();
    await _appendOutbox(
      entityId: row.id,
      operation: 'upsert',
      payload: {
        'id': row.id,
        'profile_id': profileId,
        'day': day.toIso8601String(),
        'sleep_hours': entry.sleepHours,
        'energy_score': entry.energyScore,
        'steps': entry.steps,
        'walk_minutes': entry.walkMinutes,
        'updated_at': entry.updatedAt.toUtc().toIso8601String(),
        'deleted_at': null,
      },
      now: now,
    );
  }

  Future<void> _appendOutbox({
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: const Uuid().v4(),
          entityType: 'daily_check_in',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  /// Porta dentro il file JSON delle versioni precedenti e poi lo archivia.
  ///
  /// L'import è additivo (`insertOrIgnore` sulla chiave naturale): quello che
  /// c'è già nella tabella vince sempre — un giorno cancellato apposta non
  /// resuscita dal file — e i giorni che esistono solo nel file entrano. Il
  /// file non viene cancellato ma rinominato: se qualcosa va storto resta lì
  /// da guardare.
  Future<void> _importLegacyOnce(String profileId) =>
      _legacyImport ??= _importLegacy(profileId);

  Future<void> _importLegacy(String profileId) async {
    try {
      if (!await _legacy.exists()) {
        return;
      }
      final log = await _legacy.read();
      if (log.entries.isNotEmpty) {
        await _database.transaction(() async {
          for (final entry in log.entries.values) {
            if (entry.isEmpty) {
              continue;
            }
            final day = _dayOf(entry);
            final existing =
                await (_database.select(_database.dailyCheckIns)..where(
                      (row) =>
                          row.profileId.equals(profileId) & row.day.equals(day),
                    ))
                    .getSingleOrNull();
            if (existing != null) {
              continue;
            }
            // Anche le righe migrate devono entrare nella coda: altrimenti il
            // primo telefono le vede, un secondo dispositivo sincronizzato no.
            await _upsert(
              profileId: profileId,
              entry: entry,
              now: entry.updatedAt.toUtc(),
            );
          }
        });
      }
      await _legacy.archive();
    } on Object {
      // Un file rovinato non deve impedire di aprire la schermata: resta al
      // suo posto e si riproverà alla prossima apertura.
      return;
    }
  }

  DateTime _horizon([DateTime? now]) => checkInDayOf(
    now ?? AppTime.nowUtc(),
  ).subtract(const Duration(days: CheckInLog.historyDays));

  /// Il giorno di una voce, sempre in UTC a mezzanotte: Drift rilegge i
  /// `DateTime` nel fuso locale e senza `toUtc()` il confronto tornerebbe le
  /// 02:00 dell'ora legale.
  DateTime _dayOf(DailyCheckIn entry) {
    final day = entry.day.toUtc();
    return DateTime.utc(day.year, day.month, day.day);
  }

  DailyCheckIn? _toDomain(LocalDailyCheckIn row) {
    final day = row.day.toUtc();
    final entry = DailyCheckIn(
      day: DateTime.utc(day.year, day.month, day.day),
      updatedAt: row.updatedAt.toUtc(),
      sleepHours: row.sleepHours,
      energyScore: row.energyScore,
      steps: row.steps,
      walkMinutes: row.walkMinutes,
    );
    return entry.isEmpty ? null : entry;
  }

  Future<String> _marcoProfileId() async =>
      (await LocalProfileRepository(_database).getOrCreateMarco()).id;
}

/// L'id della riga di un giorno: deterministico, così due dispositivi che
/// compilano lo stesso giorno offline non creano due righe.
///
/// È un uuid v5 sullo spazio dei nomi URL, la stessa forma che
/// `SyncIds.derived` usa per gli obiettivi nutrizionali. Ricalcolarlo qui
/// invece di importarlo evita di trascinare il gateway — e con lui Supabase —
/// dentro un file di persistenza locale; quello che conta è che sia stabile,
/// perché per il gateway un id già uuid passa invariato.
String checkInRowId({required String profileId, required DateTime day}) =>
    const Uuid().v5(
      Namespace.url.value,
      'https://kal-tracker.local/sync/check-in/$profileId/'
      '${DailyCheckIn.dayKeyOf(day)}',
    );

/// Il file JSON delle versioni fino alla v6.
///
/// Non è più la persistenza del check-in: resta come sorgente della migrazione
/// una-tantum e come store di riserva per un ambiente senza database.
class FileCheckInStore implements CheckInStore {
  FileCheckInStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-checkin.json';

  /// Il nome che il file prende dopo essere entrato in Drift: rinominare è
  /// reversibile, cancellare no.
  static const String archivedFileName = 'kal-tracker-checkin.json.migrated';

  final Future<Directory> Function() _directory;

  @override
  Future<CheckInLog> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const CheckInLog.empty();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const CheckInLog.empty();
      }
      return CheckInLog.fromJson(decoded);
    } on Object {
      return const CheckInLog.empty();
    }
  }

  @override
  Future<void> write(CheckInLog log) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(log.toJson()), flush: true);
    } on Object {
      // Lo stato in memoria resta coerente per la sessione.
      return;
    }
  }

  Future<bool> exists() async {
    try {
      return (await _file()).existsSync();
    } on Object {
      return false;
    }
  }

  Future<void> archive() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return;
      }
      final directory = await _directory();
      await file.rename('${directory.path}/$archivedFileName');
    } on Object {
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

/// Store in memoria: serve ai test e a un ambiente senza filesystem (i widget
/// test non hanno `path_provider`).
class InMemoryCheckInStore implements CheckInStore {
  InMemoryCheckInStore([this._log = const CheckInLog.empty()]);

  CheckInLog _log;

  @override
  Future<CheckInLog> read() async => _log;

  @override
  Future<void> write(CheckInLog log) async => _log = log;
}
