import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/data/scale_reader.dart';
import 'package:kal_tracker/features/body/domain/gatt_scale_protocol.dart';
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
    bodyCompositionTimeout: const Duration(milliseconds: 400),
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
      'non si è visto proprio niente: solo allora è «non trovata»',
      () async {
        final link = FakeScaleLink(devices: const []);
        final status = await readerFor(link).read();
        expect(status.phase, ScalePhase.notFound);
        // Elenco vuoto: non c'è niente da far scegliere, e mostrare una card
        // vuota sarebbe un vicolo cieco travestito da scelta.
        expect(status.candidates, isEmpty);
        expect(status.detail, contains('nemmeno i vicini'));
      },
    );

    test(
      'dispositivi visti ma nessuno si dichiara bilancia: sceglie Marco',
      () async {
        // La differenza fra questo caso e quello sopra è tutta la funzione: se
        // qualcosa si è visto, la radio funziona e la bilancia è probabilmente
        // lì sotto un nome che non conosciamo. Dire «non trovata» chiuderebbe
        // la strada per un'euristica sbagliata.
        final link = FakeScaleLink(
          devices: const [
            ScaleDevice(id: '1', name: 'Cuffie di Luca', rssi: -71),
            ScaleDevice(id: '2', name: 'Lampadina', rssi: -83),
          ],
        );
        final status = await readerFor(link).read();
        expect(status.phase, ScalePhase.chooseDevice);
        expect(status.candidates.map((device) => device.id), ['1', '2']);
        expect(
          status.log.map((entry) => entry.message).join('\n'),
          allOf(contains('Cuffie di Luca'), contains('Lampadina')),
        );
      },
    );

    test('l’elenco è in ordine di comparsa e non si riordina mai', () async {
      // La prima versione ordinava per nome e potenza, e sembrava sensato
      // finché non si è provato il gesto vero. Marco è in piedi sulla
      // bilancia; la sua Renpho non annuncia nessun nome, quindi con quel
      // criterio finiva nel blocco di sotto. Bastava che il televisore di là
      // si annunciasse per la prima volta — ha un nome, quindi saliva in cima
      // — per far scivolare la bilancia di una riga **mentre il dito era già
      // per aria**. Il tocco atterrava sul televisore, che veniva salvato
      // come «la bilancia di Marco».
      //
      // Il difetto non era quale ordine scegliere: era che l'ordine cambiasse
      // mentre lui mirava. Questo test fissa l'unica proprietà che conta —
      // ciò che è già in schermata non si muove.
      final link = FakeScaleLink(
        devices: const [
          ScaleDevice(id: 'muto-lontano', name: '', rssi: -88),
          ScaleDevice(id: 'tv', name: 'TV Salotto', rssi: -74),
          ScaleDevice(id: 'muto-vicino', name: '', rssi: -45),
          ScaleDevice(id: 'cuffie', name: 'Cuffie di Luca', rssi: -59),
        ],
      );
      // Ogni avanzamento, non solo l'ultimo: il riordino colpevole avveniva
      // proprio fra un fotogramma e l'altro, e guardare solo l'esito finale
      // non l'avrebbe mai visto.
      final elenchi = <List<String>>[];
      final status = await readerFor(link).read(
        onStatus: (status) =>
            elenchi.add([for (final device in status.candidates) device.id]),
      );
      expect(status.candidates.map((device) => device.id), [
        'muto-lontano',
        'tv',
        'muto-vicino',
        'cuffie',
      ]);
      // Nessun elenco intermedio smentisce quello dopo: ogni stato è un
      // prefisso del successivo, cioè i nuovi si accodano e basta.
      for (var i = 1; i < elenchi.length; i++) {
        final prima = elenchi[i - 1];
        final dopo = elenchi[i];
        expect(
          dopo.take(prima.length),
          prima,
          reason:
              'l’elenco si è riordinato fra il passo ${i - 1} e il passo $i: '
              'una riga si è spostata sotto il dito di Marco',
        );
      }
    });

    test('la potenza si aggiorna, la posizione no', () async {
      // Due ragioni per volerlo. La prima: il valore in dBm è l'unico appiglio
      // per distinguere la bilancia da un indirizzo anonimo, e attraverso un
      // corpo oscilla di quindici decibel — un campione solo, preso al primo
      // avvistamento, non dice niente. La seconda: aggiornarlo non deve
      // rimettere in fila l'elenco, o si torna al difetto di sopra.
      final link = FakeScaleLink(
        devices: const [
          ScaleDevice(id: 'muta', name: '', rssi: -91),
          ScaleDevice(id: 'tv', name: 'TV Salotto', rssi: -74),
          // La radio ripubblica lo stesso dispositivo a ogni giro: qui la
          // bilancia si è avvicinata di cinquanta decibel perché Marco ci è
          // salito sopra.
          ScaleDevice(id: 'muta', name: '', rssi: -42),
        ],
      );
      final status = await readerFor(link).read();
      expect(status.candidates.map((device) => device.id), ['muta', 'tv']);
      expect(
        status.candidates.firstWhere((device) => device.id == 'muta').rssi,
        -42,
      );
    });

    test(
      'i dati del costruttore finiscono nel registro in esadecimale',
      () async {
        // Era il campo che si buttava via, ed è quello in cui moltissime bilance
        // mettono tutto: senza, un dispositivo «senza servizi» nel registro era
        // indistinguibile da un frigorifero.
        final link = FakeScaleLink(
          devices: const [
            ScaleDevice(
              id: 'muta',
              name: '',
              manufacturerData: {
                0x0157: [0x01, 0xff, 0x5a],
              },
              rssi: -52,
            ),
          ],
        );
        final status = await readerFor(link).read();
        expect(status.phase, ScalePhase.chooseDevice);
        expect(
          status.log.map((entry) => entry.hex).whereType<String>(),
          contains('0157:01ff5a'),
        );
      },
    );

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

  group('la scelta a mano', () {
    /// Il dialogo che porta la bilancia dal collegamento alla pesata buona.
    Future<void> pesa(FakeScaleLink link) async {
      final connection = await link.opened;
      await connection.emit(fakeHandshakeFrame());
      await connection.emit(
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      );
    }

    test('l’indirizzo già scelto vince su nome e servizi che non dicono '
        'niente', () async {
      final link = FakeScaleLink(
        devices: const [
          ScaleDevice(id: 'frigo', name: 'Frigorifero', rssi: -77),
          // Nessun nome, un servizio che non c'entra niente: da sola
          // l'euristica non la guarderebbe mai.
          ScaleDevice(id: 'ff:ee:dd', name: '', serviceUuids: ['180f']),
        ],
      );
      final reader = readerFor(link);
      final result = reader.read(preferredDeviceId: 'ff:ee:dd');
      await pesa(link);

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(
        status.log.map((entry) => entry.message).join('\n'),
        contains('ff:ee:dd'),
      );
    });

    test(
      'l’indirizzo già scelto vince anche su chi sembra una QN-Scale',
      () async {
        // Il riconoscimento è largo per scelta — «QN-», «RENPHO», i nomi di
        // modello — e quindi può prendere in pieno un altro apparecchio della
        // stessa famiglia. Se Marco ha già detto qual è la sua bilancia, quella
        // risposta non deve poter essere smentita da un indovinello, nemmeno se
        // l'indovinello si annuncia per primo.
        final link = FakeScaleLink(
          devices: const [
            ScaleDevice(id: 'sosia', name: QnScale.advertisedName, rssi: -80),
            ScaleDevice(id: 'quella-di-marco', name: '', rssi: -48),
          ],
        );
        final reader = readerFor(link);
        final result = reader.read(preferredDeviceId: 'quella-di-marco');
        await pesa(link);

        final status = await result;
        expect(status.phase, ScalePhase.ready);
        expect(status.reading!.deviceName, isEmpty);
        expect(
          status.log.map((entry) => entry.message).join('\n'),
          contains('mi collego a quella-di-marco'),
        );
      },
    );

    test('la bilancia scelta che non compare lascia il posto a chi le '
        'somiglia', () async {
      // L'altra faccia della regola sopra: aspettare l'indirizzo scelto non
      // deve diventare un'ostinazione. Se quello non si fa vedere — telefono
      // nuovo, bilancia cambiata — e nel frattempo ne è passata una che si
      // dichiara bilancia, tanto vale provarci invece di rimandare Marco a
      // scegliere da un elenco.
      final link = FakeScaleLink(
        devices: const [
          ScaleDevice(id: 'sosia', name: QnScale.advertisedName, rssi: -80),
          ScaleDevice(id: 'frigo', name: 'Frigorifero', rssi: -77),
        ],
      );
      final reader = readerFor(link);
      final result = reader.read(preferredDeviceId: 'mai-vista');
      await pesa(link);

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.deviceName, QnScale.advertisedName);
    });

    test('la scelta fatta mentre cerca prosegue fino alla pesata', () async {
      // Il momento vero: la scansione è ancora aperta, Marco è sulla bilancia
      // e tocca la riga appena compare. Da lì in poi deve andare avanti la
      // lettura già in volo, senza aspettare che scadano i trenta secondi.
      const muta = ScaleDevice(id: 'muta', name: '', rssi: -47);
      final link = FakeScaleLink(keepScanning: true, devices: const [muta]);
      final reader = readerFor(link);
      final phases = <ScalePhase>[];
      final result = reader.read(
        onStatus: (status) => phases.add(status.phase),
      );

      await link.announced;
      expect(reader.chooseWhileScanning(muta), isTrue);
      await pesa(link);

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      // La ricerca si spegne: continuare a cercare una bilancia a cui si è
      // già collegati brucerebbe radio e batteria per niente.
      expect(link.scanStopped, isTrue);
      expect(
        phases,
        containsAllInOrder([
          ScalePhase.scanning,
          ScalePhase.connecting,
          ScalePhase.ready,
        ]),
      );
      expect(
        status.log.map((entry) => entry.message).join('\n'),
        contains('scelta a mano'),
      );
    });

    test('senza una scansione aperta la scelta non ha dove andare', () async {
      const muta = ScaleDevice(id: 'muta', name: '', rssi: -47);
      final link = FakeScaleLink(keepScanning: true, devices: const [muta]);
      final reader = readerFor(link);
      // Prima ancora di cercare non c'è nessuna scelta da completare.
      expect(reader.chooseWhileScanning(muta), isFalse);

      final result = reader.read();
      await link.announced;
      await link.endScan();

      final status = await result;
      expect(status.phase, ScalePhase.chooseDevice);
      // Scansione finita: da qui in poi la strada è `connectTo`, e dirlo con
      // un `false` è ciò che impedisce alla scelta di sparire nel nulla.
      expect(reader.chooseWhileScanning(status.candidates.single), isFalse);
    });

    test('un dispositivo mai riconosciuto, scelto a mano, arriva alla '
        'pesata', () async {
      final link = FakeScaleLink(devices: const []);
      final reader = readerFor(link);
      final phases = <ScalePhase>[];
      final result = reader.connectTo(
        const ScaleDevice(id: 'muta', name: '', rssi: -47),
        onStatus: (status) => phases.add(status.phase),
      );
      await pesa(link);

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.impedanceOhm, 442);
      expect(
        phases,
        containsAllInOrder([ScalePhase.connecting, ScalePhase.ready]),
      );
    });

    test('un collegamento rifiutato dopo la scelta resta un guasto '
        'leggibile', () async {
      // La scelta di Marco è comunque valida: qui fallisce il collegamento,
      // non la risposta alla domanda «qual è la tua bilancia».
      final link = FakeScaleLink(devices: const [])
        ..connectException = ScaleLinkException(
          ScaleLinkFailure.connection,
          'gatt error 133',
        );
      final status = await readerFor(
        link,
      ).connectTo(const ScaleDevice(id: 'muta', name: ''));
      expect(status.phase, ScalePhase.failed);
      expect(status.errorDetail, contains('gatt error 133'));
    });
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
        expect(status.detail, contains('circuito chiuso'));
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

  group('il profilo standard del Bluetooth', () {
    // La bilancia vera di Marco, la R-MSC02: ci si collega, ma di `ffe0` e
    // `fff0` non c'è traccia — parla il profilo pubblicato dal SIG. Il nome
    // non la fa riconoscere da nessuna euristica, quindi la strada vera è
    // quella di `connectTo`: Marco la sceglie a mano dall'elenco.
    const renpho = ScaleDevice(id: 'r-msc02', name: 'R-MSC02', rssi: -46);

    FakeScaleLink linkStandard(ScaleProtocolKind protocol) =>
        FakeScaleLink(devices: const [], protocol: protocol);

    test('peso e impedenza nella stessa trama: pesata completa', () async {
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final reader = readerFor(link);
      final phases = <ScalePhase>[];
      final result = reader.connectTo(
        renpho,
        onStatus: (status) => phases.add(status.phase),
      );

      final connection = await link.opened;
      // Lo standard manda la misura **solo a pesata finita**: non c'è nessuna
      // trama instabile da scartare prima, e questa è già quella buona.
      await connection.emit(
        fakeGattBodyFrame(weightKg: 95.8, impedanceOhm: 442),
      );

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.impedanceOhm, closeTo(442, 0.001));
      expect(status.reading!.deviceName, 'R-MSC02');
      expect(status.reading!.measuredAt, moment);
      expect(
        status.reading!.rawPayloadHex,
        gattHex(fakeGattBodyFrame(weightKg: 95.8, impedanceOhm: 442)),
      );
      expect(
        phases,
        containsAllInOrder([
          ScalePhase.connecting,
          ScalePhase.stepOn,
          ScalePhase.ready,
        ]),
      );
    });

    test('alla bilancia non si scrive niente', () async {
      // Il dialogo QN comincia sincronizzando l'orologio e imponendo i
      // chilogrammi. Qui quei comandi non hanno nessun posto dove andare: lo
      // standard non ha caratteristiche di scrittura che li aspettino, e
      // spedirli lo stesso vorrebbe dire farsi chiudere il collegamento in
      // faccia prima ancora di leggere il peso.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final result = readerFor(link).connectTo(renpho);

      final connection = await link.opened;
      await connection.emit(
        fakeGattBodyFrame(weightKg: 95.8, impedanceOhm: 442),
      );

      expect((await result).phase, ScalePhase.ready);
      expect(connection.sent, isEmpty);
      expect(connection.closed, isTrue);
    });

    test('la bilancia che sa solo pesare chiude con il solo peso', () async {
      // `0x181D` è il ripiego: peso e nient'altro, per costruzione. Non è un
      // guasto e non va raccontato come tale — il peso vale ed entra nelle
      // medie, la composizione no.
      final link = linkStandard(ScaleProtocolKind.gattWeight);
      final result = readerFor(link).connectTo(renpho);

      final connection = await link.opened;
      await connection.emit(fakeGattWeightFrame(weightKg: 95.8));

      final status = await result;
      expect(status.phase, ScalePhase.incomplete);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.hasImpedance, isFalse);
      expect(status.detail, contains('circuito chiuso'));
      expect(
        status.log.map((entry) => entry.message).join('\n'),
        contains('solo peso'),
      );
    });

    test('impedenza in una trama e peso in quella dopo: i pezzi si '
        'sommano', () async {
      // Nel *Body Composition* il peso è un campo **opzionale**, e una
      // bilancia può mandare la misura elettrica per prima. È l'intera ragione
      // per cui il dialogo accumula invece di decidere su una trama sola:
      // guardando una trama per volta, qui non si concluderebbe mai niente.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final result = readerFor(link).connectTo(renpho);

      final connection = await link.opened;
      await connection.emit(fakeGattBodyFrame(impedanceOhm: 442));
      await connection.emit(fakeGattBodyFrame(weightKg: 95.8));

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.impedanceOhm, closeTo(442, 0.001));
    });

    test('una misura spezzata in due pacchetti si chiude lo stesso', () async {
      // **Il difetto che questo test fissa.** Il bit 12 era stato letto come
      // «dopo di me ne arriva un altro», e su quella lettura il dialogo si
      // fermava aspettando il seguito. Ma la specifica (BCS 1.0.1 §3.2.1)
      // impone il bit acceso in ENTRAMBI i pacchetti: descrive la misura, non
      // il pacchetto. Quindi anche l'ultimo ce l'ha, si aspettava un terzo che
      // non esiste, e la pesata moriva per scadenza del tempo di salita con
      // peso e impedenza già in mano.
      //
      // Qui i due pacchetti sono come li manda una bilancia conforme: bit
      // acceso su tutti e due, impedenza nel primo e peso nel secondo.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final reader = readerFor(link);
      final phases = <ScalePhase>[];
      final result = reader.connectTo(
        renpho,
        onStatus: (status) => phases.add(status.phase),
      );

      final connection = await link.opened;
      await connection.emit(fakeGattBodyFrame(impedanceOhm: 442, split: true));
      // Senza peso non c'è ancora niente da chiudere, ed è giusto aspettare.
      expect(connection.closed, isFalse);
      expect(phases.last, ScalePhase.reading);

      await connection.emit(fakeGattBodyFrame(weightKg: 95.8, split: true));

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.impedanceOhm, closeTo(442, 0.001));
      // Il grezzo tiene TUTTI i pacchetti: con il solo secondo, la coppia
      // peso-impedenza non sarebbe più ricostruibile, e `rawPayloadHex`
      // prometterebbe una cosa che non mantiene.
      expect(status.reading!.rawPayloadHex, contains(' | '));
    });

    test('Renpho R-MSC02: il peso si consegna subito e si resta in '
        'ascolto', () async {
      // Le trame sono quelle vere del 6 agosto. Due cose insieme: il peso è
      // disponibile da salvare appena arriva il `0x24`, e la sessione NON si
      // chiude lì — l'impedenza in questo protocollo non si è ancora vista, e
      // l'unico modo di trovarla è restare in ascolto oltre il peso.
      final link = linkStandard(ScaleProtocolKind.renphoMsc);
      final reader = readerFor(link);
      final fasi = <ScalePhase>[];
      final result = reader.connectTo(
        renpho,
        onStatus: (status) => fasi.add(status.phase),
      );

      final connection = await link.opened;
      await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
        0x55,
        0xaa,
        0x21,
        0x00,
        0x05,
        0x01,
        0x00,
        0x00,
        0x24,
        0x9f,
        0xe9,
      ]);
      expect(fasi.last, ScalePhase.reading);
      expect(connection.closed, isFalse);

      await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
        0x55,
        0xaa,
        0x24,
        0x00,
        0x06,
        0x01,
        0x11,
        0x00,
        0x00,
        0x25,
        0xb2,
        0x12,
      ]);
      // Il peso c'è già, il collegamento è ancora aperto, e la fase dice
      // «non scendere» invece di «finito». È tutto il punto: l'impedenza si
      // misura DOPO il peso, e solo finché i piedi sono sugli elettrodi —
      // mostrare un esito qui equivaleva a dirgli di scendere un istante
      // prima del dato che serve.
      expect(fasi.last, ScalePhase.holdStill);
      expect(ScalePhase.holdStill.hasReading, isTrue);
      expect(connection.closed, isFalse);

      // Una trama mai vista arriva DOPO il peso: senza restare in ascolto
      // sarebbe andata persa, ed è lì che l'impedenza va cercata.
      await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
        0x55,
        0xaa,
        0x2f,
        0x00,
        0x04,
        0x01,
        0x02,
        0x03,
        0x04,
        0x38,
      ]);
      await connection.dropConnection();

      final status = await result;
      expect(status.phase, ScalePhase.incomplete);
      expect(status.reading!.weightKg, closeTo(96.50, 0.001));
      expect(status.phase.hasReading, isTrue);
      final registro = status.log.map((entry) => entry.hex).toList();
      expect(registro, contains('55 aa 2f 00 04 01 02 03 04 38'));
      // Il grezzo salvato tiene tutte le trame, non solo l'ultima.
      expect(status.reading!.rawPayloadHex, contains(' | '));
    });

    test(
      'il contatore che cresce dice «ha misurato e non me lo manda»',
      () async {
        // La differenza fra i due modi di non avere l'impedenza, e sono opposti:
        // «non è riuscita a misurare» manda Marco a rifare la pesata, «ha
        // misurato e se lo tiene» dice che il problema è nostro, non suo. Il
        // contatore nel battito della bilancia distingue i due casi — nella
        // sessione del 6 agosto è passato da 4 a 5 esattamente quando il body
        // scan è finito sul display.
        final link = linkStandard(ScaleProtocolKind.renphoMsc);
        final reader = readerFor(link);
        final result = reader.connectTo(renpho);

        final connection = await link.opened;
        await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
          0x55,
          0xaa,
          0x20,
          0x00,
          0x05,
          0x00,
          0x01,
          0x01,
          0x04,
          0x00,
          0x2a,
        ]);
        await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
          0x55,
          0xaa,
          0x24,
          0x00,
          0x06,
          0x01,
          0x11,
          0x00,
          0x00,
          0x26,
          0x11,
          0x72,
        ]);
        // Il body scan finisce: il contatore sale.
        await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
          0x55,
          0xaa,
          0x20,
          0x00,
          0x05,
          0x04,
          0x05,
          0x01,
          0x05,
          0x00,
          0x33,
        ]);
        await connection.dropConnection();

        final status = await result;
        expect(status.phase, ScalePhase.incomplete);
        expect(status.reading!.weightKg, closeTo(97.45, 0.001));
        expect(status.errorDetail, contains('body scan lo ha fatto'));
        expect(status.errorDetail, contains('da 4 a 5'));
      },
    );

    test(
      'senza body scan si dice cosa manca, non si dà la colpa alle calze',
      () async {
        // Il contatore resta fermo: la misura non è stata proprio fatta, e
        // l'unica cosa utile da dire è come chiudere il circuito.
        final link = linkStandard(ScaleProtocolKind.renphoMsc);
        final reader = readerFor(link);
        final result = reader.connectTo(renpho);

        final connection = await link.opened;
        await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
          0x55,
          0xaa,
          0x20,
          0x00,
          0x05,
          0x00,
          0x01,
          0x01,
          0x04,
          0x00,
          0x2a,
        ]);
        await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
          0x55,
          0xaa,
          0x24,
          0x00,
          0x06,
          0x01,
          0x11,
          0x00,
          0x00,
          0x26,
          0x11,
          0x72,
        ]);
        await connection.emitFrom(ScaleProtocolKind.renphoMsc, const [
          0x55,
          0xaa,
          0x20,
          0x00,
          0x05,
          0x04,
          0x05,
          0x01,
          0x04,
          0x00,
          0x32,
        ]);
        await connection.dropConnection();

        final status = await result;
        expect(status.errorDetail, contains('circuito chiuso'));
        expect(status.errorDetail, isNot(contains('body scan lo ha fatto')));
      },
    );

    test('protocollo sconosciuto: si registra tutto, e conta come '
        'successo', () async {
      // La R-MSC02 parla `1a10`, un servizio che non sta nello standard e che
      // nessuno ha pubblicato. Fermarsi a «non lo conosco» significava pagare
      // un giro di pubblicazione per ogni ipotesi sul formato; registrare i
      // byte veri lo risolve una volta sola. Perciò l'esito è **buono**: la
      // cattura è riuscita, anche se non si è capito niente.
      final link = linkStandard(ScaleProtocolKind.unknown);
      final reader = readerFor(link);
      final result = reader.connectTo(renpho);

      final connection = await link.opened;
      await connection.emitFrom(ScaleProtocolKind.unknown, const [
        0x01,
        0x02,
        0x03,
      ]);
      // La stessa trama tre volte: una bilancia che trasmette in continuo lo
      // fa in continuazione, e scriverle tutte caccerebbe fuori dal registro
      // proprio le prime — quelle che dichiarano il protocollo.
      await connection.emitFrom(ScaleProtocolKind.unknown, const [
        0x01,
        0x02,
        0x03,
      ]);
      await connection.emitFrom(ScaleProtocolKind.unknown, const [0xaa, 0xbb]);
      await connection.dropConnection();

      final status = await result;
      expect(status.phase, ScalePhase.captured);
      final registro = status.log.map((entry) => entry.hex).toList();
      expect(registro, contains('01 02 03'));
      expect(registro, contains('aa bb'));
      // Scritta una volta sola, non tre.
      expect(registro.where((hex) => hex == '01 02 03'), hasLength(1));
      expect(
        status.log.map((entry) => entry.message).join('\n'),
        allOf(contains('3 trame'), contains('2 diverse')),
      );
    });

    test(
      'protocollo sconosciuto che non dice niente resta un guasto',
      () async {
        // Nessuna trama vuol dire nessuna pista, e chiamarlo «riuscito» sarebbe
        // una bugia. Ma il messaggio deve dire cosa farne lo stesso: l'elenco
        // dei servizi, che c'è comunque, è già qualcosa.
        final link = linkStandard(ScaleProtocolKind.unknown);
        final reader = readerFor(link);
        final result = reader.connectTo(renpho);

        final connection = await link.opened;
        await connection.dropConnection();

        final status = await result;
        expect(status.phase, ScalePhase.failed);
      },
    );

    test('la bilancia che dichiara la pesata non riuscita lo dice', () async {
      // `0xFFFF` nel grasso non vuol dire «campo assente»: vuol dire che la
      // pesata è fallita (BCS 1.0.1 §3.2.1.2). È un esito della bilancia, non
      // un guasto nostro, e mostrarlo come «misura vuota» lascerebbe Marco a
      // fissare uno spinner fino allo scadere del tempo.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final reader = readerFor(link);
      final result = reader.connectTo(renpho);

      final connection = await link.opened;
      await connection.emit(fakeGattFailedFrame());

      final status = await result;
      expect(status.phase, ScalePhase.failed);
      expect(status.errorDetail, contains('non è riuscita'));
      expect(status.reading, isNull);
    });

    test('peso da una caratteristica, impedenza dall’altra', () async {
      // Nel *Body Composition* il peso è opzionale, e il motivo è proprio
      // questo: una bilancia che espone anche il *Weight Scale* lo manda di
      // là. Ascoltandone una sola arriverebbe l'impedenza senza mai un peso, e
      // la pesata morirebbe per scadenza con il numero già pubblicato
      // dall'altra parte.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final reader = readerFor(link);
      final result = reader.connectTo(renpho);

      final connection = await link.opened;
      await connection.emit(fakeGattBodyFrame(impedanceOhm: 442));
      await connection.emitFrom(
        ScaleProtocolKind.gattWeight,
        fakeGattWeightFrame(weightKg: 95.8),
      );

      final status = await result;
      expect(status.phase, ScalePhase.ready);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.impedanceOhm, closeTo(442, 0.001));
    });

    test('il collegamento che cade dopo il solo peso non butta via la '
        'salita', () async {
      // La bilancia si spegne appena si scende, e l'impedenza è l'ultima cosa
      // che manda: la caduta a metà è il caso normale, non l'incidente.
      // Trattarla come un guasto vorrebbe dire far risalire Marco per un peso
      // che era già arrivato.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final reader = readerFor(
        link,
        impedanceGrace: const Duration(seconds: 5),
      );
      final result = reader.connectTo(renpho);

      final connection = await link.opened;
      await connection.emit(fakeGattBodyFrame(weightKg: 95.8));
      await connection.dropConnection();

      final status = await result;
      expect(status.phase, ScalePhase.incomplete);
      expect(status.reading!.weightKg, closeTo(95.8, 0.001));
      expect(status.reading!.hasImpedance, isFalse);
      expect(
        status.log.map((entry) => entry.message),
        anyElement(contains('tengo la pesata che ho')),
      );
    });

    test('il registro nomina il protocollo riconosciuto', () async {
      // Senza questa riga, un registro raccolto sul campo non distingue «la
      // bilancia non ha mandato niente» da «le abbiamo parlato nella lingua
      // sbagliata» — che è esattamente il dubbio da cui è nato questo file.
      final link = linkStandard(ScaleProtocolKind.gattBodyComposition);
      final result = readerFor(link).connectTo(renpho);

      final connection = await link.opened;
      final trama = fakeGattBodyFrame(weightKg: 95.8, impedanceOhm: 442);
      await connection.emit(trama);

      final status = await result;
      final text = status.log.map((entry) => entry.toString()).join('\n');
      expect(text, contains('protocollo standard del Bluetooth'));
      expect(text, contains('peso e impedenza'));
      expect(text, contains('95.80 kg'));
      expect(text, contains('442 Ω'));
      expect(text, contains(gattHex(trama)));
    });
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

  group('la schermata che si chiude a metà', () {
    test('interrompere durante la ricerca ferma davvero la ricerca', () async {
      // Era un buco vero: `cancel()` guardava solo la sessione di dialogo, che
      // nasce dentro `_converse`. Durante la scansione non esisteva ancora,
      // quindi chiudere la schermata non fermava niente — la ricerca andava
      // avanti per i suoi trenta secondi e poi si collegava lo stesso a una
      // bilancia che nessuno stava più guardando.
      final link = FakeScaleLink(
        keepScanning: true,
        devices: const [ScaleDevice(id: 'muta', name: '', rssi: -60)],
      );
      final reader = readerFor(link);
      final sessione = reader.read();
      await link.announced;

      reader.cancel();
      // Ora la bilancia si annuncia: senza la correzione la ricerca era ancora
      // viva, la riconosceva e ci si collegava a schermata chiusa.
      link.announce(
        const ScaleDevice(id: 'bilancia', name: QnScale.advertisedName),
      );

      final status = await sessione;
      expect(status.phase, ScalePhase.failed);
      expect(link.scanStopped, isTrue);
      expect(link.connections, isEmpty);
      expect(
        status.log.map((entry) => entry.message),
        anyElement(contains('interrotta durante la ricerca')),
      );
    });

    test('interrompere mentre si aggancia chiude subito il collegamento', () {
      // Una richiesta di collegamento non si può richiamare indietro. L'unica
      // cosa onesta è aprirlo e chiuderlo all'istante: la bilancia resta
      // libera per il tentativo dopo, invece di restare occupata fino allo
      // scadere del tempo di salita.
      return fakeAsyncTest((elapse) async {
        final link = FakeScaleLink(
          connectDelay: const Duration(milliseconds: 50),
        );
        final reader = readerFor(link);
        final sessione = reader.read();
        // Quanto basta perché la ricerca finisca e il collegamento parta, non
        // abbastanza perché si apra.
        await elapse(const Duration(milliseconds: 20));

        reader.cancel();
        await elapse(const Duration(milliseconds: 100));

        final status = await sessione;
        expect(status.phase, ScalePhase.failed);
        expect(link.connections, hasLength(1));
        expect(link.connections.single.closed, isTrue);
      });
    });
  });
}

/// Esegue [body] lasciando avanzare il tempo davvero, in piccoli passi.
///
/// I tempi qui in gioco sono decine di millisecondi veri e non fotogrammi
/// finti: il lettore non è un widget e non ha un `pump` che lo faccia
/// procedere.
Future<void> fakeAsyncTest(
  Future<void> Function(Future<void> Function(Duration) elapse) body,
) => body((duration) => Future<void>.delayed(duration));
