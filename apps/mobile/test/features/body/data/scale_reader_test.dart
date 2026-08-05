import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/data/scale_reader.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';
import 'package:kal_tracker/features/body/domain/scale_session.dart';

import 'fake_scale_link.dart';

void main() {
  final moment = DateTime.utc(2026, 8, 6, 7, 12);

  ScaleReader readerFor(
    FakeScaleLink link, {
    Duration impedanceGrace = const Duration(milliseconds: 40),
  }) => ScaleReader(
    link,
    clock: () => moment,
    scanTimeout: const Duration(milliseconds: 60),
    handshakeTimeout: const Duration(milliseconds: 60),
    stepOnTimeout: const Duration(milliseconds: 400),
    impedanceGrace: impedanceGrace,
  );

  group('la radio prima di tutto', () {
    test('Bluetooth spento: si dice cosa fare, non «errore»', () async {
      final link = FakeScaleLink(radio: ScaleRadioState.off);
      final status = await readerFor(link).read();
      expect(status.phase, ScalePhase.radioOff);
      expect(status.detail, contains('Accendilo'));
      expect(status.phase.canRetry, isTrue);
    });

    test('permesso negato: si nomina il permesso giusto di Android', () async {
      final link = FakeScaleLink(radio: ScaleRadioState.unauthorized);
      final status = await readerFor(link).read();
      expect(status.phase, ScalePhase.permissionDenied);
      expect(status.detail, contains('Dispositivi nelle vicinanze'));
    });

    test('niente Bluetooth Low Energy: riprovare non ha senso', () async {
      final link = FakeScaleLink(radio: ScaleRadioState.unsupported);
      final status = await readerFor(link).read();
      expect(status.phase, ScalePhase.unsupported);
      expect(status.phase.canRetry, isFalse);
    });

    test('un errore di permesso lanciato dalla libreria diventa lo stesso '
        'stato leggibile', () async {
      final link = FakeScaleLink()
        ..radioException = ScaleLinkException(
          ScaleLinkFailure.permissionDenied,
          'BLUETOOTH_SCAN denied',
        );
      final status = await readerFor(link).read();
      expect(status.phase, ScalePhase.permissionDenied);
      // Il testo tecnico resta nel registro: senza, una diagnosi a distanza
      // sarebbe impossibile.
      expect(
        status.log.map((e) => e.message),
        contains('BLUETOOTH_SCAN denied'),
      );
    });
  });

  group('scansione', () {
    test(
      'nessuna bilancia in giro: lo dice e spiega perché può succedere',
      () async {
        final link = FakeScaleLink(devices: const []);
        final status = await readerFor(link).read();
        expect(status.phase, ScalePhase.notFound);
        expect(status.detail, contains('Salici sopra'));
      },
    );

    test('i vicini scartati finiscono nel registro', () async {
      final link = FakeScaleLink(
        devices: const [
          ScaleDevice(id: '1', name: 'Cuffie di Luca'),
          ScaleDevice(id: '2', name: 'Lampadina'),
        ],
      );
      final status = await readerFor(link).read();
      expect(status.phase, ScalePhase.notFound);
      expect(
        status.log.map((entry) => entry.message).join('\n'),
        allOf(contains('Cuffie di Luca'), contains('Lampadina')),
      );
    });

    test(
      'il permesso che salta fuori solo cercando resta un permesso',
      () async {
        // Android 12: la radio si dichiara accesa e `BLUETOOTH_SCAN` viene
        // negato solo al momento della scansione. Se questo errore diventasse
        // «bilancia non trovata», Marco cercherebbe la bilancia per giorni.
        final link = FakeScaleLink()
          ..scanException = ScaleLinkException(
            ScaleLinkFailure.permissionDenied,
            'Need android.permission.BLUETOOTH_SCAN',
          );
        final status = await readerFor(link).read();
        expect(status.phase, ScalePhase.permissionDenied);
        expect(status.errorDetail, contains('BLUETOOTH_SCAN'));
      },
    );

    test(
      'un collegamento rifiutato non diventa «bilancia non trovata»',
      () async {
        final link = FakeScaleLink()
          ..connectException = ScaleLinkException(
            ScaleLinkFailure.connection,
            'gatt error 133',
          );
        final status = await readerFor(link).read();
        expect(status.phase, ScalePhase.failed);
        expect(status.errorDetail, contains('gatt error 133'));
      },
    );
  });

  group('pesata completa', () {
    test('presentazione, comandi, peso stabile con impedenza', () async {
      final link = FakeScaleLink();
      final reader = readerFor(link);
      final phases = <ScalePhase>[];
      final result = reader.read(
        onStatus: (status) => phases.add(status.phase),
      );

      final connection = await link.opened;
      await connection.emit(fakeHandshakeFrame());
      await connection.emit(fakeWeightFrame(weightKg: 40, stable: false));
      await connection.emit(
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      );

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.impedanceOhm, 442);
      expect(status.reading!.secondaryOhm, 500);
      expect(status.reading!.deviceName, QnScale.advertisedName);
      expect(status.reading!.measuredAt, moment);

      // La trama grezza si conserva: è quello che permetterà di
      // ridecodificare lo storico se un giorno si scoprisse un campo che oggi
      // non sappiamo leggere.
      expect(
        qnBytesFromHex(status.reading!.rawPayloadHex),
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      );

      // Prima l'orologio, poi l'unità: una bilancia lasciata in libbre
      // manderebbe libbre.
      expect(connection.sent.length, 2);
      expect(connection.sent.first.first, QnScale.opcodeTimeReply);
      expect(connection.sent.last, qnConfigCommand());
      expect(connection.closed, isTrue);

      expect(
        phases,
        containsAllInOrder([
          ScalePhase.checkingRadio,
          ScalePhase.scanning,
          ScalePhase.connecting,
          ScalePhase.handshake,
          ScalePhase.stepOn,
          ScalePhase.ready,
        ]),
      );
    });

    test('una bilancia che non si presenta viene servita lo stesso', () async {
      final link = FakeScaleLink();
      final reader = readerFor(link);
      final result = reader.read();

      final connection = await link.opened;
      // Nessuna 0x12: si va avanti dopo il timeout della presentazione.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      await connection.emit(
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      );

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(connection.sent, isNotEmpty);
    });

    test(
      'la scala del peso dichiarata nella presentazione viene usata',
      () async {
        final link = FakeScaleLink();
        final reader = readerFor(link);
        final result = reader.read();

        final connection = await link.opened;
        await connection.emit(fakeHandshakeFrame(hundredths: false));
        await connection.emit(
          fakeAlternateWeightFrame(weightKg: 95.8, stable: true),
        );

        final status = await result;
        expect(status.phase, ScalePhase.ready);
        expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      },
    );
  });

  group('pesata incompleta', () {
    test(
      'peso stabile senza impedenza: si aspetta, poi si chiude col peso',
      () async {
        final link = FakeScaleLink();
        final reader = readerFor(link);
        final result = reader.read();

        final connection = await link.opened;
        await connection.emit(fakeHandshakeFrame());
        await connection.emit(
          fakeWeightFrame(
            weightKg: 95.8,
            stable: true,
            resistance1: 0,
            resistance2: 0,
          ),
        );

        final status = await result;
        expect(status.phase, ScalePhase.incomplete);
        expect(status.reading!.weightKg, closeTo(95.8, 0.001));
        expect(status.reading!.hasImpedance, isFalse);
        expect(status.detail, contains('calze'));
      },
    );

    test(
      'l’impedenza che arriva un attimo dopo il peso non si perde',
      () async {
        // È il comportamento vero della bilancia: prima il peso assestato, poi
        // la misura elettrica. Chiudere sulla prima trama stabile butterebbe
        // via l'impedenza di quasi tutte le pesate buone.
        final link = FakeScaleLink();
        final reader = readerFor(
          link,
          impedanceGrace: const Duration(seconds: 5),
        );
        final result = reader.read();

        final connection = await link.opened;
        await connection.emit(fakeHandshakeFrame());
        await connection.emit(
          fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 0),
        );
        await connection.emit(
          fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
        );

        final status = await result;
        expect(status.phase, ScalePhase.ready);
        expect(status.reading!.impedanceOhm, 442);
      },
    );
  });

  group('quando va storto a metà', () {
    test(
      'la bilancia che si scollega prima della pesata lo dichiara',
      () async {
        final link = FakeScaleLink();
        final reader = readerFor(link);
        final result = reader.read();

        final connection = await link.opened;
        await connection.emit(fakeHandshakeFrame());
        await connection.dropConnection();

        final status = await result;
        expect(status.phase, ScalePhase.failed);
        expect(status.errorDetail, contains('scollegata'));
      },
    );

    test(
      'nessuno sale sulla bilancia: si smette di aspettare e si dice',
      () async {
        final link = FakeScaleLink();
        final reader = readerFor(link);
        final result = reader.read();

        final connection = await link.opened;
        await connection.emit(fakeHandshakeFrame());

        final status = await result;
        expect(status.phase, ScalePhase.failed);
        expect(status.errorDetail, contains('stabile'));
        expect(connection.closed, isTrue);
      },
    );

    test('interrompere la sessione chiude il collegamento', () async {
      final link = FakeScaleLink();
      final reader = readerFor(link);
      final result = reader.read();

      final connection = await link.opened;
      await connection.emit(fakeHandshakeFrame());
      reader.cancel();

      final status = await result;
      expect(status.phase, ScalePhase.failed);
      expect(connection.closed, isTrue);
    });
  });

  group('registro di bordo', () {
    test('annota ogni trama in chiaro e in esadecimale', () async {
      final link = FakeScaleLink();
      final reader = readerFor(link);
      final result = reader.read();

      final connection = await link.opened;
      await connection.emit(fakeHandshakeFrame());
      await connection.emit(
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      );

      final status = await result;
      final text = status.log.map((entry) => entry.toString()).join('\n');
      expect(text, contains('presentazione'));
      // Il registro è la vista tecnica: numeri come li ha decodificati la
      // macchina, accanto ai byte da cui vengono. La virgola decimale sta
      // nelle card sopra, non qui.
      expect(text, contains('95.80 kg stabile'));
      expect(text, contains('R1 442'));
      expect(text, contains(qnHex(fakeHandshakeFrame())));
    });

    test('una somma di controllo sbagliata si annota come problema', () async {
      final link = FakeScaleLink();
      final reader = readerFor(link);
      final result = reader.read();

      final connection = await link.opened;
      await connection.emit(fakeHandshakeFrame());
      final broken = fakeWeightFrame(
        weightKg: 95.8,
        stable: true,
        resistance1: 442,
      );
      broken[broken.length - 1] = (broken.last + 3) & 0xFF;
      await connection.emit(broken);

      final status = await result;
      // La pesata vale comunque: buttare via l'unica pesata della giornata per
      // un bit storto sarebbe peggio del male che il controllo previene.
      expect(status.phase, ScalePhase.ready);
      expect(
        status.log.where((entry) => entry.isProblem).map((e) => e.message),
        anyElement(contains('somma di controllo')),
      );
    });

    test('il registro si azzera a ogni sessione', () async {
      final link = FakeScaleLink(radio: ScaleRadioState.off);
      final reader = readerFor(link);
      final first = await reader.read();
      final second = await reader.read();
      expect(second.log.length, first.log.length);
    });
  });
}
