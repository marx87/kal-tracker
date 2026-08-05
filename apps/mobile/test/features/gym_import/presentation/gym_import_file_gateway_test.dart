import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_file_gateway.dart';

/// Cosa succede al file che il selettore di sistema restituisce.
///
/// Il selettore vero non si può aprire in un test — è un canale nativo — ma
/// tutto ciò che viene dopo sì, ed è lì che stanno gli sbagli: il percorso che
/// non esiste più, il file troppo grosso, i byte che non sono testo.
void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('gym-import-picker');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  File write(String name, String contents) =>
      File('${temporary.path}/$name')..writeAsStringSync(contents);

  test('il file scelto si legge dal percorso, con nome e dimensione', () async {
    final file = write('gym-tracker-export.json', '{"workouts":[]}');
    final gateway = SystemGymImportFileGateway(
      picker: () async => PlatformFile(
        name: 'gym-tracker-export.json',
        size: 15,
        path: file.path,
      ),
    );

    expect(gateway.canBrowse, isTrue);
    final picked = await gateway.browse();

    expect(picked, isNotNull);
    expect(picked!.name, 'gym-tracker-export.json');
    expect(picked.contents, '{"workouts":[]}');
    expect(picked.sizeBytes, 15);
  });

  test('chiudere il selettore non è un errore', () async {
    final gateway = SystemGymImportFileGateway(picker: () async => null);
    expect(await gateway.browse(), isNull);
  });

  test('un selettore che esplode diventa una frase in italiano', () async {
    final gateway = SystemGymImportFileGateway(
      picker: () async => throw StateError('canale assente'),
    );

    await expectLater(
      gateway.browse(),
      throwsA(
        isA<GymImportFileException>().having(
          (error) => error.message,
          'message',
          contains('Non riesco ad aprire il selettore'),
        ),
      ),
    );
  });

  test('un file troppo grosso si ferma prima di essere letto', () async {
    final file = write('enorme.json', '{"a":1}');
    final gateway = SystemGymImportFileGateway(
      maximumBytes: 3,
      picker: () async =>
          PlatformFile(name: 'enorme.json', size: 7, path: file.path),
    );

    await expectLater(
      gateway.browse(),
      throwsA(
        isA<GymImportFileException>().having(
          (error) => error.message,
          'message',
          contains('troppo per essere un export'),
        ),
      ),
    );
  });

  test('senza percorso si usano i byte che il selettore ha già', () async {
    final contents = '{"workouts":[]}';
    final gateway = SystemGymImportFileGateway(
      picker: () async => PlatformFile(
        name: 'export.json',
        size: contents.length,
        bytes: Uint8List.fromList(utf8.encode(contents)),
      ),
    );

    final picked = await gateway.browse();
    expect(picked!.contents, contents);
    expect(picked.name, 'export.json');
  });

  test('senza percorso e senza byte lo dice, invece di fingere', () async {
    final gateway = SystemGymImportFileGateway(
      picker: () async => PlatformFile(name: 'export.json', size: 12),
    );

    await expectLater(
      gateway.browse(),
      throwsA(
        isA<GymImportFileException>().having(
          (error) => error.message,
          'message',
          contains('prova a incollarne il percorso'),
        ),
      ),
    );
  });

  test('il percorso digitato a mano continua a funzionare', () async {
    // È la strada del Mac e dei test: aggiungere il selettore non la toglie.
    final file = write('export.json', '{"workouts":[]}');
    const gateway = SystemGymImportFileGateway();

    final read = await gateway.read(file.path);
    expect(read.name, 'export.json');
    expect(read.contents, '{"workouts":[]}');

    // E anche il contenuto incollato, che non ha nemmeno un file dietro.
    final pasted = await gateway.read('  {"workouts":[]}  ');
    expect(pasted.name, 'contenuto incollato');
    expect(pasted.contents, '{"workouts":[]}');
  });
}
