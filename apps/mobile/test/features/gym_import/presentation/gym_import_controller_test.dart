import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_providers.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_state.dart';

import '../gym_fixtures.dart';

void main() {
  late AppDatabase database;
  late ProviderContainer container;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  GymImportController controller() =>
      container.read(gymImportControllerProvider.notifier);

  GymImportState read() => container.read(gymImportControllerProvider);

  Future<int> countWorkouts() async =>
      (await database.select(database.workouts).get()).length;

  test('la prova a vuoto conta tutto senza scrivere niente', () async {
    await controller().useExportSource(exportPath);
    await controller().useDumpSource(dumpPath);

    await controller().preview();

    final preview = read().preview!;
    // Gli stessi numeri del test dell'importer: l'anteprima non è una stima,
    // è l'import vero fatto girare e poi annullato.
    expect(preview.exercises, 308);
    expect(preview.routines, 14);
    expect(preview.workouts, 29);
    expect(preview.workoutSets, 628);
    expect(preview.usedFirestoreDump, isTrue);
    expect(preview.warnings, isNotEmpty);

    // La prova non deve aver lasciato una riga.
    expect(await countWorkouts(), 0);
    expect(read().result, isNull);
    expect(read().isBusy, isFalse);
  });

  test('la conferma scrive, e un secondo giro non duplica', () async {
    await controller().useExportSource(exportPath);
    await controller().preview();
    await controller().confirm();

    final result = read().result!;
    expect(result.workouts, 29);
    expect(result.syncMutations, 0, reason: 'la coda di sync resta spenta');
    expect(await countWorkouts(), 29);

    // Rilanciato sullo stesso file: l'anteprima dice che non c'è niente di
    // nuovo, quindi la conferma non è nemmeno proponibile.
    controller().startOver();
    await controller().useExportSource(exportPath);
    await controller().preview();

    expect(read().preview!.isNoop, isTrue);
    expect(read().previewIsNoop, isTrue);
    expect(read().awaitsConfirmation, isFalse);
    expect(await countWorkouts(), 29);
  });

  test(
    'il profilo creato dalla prova a vuoto sopravvive alla scrittura',
    () async {
      // La prova a vuoto gira in una transazione annullata: se il profilo
      // nascesse là dentro, la scrittura vera troverebbe un profileId
      // inesistente e la chiave esterna la respingerebbe.
      expect(await database.select(database.appProfiles).get(), isEmpty);

      await controller().useExportSource(exportPath);
      await controller().preview();
      await controller().confirm();

      final profiles = await database.select(database.appProfiles).get();
      expect(profiles, hasLength(1));
      final workouts = await database.select(database.workouts).get();
      expect(workouts.first.profileId, profiles.single.id);
    },
  );

  test('un file che non è di Gym Tracker si ferma prima di scrivere', () async {
    await controller().useExportSource(
      '{"app":"kal-tracker","schemaVersion":1}',
    );
    await controller().preview();

    expect(read().error, contains('non è un export di Gym Tracker'));
    expect(read().preview, isNull);
    expect(read().isBusy, isFalse);
    expect(await countWorkouts(), 0);
  });

  test('un file illeggibile lo dice appena scelto', () async {
    await controller().useExportSource('/percorso/che/non/esiste.json');
    expect(read().error, contains('Non trovo nessun file'));
    expect(read().hasExport, isFalse);

    await controller().useExportSource('{"app": manca-la-virgoletta}');
    expect(read().error, contains('non è un file JSON leggibile'));
  });

  test('il dump si può togliere e rimettere', () async {
    await controller().useExportSource(exportPath);
    await controller().useDumpSource(dumpPath);
    await controller().preview();
    expect(read().preview!.usedFirestoreDump, isTrue);

    final removed = controller().removeDump();
    expect(removed, isNotNull);
    // Tolto il dump l'anteprima non vale più: sparisce invece di mentire.
    expect(read().preview, isNull);
    expect(read().dumpSource, isNull);

    await controller().preview();
    expect(read().preview!.usedFirestoreDump, isFalse);
    expect(read().preview!.notImported, contains(contains('dump Firestore')));

    controller().restoreDump(removed!);
    expect(read().dumpSource, isNotNull);
    expect(read().preview, isNull);
  });
}
