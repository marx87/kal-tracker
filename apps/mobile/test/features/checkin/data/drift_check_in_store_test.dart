import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_repository.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

/// Un file JSON come quello che il telefono di Marco ha oggi accanto al
/// database, con la forma prodotta da `CheckInLog.toJson`.
Future<Directory> _legacyDirectory(Map<String, Object?> content) async {
  final directory = await Directory.systemTemp.createTemp('kal_checkin_');
  File(
    '${directory.path}/${FileCheckInStore.fileName}',
  ).writeAsStringSync(jsonEncode(content));
  return directory;
}

void main() {
  setUpAll(AppTime.initialize);

  late AppDatabase database;
  late String profileId;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  tearDown(() => database.close());

  DriftCheckInStore storeWith({FileCheckInStore? legacy}) => DriftCheckInStore(
    database,
    legacy:
        legacy ?? FileCheckInStore(directory: Directory.systemTemp.createTemp),
    profileId: () async => profileId,
  );

  test('sonno, energia e movimento sopravvivono alla riapertura', () async {
    final day = DateTime.utc(2026, 8, 6, 7, 30);
    final repository = CheckInRepository(storeWith());

    await repository.save(day: day, sleepHours: 7.5);
    await repository.save(day: day, energyScore: 4);
    await repository.save(day: day, steps: 8000, walkMinutes: 40);

    // Uno store nuovo sullo stesso database: è la riapertura dell'app.
    final log = await storeWith().read();
    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.sleepHours, 7.5);
    expect(entry.energyScore, 4);
    expect(entry.steps, 8000);
    expect(entry.walkMinutes, 40);
    expect(entry.isFullyLogged, isTrue);

    final row = await database.select(database.dailyCheckIns).getSingle();
    expect(row.day.toUtc(), DateTime.utc(2026, 8, 6));
    expect(row.deletedAt, isNull);
    final outbox = await database.select(database.syncOutbox).get();
    expect(outbox, hasLength(3));
    expect(outbox.every((row) => row.entityType == 'daily_check_in'), isTrue);
  });

  test('la giornata ferma si salva come zero, non come niente', () async {
    final day = DateTime.utc(2026, 8, 6);
    await CheckInRepository(
      storeWith(),
    ).save(day: day, sleepHours: 7, steps: 0, walkMinutes: 0);

    final entry = (await storeWith().read()).forDay(checkInDayOf(day))!;
    // Lo zero deve tornare indietro dal database come zero: se si rileggesse
    // `null` il giorno fermo tornerebbe indistinguibile da quello non
    // segnato, e la media settimanale si farebbe di nuovo solo sui giorni
    // buoni.
    expect(entry.steps, 0);
    expect(entry.walkMinutes, 0);
    expect(entry.hasNeat, isTrue);
  });

  test('il movimento da solo arriva alla tabella', () async {
    final soloCammino = DateTime.utc(2026, 8, 6);
    final normale = DateTime.utc(2026, 8, 5);
    final repository = CheckInRepository(storeWith());
    await repository.save(day: normale, sleepHours: 7, steps: 5000);

    await repository.save(day: soloCammino, walkMinutes: 45);

    // Fino alla v9 la CHECK pretendeva sonno o energia e questa riga veniva
    // saltata: una giornata camminata spariva perché quel giorno Marco non
    // aveva risposto sulla notte. Dalla v10 la camminata basta a sé stessa.
    final righe = await database.select(database.dailyCheckIns).get();
    expect(righe, hasLength(2));
    final riga = righe.firstWhere(
      (row) => row.day.toUtc() == DateTime.utc(2026, 8, 6),
    );
    expect(riga.walkMinutes, 45);
    expect(riga.sleepHours, isNull);
    expect(riga.deletedAt, isNull);
    expect((await storeWith().read()).entries, hasLength(2));
  });

  test('togliendo il sonno resta la camminata, e il sonno non torna', () async {
    final day = DateTime.utc(2026, 8, 6);
    final repository = CheckInRepository(storeWith());
    await repository.save(day: day, sleepHours: 7, walkMinutes: 45);

    await repository.save(day: day, clearSleep: true);

    // È lo scenario che la v10 esiste per riparare: prima la riga non era più
    // riscrivibile e andava spenta, e i 45 minuti se ne andavano con il sonno
    // che Marco aveva appena tolto. Adesso resta viva con quello che ha.
    final row = await database.select(database.dailyCheckIns).getSingle();
    expect(row.deletedAt, isNull);
    expect(row.sleepHours, isNull);
    expect(row.walkMinutes, 45);

    final entry = (await storeWith().read()).forDay(checkInDayOf(day))!;
    expect(entry.walkMinutes, 45);
    expect(entry.sleepHours, isNull);
  });

  test('il giorno cancellato resta come tombstone e può tornare', () async {
    final day = DateTime.utc(2026, 8, 6);
    final repository = CheckInRepository(storeWith());

    await repository.save(day: day, sleepHours: 6, energyScore: 2);
    final primaId =
        (await database.select(database.dailyCheckIns).getSingle()).id;

    await repository.clearDay(day);

    final tombstone = await database.select(database.dailyCheckIns).getSingle();
    expect(tombstone.deletedAt, isNotNull);
    expect(tombstone.sleepHours, isNull);
    expect((await storeWith().read()).entries, isEmpty);
    expect(
      (await database.select(database.syncOutbox).get()).any(
        (row) => row.operation == 'delete',
      ),
      isTrue,
    );

    // Ricompilare lo stesso giorno riprende la stessa riga invece di crearne
    // una seconda: l'id è derivato da profilo e giorno.
    await repository.save(day: day, sleepHours: 8);
    final ripreso = await database.select(database.dailyCheckIns).getSingle();
    expect(ripreso.id, primaId);
    expect(ripreso.deletedAt, isNull);
    expect(ripreso.sleepHours, 8);
  });

  test(
    'il file JSON entra alla prima apertura e poi viene archiviato',
    () async {
      final directory = await _legacyDirectory({
        'version': 1,
        'entries': [
          {
            'day': '2026-08-05',
            'updated_at': '2026-08-05T06:10:00.000Z',
            'sleep_hours': 7,
            'energy_score': 3,
          },
          {
            'day': '2026-08-04',
            'updated_at': '2026-08-04T06:10:00.000Z',
            'sleep_hours': 6.5,
          },
        ],
      });
      addTearDown(() => directory.delete(recursive: true));
      final legacy = FileCheckInStore(directory: () async => directory);

      final log = await storeWith(legacy: legacy).read();

      expect(log.entries, hasLength(2));
      expect(log.forDay(DateTime.utc(2026, 8, 5))!.energyScore, 3);
      expect(log.forDay(DateTime.utc(2026, 8, 4))!.sleepHours, 6.5);
      expect(
        File('${directory.path}/${FileCheckInStore.fileName}').existsSync(),
        isFalse,
      );
      // Rinominato, non cancellato: se qualcosa fosse andato storto resterebbe
      // lì da guardare.
      expect(
        File(
          '${directory.path}/${FileCheckInStore.archivedFileName}',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('quello che c\'è già nella tabella vince sul file', () async {
    final directory = await _legacyDirectory({
      'version': 1,
      'entries': [
        {
          'day': '2026-08-05',
          'updated_at': '2026-08-05T06:10:00.000Z',
          'sleep_hours': 4,
          'energy_score': 1,
        },
      ],
    });
    addTearDown(() => directory.delete(recursive: true));

    // Il giorno esiste già in Drift: il file non deve sovrascriverlo.
    await CheckInRepository(
      storeWith(),
    ).save(day: DateTime.utc(2026, 8, 5), sleepHours: 8, energyScore: 5);

    final log = await storeWith(
      legacy: FileCheckInStore(directory: () async => directory),
    ).read();

    final entry = log.forDay(DateTime.utc(2026, 8, 5))!;
    expect(entry.sleepHours, 8);
    expect(entry.energyScore, 5);
    expect(await database.select(database.dailyCheckIns).get(), hasLength(1));
  });

  test('i giorni fuori dalla finestra non vengono cancellati', () async {
    final now = AppTime.nowUtc();
    final vecchio = checkInDayOf(
      now,
    ).subtract(const Duration(days: CheckInLog.historyDays + 30));
    await database
        .into(database.dailyCheckIns)
        .insert(
          DailyCheckInsCompanion.insert(
            id: checkInRowId(profileId: profileId, day: vecchio),
            profileId: profileId,
            day: vecchio,
            createdAt: now,
            updatedAt: now,
            sleepHours: const Value(7),
          ),
        );

    // Il log non lo vede, quindi una scrittura qualunque potrebbe scambiarlo
    // per un giorno cancellato: la finestra della potatura è un dimenticare,
    // non un cancellare.
    await CheckInRepository(storeWith()).save(day: now, energyScore: 5);

    final vecchia = await (database.select(
      database.dailyCheckIns,
    )..where((row) => row.day.equals(vecchio))).getSingle();
    expect(vecchia.deletedAt, isNull);
    expect(vecchia.sleepHours, 7);
    expect((await storeWith().read()).entries, hasLength(1));
  });
}
