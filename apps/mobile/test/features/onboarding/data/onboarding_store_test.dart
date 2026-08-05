import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/onboarding/data/onboarding_store.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('coach360-onboarding');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  FileOnboardingStore store() =>
      FileOnboardingStore(directory: () async => directory);

  File file() => File('${directory.path}/${FileOnboardingStore.fileName}');

  test('senza file la domanda non è mai stata fatta', () async {
    final memory = await store().read();

    expect(memory.readable, isTrue);
    expect(memory.askedAt, isNull);
  });

  test('segnata la domanda, resta segnata', () async {
    final moment = DateTime.utc(2026, 8, 6, 7, 30);
    await store().markAsked(moment);

    // Istanza nuova: quello che conta è il file, non lo stato in memoria.
    final memory = await store().read();
    expect(memory.readable, isTrue);
    expect(memory.askedAt, moment);
  });

  test('il momento si conserva in UTC anche se arriva locale', () async {
    final local = DateTime(2026, 8, 6, 9, 15);
    await store().markAsked(local);

    final memory = await store().read();
    expect(memory.askedAt!.isUtc, isTrue);
    expect(memory.askedAt, local.toUtc());
  });

  test(
    'un file rovinato vale come «mai chiesto», non come un guasto',
    () async {
      // La cartella c'è: la risposta si potrà riscrivere, quindi la domanda si
      // può rifare. Una volta sola.
      file().writeAsStringSync('{questo non è JSON');

      final memory = await store().read();
      expect(memory.readable, isTrue);
      expect(memory.askedAt, isNull);
    },
  );

  test('un documento senza askedAt non inventa una data', () async {
    file().writeAsStringSync('{"version":1}');

    final memory = await store().read();
    expect(memory.readable, isTrue);
    expect(memory.askedAt, isNull);
  });

  test('senza un posto dove scrivere il ricordo è illeggibile', () async {
    // È il caso dei test e di un'installazione con lo spazio di supporto
    // rotto: `path_provider` non risponde. Il gate legge `readable` e sceglie
    // di NON chiedere — la domanda tornerebbe a ogni avvio, e «salta»
    // smetterebbe di significare qualcosa.
    final broken = FileOnboardingStore(
      directory: () async => throw const FileSystemException('niente supporto'),
    );

    final memory = await broken.read();
    expect(memory.readable, isFalse);
    expect(memory.askedAt, isNull);
  });

  test('anche scrivere è best effort: non lancia mai', () async {
    final broken = FileOnboardingStore(
      directory: () async => throw const FileSystemException('niente supporto'),
    );

    await expectLater(broken.markAsked(DateTime.utc(2026, 8, 6)), completes);
  });

  test('il documento scritto è versionato', () async {
    await store().markAsked(DateTime.utc(2026, 8, 6));

    expect(
      file().readAsStringSync(),
      contains('"version":${FileOnboardingStore.documentVersion}'),
    );
  });
}
