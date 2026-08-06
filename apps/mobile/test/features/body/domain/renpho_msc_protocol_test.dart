import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/body/domain/renpho_msc_protocol.dart';

/// Le trame di questo file sono **quelle vere**, copiate dal registro della
/// bilancia di Marco del 6 agosto 2026 alle 13:41. Non sono state costruite da
/// una specifica — per questo protocollo una specifica non esiste — né dal
/// decodificatore, che le renderebbe una tautologia.
///
/// È l'unica prova possibile per un formato ricavato per osservazione, ed è
/// anche la più forte che ci sia: se un giorno la decodifica cambierà, dovrà
/// continuare a leggere 96,50 kg da questi byte, perché quel giorno Marco
/// pesava 96,50 kg.
void main() {
  group('la struttura', () {
    test('intestazione, lunghezza e somma di controllo', () {
      // 55 aa | opcode 21 | lunghezza 0005 | payload | somma
      final frame = decodeRenphoFrame(const [
        0x55, 0xaa, //
        0x21, // peso corrente
        0x00, 0x05, // cinque byte di payload
        0x01, 0x00, 0x00, 0x24, 0x9f, //
        0xe9, // somma: 0x55+0xaa+0x21+0x00+0x05+0x01+0x24+0x9f = 0x1e9
      ])!;

      expect(frame.checksumOk, isTrue);
      expect(frame, isA<RenphoWeightFrame>());
    });

    test('una somma sbagliata si segnala ma non butta via la trama', () {
      // Perdere l'unica pesata della giornata per un bit storto sarebbe
      // peggio del male che il controllo previene.
      final frame = decodeRenphoFrame(const [
        0x55, 0xaa, 0x21, 0x00, 0x05, //
        0x01, 0x00, 0x00, 0x24, 0x9f, //
        0x00, // somma sbagliata di proposito
      ])!;

      expect(frame.checksumOk, isFalse);
      expect((frame as RenphoWeightFrame).weightKg, closeTo(93.75, 0.001));
    });

    test('quello che non è di questo protocollo si riconosce subito', () {
      // Senza l'intestazione non è una trama: restituire qualcosa vorrebbe
      // dire leggere un peso dai byte di un altro apparecchio.
      expect(decodeRenphoFrame(const [0x00, 0x01, 0x02]), isNull);
      expect(
        decodeRenphoFrame(const [0x12, 0x34, 0x21, 0x00, 0x05, 0x01, 0x00]),
        isNull,
      );
      // Lunghezza che promette più byte di quanti ce ne siano.
      expect(
        decodeRenphoFrame(const [0x55, 0xaa, 0x21, 0x00, 0x40, 0x01, 0x00]),
        isNull,
      );
      expect(decodeRenphoFrame(const []), isNull);
    });
  });

  group('il peso, dalle trame vere', () {
    test('il flusso mentre Marco sale sulla bilancia', () {
      // Dieci trame consecutive del registro delle 13:41:24-28. Il peso sale
      // e si assesta: è esattamente ciò che si vede salendo su una bilancia,
      // ed è la ragione per cui questa decodifica è quella giusta e non una
      // che per caso produce numeri plausibili.
      final letture = <List<int>>[
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x24, 0x9f, 0xe9],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x24, 0xc2, 0x0c],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0x8f, 0xda],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0xad, 0xf8],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0x85, 0xd0],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0xc6, 0x11],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0x62, 0xad],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0xa8, 0xf3],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0xcb, 0x16],
        [0x55, 0xaa, 0x21, 0x00, 0x05, 0x01, 0x00, 0x00, 0x25, 0xb2, 0xfd],
      ];

      final pesi = <double>[];
      for (final bytes in letture) {
        final frame = decodeRenphoFrame(bytes)! as RenphoWeightFrame;
        expect(frame.checksumOk, isTrue, reason: 'somma su ${frame.hex}');
        expect(frame.stable, isFalse);
        pesi.add(frame.weightKg);
      }

      expect(pesi.first, closeTo(93.75, 0.001));
      expect(pesi.last, closeTo(96.50, 0.001));
      // Tutte nell'intorno di un uomo di novantasei chili, nessuna assurda:
      // è il controllo che un allineamento sbagliato non passerebbe.
      for (final peso in pesi) {
        expect(peso, inInclusiveRange(93, 97));
      }
    });

    test('il peso stabile è quello che si salva', () {
      // 13:41:28, opcode 0x24, sei byte di payload invece di cinque: c'è un
      // byte in più davanti al peso. Il valore però è identico all'ultima
      // lettura del flusso — ed è così che si è capito che il peso sta negli
      // ultimi quattro byte e non a un offset fisso.
      final frame =
          decodeRenphoFrame(const [
                0x55, 0xaa, //
                0x24, // peso stabile
                0x00, 0x06, // sei byte di payload
                0x01, 0x11, 0x00, 0x00, 0x25, 0xb2, //
                0x12, // somma
              ])!
              as RenphoWeightFrame;

      expect(frame.checksumOk, isTrue);
      expect(frame.stable, isTrue);
      expect(frame.weightKg, closeTo(96.50, 0.001));
    });

    test('un peso fuori scala non si legge affatto', () {
      // La difesa contro l'allineamento sbagliato: 0xFFFFFFFF sarebbe
      // quarantadue milioni di chili. Meglio nessuna lettura che una assurda
      // registrata nello storico.
      final frame = decodeRenphoFrame(const [
        0x55, 0xaa, 0x21, 0x00, 0x05, //
        0x01, 0xff, 0xff, 0xff, 0xff, //
        0x9c,
      ])!;
      expect(frame, isA<RenphoUnknownFrame>());
    });
  });

  group('quello che ancora non si sa', () {
    test('gli avanzamenti di stato si leggono senza fingere di capirli', () {
      // Le quattro trame 0x20 del registro. Che siano avanzamenti si vede dal
      // primo byte che cresce (00, 02, 03, 04) e dalla loro cadenza; cosa
      // significhino non si sa, e inventarselo sarebbe peggio che dirlo.
      final stati = <List<int>>[
        [0x55, 0xaa, 0x20, 0x00, 0x05, 0x00, 0x01, 0x01, 0x00, 0x00, 0x26],
        [0x55, 0xaa, 0x20, 0x00, 0x05, 0x02, 0x09, 0x01, 0x00, 0x00, 0x30],
        [0x55, 0xaa, 0x20, 0x00, 0x05, 0x03, 0x11, 0x01, 0x00, 0x00, 0x39],
        [0x55, 0xaa, 0x20, 0x00, 0x05, 0x04, 0x05, 0x01, 0x01, 0x00, 0x2f],
      ];
      for (final bytes in stati) {
        final frame = decodeRenphoFrame(bytes)!;
        expect(frame, isA<RenphoStatusFrame>());
        expect(frame.checksumOk, isTrue, reason: 'somma su ${frame.hex}');
      }
      // E soprattutto: non vengono scambiati per pesi.
      expect(decodeRenphoFrame(stati.first), isNot(isA<RenphoWeightFrame>()));
    });

    test('un opcode mai visto si conserva per intero', () {
      // È la sola pista verso l'impedenza, che in questo protocollo non si è
      // ancora vista. Ridurla a «trama ignota» senza i byte sarebbe come non
      // averla ricevuta.
      final frame =
          decodeRenphoFrame(const [
                0x55, 0xaa, 0x2f, 0x00, 0x04, //
                0x01, 0x02, 0x03, 0x04, //
                0x38,
              ])!
              as RenphoUnknownFrame;

      expect(frame.opcode, 0x2f);
      expect(frame.payload, [0x01, 0x02, 0x03, 0x04]);
      expect(frame.hex, '55 aa 2f 00 04 01 02 03 04 38');
      expect('$frame', contains('questa è nuova'));
    });
  });
}
