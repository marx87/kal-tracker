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

  test('sonno ed energia sopravvivono alla riapertura', () async {
    final day = DateTime.utc(2026, 8, 6, 7, 30);
    final repository = CheckInRepository(storeWith());

    await repository.save(day: day, sleepHours: 7.5);
    await repository.save(day: day, energyScore: 4);

    // Uno store nuovo sullo stesso database: è la riapertura dell'app.
    final log = await storeWith().read();
    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.sleepHours, 7.5);
    expect(entry.energyScore, 4);
    expect(entry.isComplete, isTrue);

    final row = await database.select(database.dailyCheckIns).getSingle();
    expect(row.day.toUtc(), DateTime.utc(2026, 8, 6));
    expect(row.deletedAt, isNull);
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
