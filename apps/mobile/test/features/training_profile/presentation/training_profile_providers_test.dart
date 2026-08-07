import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Le righe generate da drift si chiamano come le entità di dominio: qui
// vince il dominio, come nel repository.
import 'package:kal_tracker/core/database/app_database.dart'
    hide TrainingLimitation, TrainingProfile;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_profile_providers.dart';

void main() {
  late AppDatabase database;
  late ProviderContainer container;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('senza riga sul database il profilo è vuoto, non un errore', () async {
    final profile = await container.read(trainingProfileProvider.future);

    expect(profile.profileId, profileId);
    expect(profile.equipment, isEmpty);
    expect(profile.limitations, isEmpty);
    expect(profile.deloadPreference, DeloadPreference.suggerito);
    expect(profile.hasDeclaredEquipment, isFalse);
  });

  test('una limitazione aperta arriva senza ricaricare niente', () async {
    final arrived = Completer<TrainingProfile>();
    final subscription = container.listen<AsyncValue<TrainingProfile>>(
      trainingProfileProvider,
      (previous, next) {
        final value = next.valueOrNull;
        if (value != null &&
            value.activeLimitations.isNotEmpty &&
            !arrived.isCompleted) {
          arrived.complete(value);
        }
      },
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    // Prima la lettura iniziale: la riga del profilo non c'è ancora, e lo
    // stream deve partire lo stesso — pende dalle tabelle, non dalla riga.
    expect(
      (await container.read(trainingProfileProvider.future)).activeLimitations,
      isEmpty,
    );

    await container
        .read(trainingProfileRepositoryProvider)
        .addLimitation(
          profileId: profileId,
          bodyPart: BodyPart.spallaDx,
          severity: LimitationSeverity.stop,
        );

    final profile = await arrived.future.timeout(const Duration(seconds: 5));
    expect(profile.activeLimitations.single.bodyPart, BodyPart.spallaDx);
    expect(profile.severityFor(JointArea.spalla), LimitationSeverity.stop);
  });

  test('quello che il repository salva torna dallo stesso provider', () async {
    final repository = container.read(trainingProfileRepositoryProvider);
    await repository.saveProfile(
      TrainingProfile(
        profileId: profileId,
        equipment: const {Equipment.manubri, Equipment.tappetino},
        sessionsPerWeek: 4,
        minutesPerSession: 45,
        preferredDays: const [TrainingDay.lun, TrainingDay.gio],
        deloadPreference: DeloadPreference.automatico,
      ),
    );
    container.invalidate(trainingProfileProvider);

    final profile = await container.read(trainingProfileProvider.future);
    expect(profile.equipment, {Equipment.manubri, Equipment.tappetino});
    expect(profile.sessionsPerWeek, 4);
    expect(profile.minutesPerSession, 45);
    expect(profile.preferredDays, [TrainingDay.lun, TrainingDay.gio]);
    expect(profile.deloadPreference, DeloadPreference.automatico);
  });
}
