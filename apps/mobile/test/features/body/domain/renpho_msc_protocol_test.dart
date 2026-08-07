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

  group('la composizione, dalle trame vere del 7 agosto', () {
    // Le due misure complete catturate dal registro HCI mentre l'app Renpho
    // parlava con la bilancia. Sono la prova che la decodifica è giusta e non
    // solo plausibile: i valori che la bilancia si calcola per il display
    // combaciano con quelli del CSV esportato dall'app.
    const misura0902 =
        '55 aa 25 00 24 04 11 00 00 25 3f 0a 00 e1 0b b8 0b 69 0a 94 0a 81 '
        '00 bd 0a 48 09 f1 09 06 08 ef 01 01 00 01 20 01 ab 00 09 f3';
    const misura1022 =
        '55 aa 25 00 24 04 11 00 00 25 85 0a 00 e3 0b f1 0b aa 0a ad 0a 8e '
        '00 bd 0a 75 0a 1f 09 21 09 02 01 01 0b 01 22 01 a4 00 0a 6d';

    List<int> byte(String hex) => [
      for (final parte in hex.split(' ')) int.parse(parte, radix: 16),
    ];

    test('peso e nove impedenze', () {
      final frame = decodeRenphoFrame(byte(misura1022))! as RenphoBodyFrame;

      expect(frame.checksumOk, isTrue);
      expect(frame.weightKg, closeTo(96.05, 0.001));
      expect(frame.impedancesOhm, hasLength(9));
      // Little endian, decimi di ohm. Letto al contrario 0x0be3 farebbe
      // cinquemila ohm, che non è un corpo umano.
      expect(frame.impedancesOhm.first, closeTo(304.3, 0.05));
      expect(frame.impedancesOhm, contains(closeTo(14.2, 0.05)));
    });

    test('le somme di controllo tornano su entrambe', () {
      // Il fissaggio delle 09:02 aveva la somma copiata male, e nessuno se ne
      // era accorto perché nessun test la guardava: un fissaggio con una
      // somma sbagliata è una bugia che aspetta. Questa asserzione è il
      // controllo che le trame di questo file siano davvero quelle uscite
      // dalla bilancia.
      for (final hex in [misura0902, misura1022]) {
        expect(decodeRenphoFrame(byte(hex))!.checksumOk, isTrue, reason: hex);
      }
    });

    test('il tronco è la più bassa, e non può essere altro', () {
      // Un busto sta sui dieci-venti ohm, un arto sulle centinaia: è l'unico
      // segmento che si riconosce senza ipotesi.
      final frame = decodeRenphoFrame(byte(misura0902))! as RenphoBodyFrame;
      final ordinate = frame.impedancesOhm.toList()..sort();

      expect(ordinate.first, closeTo(12.9, 0.05));
      expect(ordinate[1], greaterThan(150));
    });

    test('il percorso mano-piede sta nell’intervallo fisiologico', () {
      // **Quello che questo test NON prova.** Quale delle nove sia il braccio
      // e quale la gamba resta ignoto: la regola prende la più bassa come
      // tronco (l'unica certa), la più alta come braccio e la minore fra le
      // restanti come gamba. Con indici fissi diversi si ottengono 571 Ω
      // invece di 522 — entrambi plausibili, e non c'è modo di scegliere
      // finché non si sa l'anatomia della trama.
      //
      // Quello che prova: che qualunque cosa esca sia **un'impedenza di corpo
      // intero** e non un numero qualsiasi. Se un domani l'attribuzione
      // cambiasse, questo intervallo la tiene onesta — e lo storico si
      // ricalcola, perché le nove restano tutte salvate.
      for (final hex in [misura0902, misura1022]) {
        final frame = decodeRenphoFrame(byte(hex))! as RenphoBodyFrame;
        expect(frame.wholeBodyOhm, inInclusiveRange(300, 900));
      }
      final a = decodeRenphoFrame(byte(misura0902))! as RenphoBodyFrame;
      final b = decodeRenphoFrame(byte(misura1022))! as RenphoBodyFrame;
      // I valori che la regola dichiarata produce oggi, fissati perché un
      // cambiamento silenzioso sposterebbe tutta la composizione dello storico.
      expect(a.wholeBodyOhm, closeTo(522.4, 0.1));
      expect(b.wholeBodyOhm, closeTo(553.4, 0.1));
      // Due misure a ottanta minuti di distanza sullo stesso corpo: la
      // differenza deve essere piccola, o l'attribuzione salta da un segmento
      // all'altro fra una pesata e la successiva.
      expect((a.wholeBodyOhm! - b.wholeBodyOhm!).abs(), lessThan(60));
    });

    test('i valori del display combaciano col CSV di Renpho', () {
      // Il riscontro che ha chiuso la questione: il CSV esportato dall'app
      // per una pesata dello stesso periodo dà grasso 25,2 %, BMI 28,9,
      // muscolo scheletrico 43,0 % e viscerale 9. Se questi numeri escono
      // giusti, gli offset sono giusti.
      final frame = decodeRenphoFrame(byte(misura0902))! as RenphoBodyFrame;

      expect(frame.bodyFatPct, closeTo(25.6, 0.05));
      expect(frame.bmi, closeTo(28.8, 0.05));
      expect(frame.skeletalMusclePct, closeTo(42.7, 0.05));
      expect(frame.visceralFat, 9);
    });
  });

  group('i comandi che sbloccano la composizione', () {
    test('l’orologio porta i secondi Unix, big endian', () {
      // Nella cattura valeva 0x6a7595c7, cioè le 08:22:31 UTC: esattamente
      // l'ora della prova.
      final comando = renphoClockCommand(
        now: DateTime.utc(2026, 8, 7, 8, 22, 31),
        sequence: 4,
      );

      expect(renphoHex(comando), contains('6a 75 95 c7'));
      expect(comando[2], RenphoMsc.opcodeSetClock);
      // La somma di controllo si costruisce come quella che si legge.
      final riletto = decodeRenphoFrame(comando)!;
      expect(riletto.checksumOk, isTrue);
    });

    test('il profilo è quello che l’app Renpho manda, byte per byte', () {
      // La trama vera catturata: 55 aa b2 00 09 05 01 07 1c 25 85 a6 03 02 38
      final comando = renphoProfileCommand(
        sequence: 5,
        heightCm: 182,
        weightKg: 96.05,
        age: 38,
        male: true,
      );

      expect(
        renphoHex(comando),
        '55 aa b2 00 09 05 01 07 1c 25 85 a6 03 02 38',
      );
    });

    test('una donna accende un bit diverso', () {
      final comando = renphoProfileCommand(
        sequence: 0,
        heightCm: 165,
        weightKg: 60,
        age: 30,
        male: false,
      );
      // 30 anni senza il bit alto.
      expect(comando[11], 30);
    });
  });

  group('la rimonta dei frammenti', () {
    test('tre pezzi diventano una trama sola', () {
      // Com'è arrivata davvero: `sequenza | 04 | quanti ne mancano`, e il
      // contatore scende a zero sull'ultimo. Cercando `55 aa` in testa, due
      // pezzi su tre non somigliano a niente — ed è per questo che la
      // composizione era sembrata non arrivare mai.
      final r = RenphoReassembler();
      List<int> b(String hex) => [
        for (final p in hex.split(' ')) int.parse(p, radix: 16),
      ];

      expect(
        r.accept(
          b('ad 04 02 55 aa 25 00 24 04 11 00 00 25 85 0a 00 e3 0b f1 0b'),
        ),
        isNull,
      );
      expect(
        r.accept(
          b('ae 04 01 aa 0a ad 0a 8e 00 bd 0a 75 0a 1f 09 21 09 02 01 01'),
        ),
        isNull,
      );
      final intera = r.accept(b('af 04 00 0b 01 22 01 a4 00 0a 6d'))!;

      final frame = decodeRenphoFrame(intera)! as RenphoBodyFrame;
      expect(frame.checksumOk, isTrue);
      expect(frame.weightKg, closeTo(96.05, 0.001));
      expect(frame.impedancesOhm, hasLength(9));
    });

    test('una trama intera passa dritta e azzera un rimontaggio a metà', () {
      final r = RenphoReassembler();
      r.accept([0xad, 0x04, 0x02, 0x55, 0xaa, 0x25]);
      final intera = r.accept([
        0x55,
        0xaa,
        0x21,
        0x00,
        0x05,
        0x01,
        0x00,
        0x00,
        0x25,
        0xb2,
        0xfd,
      ])!;

      expect(decodeRenphoFrame(intera), isA<RenphoWeightFrame>());
    });
  });

  group('la pesata tenuta in memoria', () {
    test('il comando è byte per byte quello dell’app Renpho', () {
      // Dal registro HCI del 7 agosto: la bilancia annuncia una pesata in
      // sospeso, l'app manda questo, e la bilancia risponde mandandola.
      // Senza, non ne fa di nuove — tre sessioni di fila chiuse col solo peso.
      expect(renphoHex(renphoFetchStoredCommand()), '55 aa b6 00 02 01 01 b9');
    });

    test('la risposta è una pesata intera, non una conferma', () {
      // **La prima lettura era sbagliata.** Il comando sembrava «svuota la
      // coda», e nelle note di rilascio era finito scritto che le pesate
      // venivano buttate. Invece la bilancia risponde con la pesata per
      // esteso: è così che si recupera una salita fatta senza il telefono
      // vicino. Questa è la trama vera delle 11:45:56.
      final frame =
          decodeRenphoFrame([
                for (final p
                    in ('55 aa 26 00 28 04 11 00 00 00 0f 00 00 25 f3 0a 00 '
                            'de 0c 51 0c 0e 0a 61 0a 07 00 c1 0a be 0a 6f 08 '
                            'e5 08 92 01 01 15 01 25 01 9e 00 0b d4')
                        .split(' '))
                  int.parse(p, radix: 16),
              ])!
              as RenphoBodyFrame;

      expect(frame.checksumOk, isTrue);
      expect(frame.weightKg, closeTo(97.15, 0.001));
      expect(frame.impedancesOhm, hasLength(9));
      expect(frame.bodyFatPct, closeTo(27.7, 0.05));
      expect(frame.bmi, closeTo(29.3, 0.05));
      expect(frame.visceralFat, 11);
      // I quattro byte in più: quanto tempo fa è stata fatta.
      expect(frame.age, const Duration(seconds: 15));
    });

    test('un’età assurda non data la pesata in un altro anno', () {
      // L'unità è nota da una sola osservazione. Se un giorno si scoprisse
      // che sono minuti o millisecondi, un valore grande sposterebbe la
      // pesata di mesi: meglio nessuna età che una data inventata.
      final byte = [
        0x55, 0xaa, 0x26, 0x00, 0x28, //
        0x04, 0x11, 0xff, 0xff, 0xff, 0xff, // età assurda
        0x00, 0x00, 0x25, 0xf3, // peso
        // Il payload dichiara 40 byte: dieci ci sono già, trenta di riempimento.
        ...List<int>.filled(30, 0),
      ];
      byte.add(byte.fold<int>(0, (a, b) => a + b) & 0xFF);
      final frame = decodeRenphoFrame(byte)! as RenphoBodyFrame;

      expect(frame.age, isNull);
      expect(frame.weightKg, closeTo(97.15, 0.001));
    });

    test('il contatore si legge dal battito', () {
      // Le due trame a confronto: quella con una misura in sospeso e quella
      // subito dopo il comando. È l'unica differenza fra una sessione che
      // funziona e una che si chiude col solo peso.
      final prima =
          decodeRenphoFrame(const [
                0x55, 0xaa, 0x20, 0x00, 0x05, //
                0x00, 0x01, 0x01, 0x01, 0x00, 0x27,
              ])!
              as RenphoStatusFrame;
      final dopo =
          decodeRenphoFrame(const [
                0x55, 0xaa, 0x20, 0x00, 0x05, //
                0x03, 0x09, 0x01, 0x00, 0x00, 0x31,
              ])!
              as RenphoStatusFrame;

      expect(prima.counter, 1);
      expect(dopo.counter, 0);
    });
  });

  group('la misura riuscita del 7 agosto alle 12:36', () {
    test('la prima composizione arrivata a Coach360', () {
      // La sessione che ha chiuso la caccia: contatore a zero, peso stabile
      // alle 12:36:45, composizione alle 12:36:59 — tredici secondi e mezzo
      // dopo, esattamente il tempo che ci mette con l'app del costruttore.
      final frame =
          decodeRenphoFrame([
                for (final p
                    in ('55 aa 25 00 24 04 11 00 00 25 b2 0a 00 e6 0c 31 0b '
                            'ea 0a 5c 0a 31 00 c3 0a a9 0a 53 08 e2 08 b6 01 '
                            '01 11 01 23 01 a1 00 0a 55')
                        .split(' '))
                  int.parse(p, radix: 16),
              ])!
              as RenphoBodyFrame;

      expect(frame.checksumOk, isTrue);
      expect(frame.weightKg, closeTo(96.50, 0.001));
      expect(frame.impedancesOhm, hasLength(9));
      expect(frame.bodyFatPct, closeTo(27.3, 0.05));
      expect(frame.bmi, closeTo(29.1, 0.05));
      expect(frame.visceralFat, 10);
      // Il tronco resta il più basso di tutti, anche se qui vale meno che
      // nelle altre due misure: il rapporto con gli arti è quello che conta.
      final ordinate = frame.impedancesOhm.toList()..sort();
      expect(ordinate.first, lessThan(50));
      expect(ordinate[1], greaterThan(150));
      expect(frame.wholeBodyOhm, inInclusiveRange(300, 900));
    });
  });

  group('quello che il campo ha insegnato', () {
    test('peso zero è «bilancia libera», non un opcode ignoto', () {
      // Trama vera del 7 agosto alle 09:24:42, prima che Marco salisse. Il
      // controllo di plausibilità la scartava e finiva fra le trame ignote:
      // il registro si riempiva di allarmi in grassetto per la cosa più
      // normale che una bilancia possa dire.
      final frame =
          decodeRenphoFrame(const [
                0x55, 0xaa, 0x21, 0x00, 0x05, //
                0x01, 0x00, 0x00, 0x00, 0x00, 0x26,
              ])!
              as RenphoWeightFrame;

      expect(frame.isEmpty, isTrue);
      expect(frame.weightKg, 0);
      expect('$frame', 'bilancia libera');
    });

    test('gli ack della bilancia si leggono', () {
      // `0x23` per l'orologio e `0x22` per il profilo: sono le risposte ai
      // due comandi, e comparivano come «questa è nuova» mentre erano
      // esattamente ciò che si stava aspettando.
      final orologio =
          decodeRenphoFrame(const [
                0x55,
                0xaa,
                0x23,
                0x00,
                0x03,
                0x00,
                0x07,
                0x01,
                0x2d,
              ])!
              as RenphoAckFrame;
      expect(orologio.forClock, isTrue);
      expect(orologio.ok, isTrue);
      expect(orologio.checksumOk, isTrue);

      final profilo =
          decodeRenphoFrame(const [
                0x55,
                0xaa,
                0x22,
                0x00,
                0x02,
                0x01,
                0x01,
                0x25,
              ])!
              as RenphoAckFrame;
      expect(profilo.forClock, isFalse);
      expect(profilo.sequence, 1);
      expect(profilo.ok, isTrue);
      expect('$profilo', contains('accettato'));
    });

    test('sotto i quaranta chili il profilo non si manda', () {
      // La soglia esiste per un errore preciso: il profilo partiva alla prima
      // trama di peso utile — quella di quando si sta ancora salendo — e
      // dichiarava alla bilancia un uomo di 182 cm da 31,45 kg. Alla richiesta
      // assurda la bilancia ha risposto con l'unica cosa sensata: niente.
      expect(RenphoMsc.minProfileWeightKg, greaterThan(31.45));
      // E non tanto alta da escludere una persona magra.
      expect(RenphoMsc.minProfileWeightKg, lessThan(45));
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
