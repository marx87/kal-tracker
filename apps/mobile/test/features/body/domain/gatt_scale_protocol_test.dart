import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/body/domain/gatt_scale_protocol.dart';

/// Le trame di questo file sono scritte a mano dalla specifica del Bluetooth
/// SIG — *Body Composition Measurement* (`0x2A9C`) e *Weight Measurement*
/// (`0x2A9D`) — e non generate da un costruttore che rispecchi il
/// decodificatore: una trama costruita con la stessa idea che poi si vuole
/// verificare si adatterebbe a qualunque errore, compreso quello che si sta
/// cercando. Ogni byte porta accanto il campo e il valore che rappresenta.
void main() {
  group('composizione corporea (0x2A9C)', () {
    test('peso e impedenza in SI escono nelle loro unità', () {
      // Il caso normale della R-MSC02: flag con impedenza (bit 9) e peso
      // (bit 10) accesi, nient'altro. Un'unità di massa vale 5 g,
      // un'unità di impedenza 0,1 Ω: sono le due risoluzioni che, se
      // sbagliate, danno numeri comunque plausibili — e quindi non si
      // notano guardando l'app.
      final misura = decodeGattFrame(const [
        0x00, 0x06, // flag 0x0600: SI, impedenza e peso presenti
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0x03, 0x14, // impedenza 512,3 Ω (5123 × 0,1)
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.weightKg, closeTo(95.8, 0.0005));
      expect(misura.impedanceOhm, closeTo(512.3, 0.005));
      expect(misura.bodyFatPct, closeTo(22.4, 0.005));
      expect(misura.hasWeight, isTrue);
      expect(misura.hasImpedance, isTrue);
      expect(misura.splitMeasurement, isFalse);
      // La trama grezza si conserva così com'è: è l'unica cosa che resta se
      // domani si scopre che la decodifica era sbagliata.
      expect(misura.hex, '00 06 e0 00 03 14 d8 4a');
    });

    test('in imperiale il peso arriva in libbre e va convertito', () {
      // La bilancia lasciata in libbre dall'app del costruttore continua a
      // mandarle: senza conversione Marco leggerebbe 211 kg e penserebbe a
      // un guasto, oppure — peggio — a 105 kg e ci crederebbe.
      final misura = decodeGattFrame(const [
        0x01, 0x04, // flag 0x0401: imperiale, peso presente
        0xc8, 0x00, // grasso 20,0 % (200 × 0,1)
        0x80, 0x52, // peso 211,2 lb (21120 × 0,01)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      // 211,2 lb × 0,45359237 = 95,798708544 kg.
      expect(misura.weightKg, closeTo(95.798708544, 0.000001));
      expect(misura.bodyFatPct, closeTo(20.0, 0.005));
    });

    test('in imperiale la percentuale d’acqua non dipende dall’unità', () {
      // L'acqua arriva in massa, non in percentuale: massa e peso sono nella
      // stessa unità, quindi il rapporto è lo stesso in kg e in libbre. Se
      // uno dei due venisse convertito e l'altro no, qui salterebbe fuori.
      final misura = decodeGattFrame(const [
        0x01, 0x05, // flag 0x0501: imperiale, acqua (bit 8) e peso
        0xc8, 0x00, // grasso 20,0 % (200 × 0,1)
        0x50, 0x2d, // acqua 116,0 lb (11600 × 0,01)
        0x80, 0x52, // peso 211,2 lb (21120 × 0,01)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      // 116,0 / 211,2 = 54,924 %, identico al rapporto in chilogrammi.
      expect(misura.waterPct, closeTo(54.9242424, 0.00001));
      expect(misura.weightKg, closeTo(95.798708544, 0.000001));
    });

    test('con tutti gli opzionali accesi ogni campo resta al suo posto', () {
      // Questo è il test che conta. I campi opzionali arrivano in un ordine
      // fisso — data, utente, metabolismo, muscolo %, massa muscolare, massa
      // magra, massa magra molle, acqua, impedenza, peso, altezza — e ogni
      // campo saltato o letto fuori ordine sposta in silenzio tutti quelli
      // dopo. Il peso e l'impedenza sono in fondo: sono i primi a diventare
      // numeri sbagliati ma credibili.
      final misura = decodeGattFrame(const [
        0xfe, 0x0f, // flag 0x0FFE: SI, tutti gli opzionali presenti
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0xea, 0x07, // data: anno 2026
        0x08, // mese 8
        0x06, // giorno 6
        0x07, // ora 7
        0x1e, // minuti 30
        0x0c, // secondi 12
        0x01, // identificativo utente sulla bilancia
        0x58, 0x1b, // metabolismo basale 7000 kJ
        0x9f, 0x01, // muscolo 41,5 % (415 × 0,1)
        0xf0, 0x1e, // massa muscolare 39,6 kg (7920 × 0,005)
        0x0c, 0x3a, // massa magra 74,3 kg (14860 × 0,005)
        0xb0, 0x36, // massa magra molle 70,0 kg (14000 × 0,005)
        0x18, 0x29, // acqua 52,6 kg (10520 × 0,005)
        0x03, 0x14, // impedenza 512,3 Ω (5123 × 0,1)
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
        0xf4, 0x06, // altezza 1,780 m (1780 × 0,001)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.weightKg, closeTo(95.8, 0.0005));
      expect(misura.impedanceOhm, closeTo(512.3, 0.005));
      expect(misura.bodyFatPct, closeTo(22.4, 0.005));
      expect(misura.musclePct, closeTo(41.5, 0.005));
      // 52,6 kg d'acqua su 95,8 kg di peso.
      expect(misura.waterPct, closeTo(54.906054, 0.00001));
      // 7000 kJ × 0,239 = 1673 kcal.
      expect(misura.basalMetabolismKcal, closeTo(1673.04, 0.01));
    });

    test('gli opzionali spenti non consumano nemmeno un byte', () {
      // Rovescio del test precedente: se il decodificatore avanzasse di un
      // solo byte per un campo assente, il peso finirebbe oltre la fine
      // della trama e uscirebbe nullo. La trama è lunga esattamente quanto
      // deve, quindi non c'è margine dove nascondere l'errore.
      final misura = decodeGattFrame(const [
        0x00, 0x04, // flag 0x0400: SI, solo il peso presente
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.weightKg, closeTo(95.8, 0.0005));
      expect(misura.impedanceOhm, isNull);
      expect(misura.musclePct, isNull);
      expect(misura.waterPct, isNull);
      expect(misura.basalMetabolismKcal, isNull);
      expect(misura.hasImpedance, isFalse);
    });

    test('il grasso da solo è una trama legittima di quattro byte', () {
      // Nessun flag acceso: restano i flag e il grasso, che nello standard è
      // l'unico campo sempre presente. È il minimo valido e non va scambiato
      // per una trama monca.
      final misura = decodeGattFrame(const [
        0x00, 0x00, // flag 0x0000: SI, nessun campo opzionale
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.bodyFatPct, closeTo(22.4, 0.005));
      expect(misura.weightKg, isNull);
      expect(misura.hasWeight, isFalse);
    });

    test('0xFFFF nel grasso vuol dire «pesata non riuscita»', () {
      // Questa è l'unica cosa che 0xFFFF significa davvero, e solo su questo
      // campo (BCS 1.0.1 §3.2.1.2): non «campo assente» — un campo che non c'è
      // si dichiara spegnendo il suo bit — ma «la pesata è fallita». La
      // specifica impone anche che in quel caso i campi opzionali siano
      // assenti, quindi non c'è altro da leggere.
      final misura = decodeGattFrame(const [
        0x00, 0x06, // flag 0x0600: SI, impedenza e peso dichiarati presenti
        0xff, 0xff, // pesata non riuscita
        0xff, 0xff,
        0xff, 0xff,
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.failed, isTrue);
      expect(misura.weightKg, isNull);
      expect(misura.impedanceOhm, isNull);
      expect(misura.bodyFatPct, isNull);
      expect('$misura', contains('non riuscita'));
    });

    test('un campo non disponibile occupa comunque il suo posto', () {
      // La pesata con le calze: la bilancia dichiara il peso e ammette di non
      // avere l'impedenza. I due byte del campo ci sono lo stesso, quindi
      // saltarli sposterebbe il peso.
      final misura = decodeGattFrame(const [
        0x00, 0x06, // flag 0x0600: SI, impedenza e peso presenti
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0xff, 0xff, // impedenza non disponibile
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.impedanceOhm, isNull);
      expect(misura.weightKg, closeTo(95.8, 0.0005));
    });

    test('il bit 12 dice «misura spezzata», non «continua»', () {
      // La differenza non è di parole. La specifica (BCS 1.0.1 §3.2.1) impone
      // il bit acceso in ENTRAMBI i pacchetti di una misura spezzata: descrive
      // la misura, non il pacchetto. Leggerlo come «dopo di me ne arriva un
      // altro» — l'errore che era stato fatto — significa aspettare all'
      // infinito un terzo pacchetto che non esiste, e far morire per scadenza
      // una pesata che era già completa.
      //
      // Per questo il campo non decide niente: è solo una riga di registro.
      final misura = decodeGattFrame(const [
        0x00, 0x14, // flag 0x1400: SI, peso presente, misura spezzata
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
      ], characteristic: GattScaleCharacteristic.bodyComposition)!;

      expect(misura.splitMeasurement, isTrue);
      // E il peso si legge lo stesso: un pacchetto di una misura spezzata è
      // comunque un pacchetto da cui si prendono i campi che porta.
      expect(misura.weightKg, closeTo(95.8, 0.0005));
    });

    test('una trama troncata a metà campo non fa saltare la lettura', () {
      // I flag promettono impedenza e peso, la trama finisce dentro
      // l'impedenza. Succede quando la notifica arriva spezzata: deve uscire
      // una misura povera, non un'eccezione che ferma la pesata.
      const troncata = [
        0x00, 0x06, // flag 0x0600: SI, impedenza e peso presenti
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0x03, // impedenza: manca il secondo byte
      ];

      expect(
        () => decodeGattFrame(
          troncata,
          characteristic: GattScaleCharacteristic.bodyComposition,
        ),
        returnsNormally,
      );
      final misura = decodeGattFrame(
        troncata,
        characteristic: GattScaleCharacteristic.bodyComposition,
      )!;
      expect(misura.impedanceOhm, isNull);
      expect(misura.weightKg, isNull);
      expect(misura.bodyFatPct, closeTo(22.4, 0.005));
    });

    test('una trama che si interrompe dentro la data non fa saltare', () {
      // La data occupa sette byte che non ci servono, ma vanno comunque
      // scavalcati: se la trama finisce lì in mezzo, il salto porta l'offset
      // oltre la fine e non deve leggere memoria che non c'è.
      const troncata = [
        0x02, 0x04, // flag 0x0402: SI, data presente, peso presente
        0xe0, 0x00, // grasso 22,4 % (224 × 0,1)
        0xea, 0x07, 0x08, // data: si interrompe al giorno
      ];

      expect(
        () => decodeGattFrame(
          troncata,
          characteristic: GattScaleCharacteristic.bodyComposition,
        ),
        returnsNormally,
      );
      final misura = decodeGattFrame(
        troncata,
        characteristic: GattScaleCharacteristic.bodyComposition,
      )!;
      // Il peso era promesso ma la trama è finita prima: nullo, non zero.
      expect(misura.weightKg, isNull);
    });

    test('sotto i quattro byte non c’è niente da leggere', () {
      // Flag e grasso sono obbligatori: sotto i loro quattro byte la trama
      // non è quella che dichiara di essere. Meglio una riga di registro che
      // dice «illeggibile» che un peso inventato.
      for (final corta in const [
        <int>[],
        [0x00],
        [0x00, 0x06],
        [0x00, 0x06, 0xe0],
      ]) {
        expect(
          decodeGattFrame(
            corta,
            characteristic: GattScaleCharacteristic.bodyComposition,
          ),
          isNull,
          reason: 'trama di ${corta.length} byte',
        );
      }
    });
  });

  group('solo peso (0x2A9D)', () {
    test('in SI il peso è un uint16 da cinque grammi', () {
      // Qui i flag stanno in un byte solo, non in due: è l'errore che
      // sposterebbe il peso di una posizione e darebbe comunque un numero.
      final misura = decodeGattFrame(const [
        0x00, // flag: SI, nessun campo opzionale
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
      ], characteristic: GattScaleCharacteristic.weight)!;

      expect(misura.weightKg, closeTo(95.8, 0.0005));
      expect(misura.hasWeight, isTrue);
      expect(misura.hex, '00 d8 4a');
    });

    test('in imperiale il peso passa da libbre a chilogrammi', () {
      final misura = decodeGattFrame(const [
        0x01, // flag: imperiale
        0x80, 0x52, // peso 211,2 lb (21120 × 0,01)
      ], characteristic: GattScaleCharacteristic.weight)!;

      expect(misura.weightKg, closeTo(95.798708544, 0.000001));
    });

    test('data, utente e BMI vengono dopo: il peso non si sposta', () {
      // In questa caratteristica il peso precede tutti gli opzionali. Se
      // qualcuno un giorno ne aggiungesse il salto prima del peso, questo
      // test lo prenderebbe subito.
      final misura = decodeGattFrame(const [
        0x0e, // flag: SI, data + utente + BMI e altezza presenti
        0xd8, 0x4a, // peso 95,8 kg (19160 × 0,005)
        0xea, 0x07, // data: anno 2026
        0x08, // mese 8
        0x06, // giorno 6
        0x07, // ora 7
        0x1e, // minuti 30
        0x0c, // secondi 12
        0x01, // identificativo utente sulla bilancia
        0x2e, 0x01, // BMI 30,2 (302 × 0,1)
        0xf4, 0x06, // altezza 1,780 m (1780 × 0,001)
      ], characteristic: GattScaleCharacteristic.weight)!;

      expect(misura.weightKg, closeTo(95.8, 0.0005));
    });

    test('anche qui 0xFFFF resta un peso che non c’è', () {
      final misura = decodeGattFrame(const [
        0x00, // flag: SI
        0xff, 0xff, // peso non disponibile
      ], characteristic: GattScaleCharacteristic.weight)!;

      expect(misura.weightKg, isNull);
      expect(misura.hasWeight, isFalse);
      // La trama si conserva lo stesso: serve a capire perché non c'è peso.
      expect(misura.hex, '00 ff ff');
    });

    test('sotto i tre byte non c’è un peso', () {
      for (final corta in const [
        <int>[],
        [0x00],
        [0x00, 0xd8],
      ]) {
        expect(
          decodeGattFrame(
            corta,
            characteristic: GattScaleCharacteristic.weight,
          ),
          isNull,
          reason: 'trama di ${corta.length} byte',
        );
      }
    });
  });

  group('esadecimale', () {
    test('due cifre per byte, minuscole, separate da spazio', () {
      // Il registro si legge a occhio quando si confronta una trama con la
      // specifica: lo zero iniziale non va perso.
      expect(gattHex(const [0x00, 0x0f, 0xff, 0x4a]), '00 0f ff 4a');
      expect(gattHex(const <int>[]), '');
    });
  });
}
