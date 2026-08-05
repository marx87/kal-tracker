import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/backup/data/backup_storage.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';

/// Il selettore di sistema, dal lato del ripristino.
///
/// Restituisce il PERCORSO e non il contenuto di proposito: `readRestoreSource`
/// sa già leggere un percorso, e così Marco vede scritto quale file ha preso
/// invece di doversi fidare.
void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('backup-picker');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  FileBackupStorage storageWith(BackupFilePicker picker) => FileBackupStorage(
    exportDirectory: () async => temporary,
    stateDirectory: () async => temporary,
    picker: picker,
  );

  test('il file scelto arriva come percorso, pronto per la lettura', () async {
    final file = File('${temporary.path}/kal-tracker-backup-2026-08-05.json')
      ..writeAsStringSync('{"app":"kal-tracker"}');
    final storage = storageWith(
      () async => PlatformFile(
        name: 'kal-tracker-backup-2026-08-05.json',
        size: 21,
        path: file.path,
      ),
    );

    expect(storage.canBrowse, isTrue);
    final source = await storage.browseRestoreSource();

    expect(source, file.path);
    // E il percorso restituito è davvero uno che il ripristino sa leggere.
    expect(await storage.readRestoreSource(source!), '{"app":"kal-tracker"}');
  });

  test('chiudere il selettore non è un errore', () async {
    expect(await storageWith(() async => null).browseRestoreSource(), isNull);
  });

  test('un selettore che esplode diventa una frase in italiano', () async {
    final storage = storageWith(() async => throw StateError('canale assente'));

    await expectLater(
      storage.browseRestoreSource(),
      throwsA(
        isA<BackupFormatException>().having(
          (error) => error.message,
          'message',
          contains('Non riesco ad aprire il selettore'),
        ),
      ),
    );
  });

  test('un file senza percorso lo dice e lascia la strada manuale', () async {
    final storage = storageWith(
      () async => PlatformFile(name: 'backup.json', size: 10),
    );

    await expectLater(
      storage.browseRestoreSource(),
      throwsA(
        isA<BackupFormatException>().having(
          (error) => error.message,
          'message',
          contains('incolla il percorso'),
        ),
      ),
    );
  });

  test('il contenuto incollato continua a funzionare', () async {
    final storage = storageWith(() async => null);
    expect(
      await storage.readRestoreSource('  {"app":"kal-tracker"}  '),
      '{"app":"kal-tracker"}',
    );
  });
}
