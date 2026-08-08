import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/onboarding/data/personal_details_repository.dart';
import 'package:kal_tracker/features/onboarding/domain/personal_details.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late PersonalDetailsRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = PersonalDetailsRepository(database);
  });

  tearDown(() => database.close());

  test('un profilo appena creato non ha nessuno dei tre dati', () async {
    final details = await repository.read(profileId);

    expect(details.isEmpty, isTrue);
    expect(details.heightCm, isNull);
    expect(details.birthDate, isNull);
    expect(details.sex, isNull);
  });

  test('quello che si scrive si rilegge identico', () async {
    await repository.write(
      profileId,
      PersonalDetails(
        heightCm: 182,
        birthDate: DateTime.utc(1987, 9, 13),
        sex: BiologicalSex.male,
      ),
    );

    final details = await repository.read(profileId);
    expect(details.heightCm, 182);
    expect(details.birthDate, DateTime.utc(1987, 9, 13));
    expect(details.sex, BiologicalSex.male);
    expect(details.isComplete, isTrue);
    final outbox = await database.select(database.syncOutbox).getSingle();
    expect(outbox.entityType, 'profile');
    expect(outbox.operation, 'upsert');
  });

  test(
    'la data di nascita torna a mezzanotte UTC, non due ore prima',
    () async {
      // Drift salva i `DateTime` come istante e li rilegge nel fuso locale:
      // senza `toUtc()` in lettura, a Roma d'estate il 13 settembre tornerebbe
      // come le 02:00 del 13 — e con un `startOfDay` sbagliato, come il 12.
      await repository.write(
        profileId,
        PersonalDetails(birthDate: DateTime.utc(1987, 9, 13)),
      );

      final details = await repository.read(profileId);
      expect(details.birthDate!.isUtc, isTrue);
      expect(details.birthDate, DateTime.utc(1987, 9, 13));
    },
  );

  test('scrivere è sostituire: un campo svuotato si svuota davvero', () async {
    await repository.write(
      profileId,
      PersonalDetails(
        heightCm: 182,
        birthDate: DateTime.utc(1987, 9, 13),
        sex: BiologicalSex.male,
      ),
    );

    // La stessa schermata serve a correggere: togliere l'altezza deve
    // toglierla, non lasciare quella di prima perché il campo era vuoto.
    await repository.write(
      profileId,
      PersonalDetails(birthDate: DateTime.utc(1987, 9, 13)),
    );

    final details = await repository.read(profileId);
    expect(details.heightCm, isNull);
    expect(details.sex, isNull);
    expect(details.birthDate, DateTime.utc(1987, 9, 13));
  });

  test('scrivere aggiorna updatedAt del profilo', () async {
    // Si invecchia la riga a mano invece di aspettare: Drift salva i
    // `DateTime` al secondo, e due scritture nello stesso secondo hanno lo
    // stesso timbro.
    final stale = DateTime.utc(2020, 1, 1);
    await (database.update(database.appProfiles)
          ..where((p) => p.id.equals(profileId)))
        .write(AppProfilesCompanion(updatedAt: Value(stale)));

    await repository.write(profileId, const PersonalDetails(heightCm: 182));

    final after = await (database.select(
      database.appProfiles,
    )..where((p) => p.id.equals(profileId))).getSingle();

    // `updatedAt` è la chiave del last-write-wins della sincronizzazione:
    // senza toccarlo, un altro dispositivo non saprebbe mai che l'altezza è
    // cambiata.
    expect(after.updatedAt.toUtc().isAfter(stale), isTrue);
  });

  test('un profilo che non esiste non fa esplodere la lettura', () async {
    final details = await repository.read('profilo-che-non-c-e');
    expect(details, PersonalDetails.empty);
  });
}
