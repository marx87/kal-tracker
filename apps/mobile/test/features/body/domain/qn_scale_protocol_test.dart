import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';

import '../data/fake_scale_link.dart';

void main() {
  group('riconoscimento della bilancia', () {
    test('accetta le QN e scarta il resto del condominio', () {
      expect(isQnScaleName('QN-Scale'), isTrue);
      expect(isQnScaleName('qn-scale'), isTrue);
      expect(isQnScaleName('QN-Scale Pro'), isTrue);
      expect(isQnScaleName('QN Scale'), isTrue);
      expect(isQnScaleName('Mi Smart Scale'), isFalse);
      expect(isQnScaleName(''), isFalse);
      expect(isQnScaleName(null), isFalse);
    });
  });

  group('somma di controllo', () {
    test('è la somma dei byte modulo 256', () {
      expect(qnChecksum([0x10, 0x20]), 0x30);
      expect(qnChecksum([0xFF, 0x02]), 0x01);
      expect(qnChecksum(const <int>[]), 0);
    });
  });

  group('presentazione (0x12)', () {
    test('dichiara tipo di protocollo e scala del peso', () {
      final frame = decodeQnFrame(fakeHandshakeFrame(protocolType: 0x15));
      expect(frame, isA<QnHandshakeFrame>());
      final handshake = frame! as QnHandshakeFrame;
      expect(handshake.protocolType, 0x15);
      expect(handshake.weightScaleFactor, 100);
      expect(handshake.checksumOk, isTrue);
    });

    test('il byte 10 diverso da 1 significa decimi di chilo', () {
      final frame =
          decodeQnFrame(fakeHandshakeFrame(hundredths: false))!
              as QnHandshakeFrame;
      expect(frame.weightScaleFactor, 10);
    });

    test('una presentazione troppo corta non si inventa i campi', () {
      final frame = decodeQnFrame([0x12, 0x04, 0x15, 0x2B]);
      expect(frame, isA<QnUnknownFrame>());
    });
  });

  group('peso (0x10)', () {
    test('legge peso, stabilità e le due resistenze', () {
      final frame =
          decodeQnFrame(
                fakeWeightFrame(
                  weightKg: 95.8,
                  stable: true,
                  resistance1: 442,
                  resistance2: 500,
                ),
              )!
              as QnWeightFrame;
      expect(frame.weightKg, closeTo(95.8, 0.001));
      expect(frame.stable, isTrue);
      expect(frame.resistance1, 442);
      expect(frame.resistance2, 500);
      expect(frame.hasImpedance, isTrue);
      expect(frame.checksumOk, isTrue);
    });

    test('il peso che sta ancora oscillando si dichiara instabile', () {
      final frame =
          decodeQnFrame(fakeWeightFrame(weightKg: 62.4, stable: false))!
              as QnWeightFrame;
      expect(frame.stable, isFalse);
    });

    test('resistenza a zero: la bilancia ha pesato ma non ha letto niente', () {
      // È il caso reale della pesata con i piedi asciutti o con le calze.
      final frame =
          decodeQnFrame(
                fakeWeightFrame(
                  weightKg: 95.8,
                  stable: true,
                  resistance1: 0,
                  resistance2: 0,
                ),
              )!
              as QnWeightFrame;
      expect(frame.hasImpedance, isFalse);
      expect(frame.weightKg, closeTo(95.8, 0.001));
    });

    test(
      'la disposizione ES-30M si riconosce dal quinto byte e dalla scala',
      () {
        final frame =
            decodeQnFrame(
                  fakeAlternateWeightFrame(weightKg: 95.8, stable: true),
                  weightScaleFactor: 10,
                )!
                as QnWeightFrame;
        expect(frame.weightKg, closeTo(95.8, 0.001));
        expect(frame.stable, isTrue);
        expect(frame.resistance1, 442);
      },
    );

    test('un peso fuori dal possibile umano non diventa una pesata', () {
      // Trama di accensione: tutto a zero.
      final frame = decodeQnFrame([
        0x10,
        0x0B,
        0x15,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x2B,
      ]);
      expect(frame, isA<QnUnknownFrame>());
    });

    test('una trama troppo corta non si decodifica a metà', () {
      expect(decodeQnFrame([0x10, 0x06, 0x15, 0x25, 0x6C]), isNull);
    });

    test('la somma sbagliata si annota ma non butta via la pesata', () {
      final bytes = fakeWeightFrame(weightKg: 95.8, stable: true);
      bytes[bytes.length - 1] = (bytes.last + 1) & 0xFF;
      final frame = decodeQnFrame(bytes)! as QnWeightFrame;
      expect(frame.checksumOk, isFalse);
      expect(frame.weightKg, closeTo(95.8, 0.001));
    });
  });

  group('comandi verso la bilancia', () {
    test('il comando di unità è di nove byte e chiude con la somma', () {
      final command = qnConfigCommand(protocolType: 0x15);
      expect(command.length, 9);
      expect(command[0], 0x13);
      expect(command[1], 0x09);
      expect(command[2], 0x15);
      expect(command[3], QnScale.unitKilograms);
      expect(command.last, qnChecksum(command.take(8)));
    });

    test('il comando dell’orologio conta dal 2000 e viaggia little-endian', () {
      final now = DateTime.utc(2026, 8, 6, 7, 30);
      final command = qnTimeCommand(now: now, protocolType: 0x15);
      expect(command.length, 8);
      expect(command[0], 0x20);
      expect(command[1], 0x08);
      final seconds =
          (now.millisecondsSinceEpoch ~/ 1000) - QnScale.epochOffsetSeconds;
      final decoded =
          command[3] |
          (command[4] << 8) |
          (command[5] << 16) |
          (command[6] << 24);
      expect(decoded, seconds);
      expect(command.last, qnChecksum(command.take(7)));
    });

    test('una data prima dell’epoca della bilancia non diventa negativa', () {
      final command = qnTimeCommand(now: DateTime.utc(1999, 1, 1));
      expect(command[3], 0);
      expect(command[4], 0);
      expect(command[5], 0);
      expect(command[6], 0);
    });
  });

  group('esadecimale', () {
    test('va e torna', () {
      final bytes = fakeWeightFrame(weightKg: 95.8, stable: true);
      final hex = qnHex(bytes);
      expect(hex, matches(RegExp(r'^[0-9a-f]+$')));
      expect(qnBytesFromHex(hex), bytes);
    });

    test('rifiuta ciò che non è esadecimale', () {
      expect(qnBytesFromHex('abc'), isNull);
      expect(qnBytesFromHex('zz'), isNull);
      expect(qnBytesFromHex(''), isNull);
    });
  });
}
