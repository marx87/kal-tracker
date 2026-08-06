import 'package:flutter/foundation.dart';

/// Il protocollo Bluetooth della bilancia che si annuncia come `QN-Scale`
/// (le Renpho, e tutte le altre costruite da Qingniu).
///
/// **Da dove viene.** Non è documentato dal costruttore: è stato ricavato dai
/// progetti liberi che lo hanno decodificato — openScale (`QNHandler.kt`) e
/// ble-scale-sync. Qui è riscritto in Dart puro e messo sotto test, perché è
/// l'unico pezzo di questa funzione che si può provare senza avere la
/// bilancia sotto i piedi.
///
/// **Cosa fa la bilancia.** Appena connessa manda una trama `0x12` che
/// dichiara il tipo di protocollo e la scala del peso. Da quel momento in poi,
/// finché qualcuno ci sale sopra, manda trame `0x10`: peso corrente, un
/// indicatore di stabilità e due resistenze. La lettura buona è la prima trama
/// `0x10` **stabile**.
///
/// **Cosa NON fa questo file.** Non calcola percentuali. La bilancia manda
/// resistenze; le percentuali le calcola `bia_formula.dart`, con una formula
/// nostra e versionata.
abstract final class QnScale {
  /// Il nome con cui la bilancia si annuncia, quando lo annuncia: in un
  /// pacchetto BLE ci stanno 31 byte e moltissimi dispositivi il nome lo
  /// omettono. Non è quindi un filtro sufficiente — vedi [looksLikeQnScale],
  /// che guarda anche i servizi dichiarati.
  static const advertisedName = 'QN-Scale';

  /// Profilo «tipo 1», il più diffuso e quello della bilancia di Marco.
  static const serviceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
  static const notifyUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
  static const writeUuid = '0000ffe3-0000-1000-8000-00805f9b34fb';
  static const timeUuid = '0000ffe4-0000-1000-8000-00805f9b34fb';

  /// Profilo «tipo 2», su alcuni modelli più recenti: stesso dialogo, altre
  /// caratteristiche. Si cercano entrambi e si usa quello che si trova.
  static const altServiceUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
  static const altNotifyUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
  static const altWriteUuid = '0000fff2-0000-1000-8000-00805f9b34fb';

  /// L'orologio della bilancia parte dal 2000, non dal 1970: 946.702.800
  /// secondi di differenza. Sbagliarlo non rompe la lettura dal vivo, ma
  /// daterebbe male le pesate che la bilancia conserva da sola.
  static const epochOffsetSeconds = 946702800;

  /// Il valore che la bilancia dichiara nella `0x12` e che va rimandato
  /// indietro in ogni comando. `0x15` è il ripiego storico, per le bilance che
  /// la `0x12` non la mandano mai.
  static const defaultProtocolType = 0x15;

  /// Unità di misura da imporre alla bilancia: chilogrammi. Senza questo
  /// comando una bilancia lasciata in libbre manderebbe libbre, e nessuno se
  /// ne accorgerebbe finché il peso non fosse assurdo.
  static const unitKilograms = 0x01;

  static const opcodeHandshake = 0x12;
  static const opcodeWeight = 0x10;
  static const opcodeTimeReply = 0x20;
  static const opcodeConfigReply = 0x13;
}

/// Vero quando il nome annunciato è quello di una bilancia che parla il
/// protocollo QN.
///
/// L'elenco è più largo del solo «QN-Scale» perché lo stesso protocollo gira
/// sotto marchi e modelli diversi: Renpho, FITINDEX, Kamtron e altri
/// rimarchiano la stessa elettronica, e alcune si annunciano col nome del
/// modello invece che con quello della famiglia. Riconoscerne una in più
/// costa un tentativo di connessione fallito; riconoscerne una in meno
/// significa che l'app non trova la bilancia che hai in bagno.
bool isQnScaleName(String? name) {
  final clean = name?.trim().toUpperCase() ?? '';
  if (clean.isEmpty) {
    return false;
  }
  const prefissi = [
    'QN-SCALE',
    'QN SCALE',
    'QN-',
    'RENPHO',
    'ES-CS20M',
    'ES-26BB',
    'ES-30M',
    'FITINDEX',
    'KAMTRON',
  ];
  return prefissi.any(clean.startsWith);
}

/// Vero quando fra i servizi annunciati c'è quello della bilancia.
///
/// Serve perché il nome, da solo, non basta: in un annuncio BLE ci stanno 31
/// byte e moltissimi dispositivi il nome lo omettono — nel registro di Marco
/// erano più della metà, presenti col solo indirizzo. Una bilancia muta è
/// comunque riconoscibile da `ffe0` (o `fff0` sui modelli più recenti), che
/// è esattamente il servizio da cui poi si leggono le trame.
bool hasQnScaleService(Iterable<String> serviceUuids) {
  const famiglie = [QnScale.serviceUuid, QnScale.altServiceUuid];
  for (final uuid in serviceUuids) {
    final clean = uuid.trim().toLowerCase();
    if (clean.isEmpty) {
      continue;
    }
    for (final famiglia in famiglie) {
      // Il confronto è sull'UUID lungo e sulla sua forma corta a 4 cifre:
      // Android annuncia `0000ffe0-0000-1000-8000-00805f9b34fb`, altri
      // stack accorciano in `ffe0`, ed è lo stesso servizio.
      final corto = famiglia.substring(4, 8);
      if (clean == famiglia ||
          clean == corto ||
          clean.startsWith('0000$corto')) {
        return true;
      }
    }
  }
  return false;
}

/// Se questo dispositivo vale un tentativo di connessione.
///
/// Nome **oppure** servizio: basta uno dei due. Un falso positivo costa una
/// connessione fallita e una riga nel registro; un falso negativo costa una
/// bilancia che «non si trova» mentre è a un metro di distanza.
bool looksLikeQnScale({
  String? name,
  Iterable<String> serviceUuids = const [],
}) => isQnScaleName(name) || hasQnScaleService(serviceUuids);

/// La somma dei byte, modulo 256, nell'ultimo byte della trama.
///
/// Non è un controllo di integrità serio ed è per questo che qui **non si
/// scarta** una trama con la somma sbagliata: si annota e si va avanti. Buttare
/// via l'unica pesata della giornata per un bit storto sarebbe peggio del
/// male che il controllo previene.
int qnChecksum(Iterable<int> bytes) {
  var sum = 0;
  for (final byte in bytes) {
    sum = (sum + (byte & 0xFF)) & 0xFF;
  }
  return sum;
}

/// Una trama decodificata.
@immutable
sealed class QnFrame {
  const QnFrame({required this.raw, required this.checksumOk});

  /// I byte così come sono arrivati: è quello che finisce in
  /// `body_measurements.raw_payload`, perché se domani si scopre un campo che
  /// oggi non sappiamo leggere, lo storico si ridecodifica.
  final List<int> raw;

  /// Falso quando la somma di controllo non torna. Descrittivo, non
  /// eliminatorio.
  final bool checksumOk;

  String get hex => qnHex(raw);
}

/// `0x12` — la bilancia si presenta.
@immutable
final class QnHandshakeFrame extends QnFrame {
  const QnHandshakeFrame({
    required this.protocolType,
    required this.weightScaleFactor,
    required super.raw,
    required super.checksumOk,
  });

  final int protocolType;

  /// Per quanto è moltiplicato il peso nelle trame: 100 (centesimi di kg)
  /// oppure 10. La bilancia lo dichiara qui e vale per tutta la sessione.
  final double weightScaleFactor;

  @override
  String toString() =>
      'presentazione (tipo 0x${protocolType.toRadixString(16)}, '
      'peso ×${weightScaleFactor.toStringAsFixed(0)})';
}

/// `0x10` — peso corrente e resistenze.
@immutable
final class QnWeightFrame extends QnFrame {
  const QnWeightFrame({
    required this.weightKg,
    required this.stable,
    required this.resistance1,
    required this.resistance2,
    required super.raw,
    required super.checksumOk,
  });

  final double weightKg;

  /// La bilancia distingue il peso che sta ancora oscillando da quello
  /// assestato. Solo il secondo si salva.
  final bool stable;

  /// La resistenza di corpo intero: **è la misura**, quella che alimenta la
  /// formula.
  final double resistance1;

  /// Una seconda resistenza, che la bilancia manda ma di cui non si conosce
  /// con certezza la frequenza. Non si salva in una colonna che direbbe
  /// «50 kHz» senza saperlo: resta dentro [raw], da cui si ridecodifica il
  /// giorno in cui il suo significato sarà noto.
  final double resistance2;

  /// Vero quando gli elettrodi hanno fatto contatto. Con i piedi asciutti, o
  /// con le calze, la bilancia pesa e basta: manda zero, e quella pesata vale
  /// come peso ma non come composizione.
  bool get hasImpedance => resistance1 > 0;

  @override
  String toString() =>
      'peso ${weightKg.toStringAsFixed(2)} kg '
      '${stable ? 'stabile' : 'in oscillazione'}, '
      'R1 ${resistance1.toStringAsFixed(0)} Ω, '
      'R2 ${resistance2.toStringAsFixed(0)} Ω';
}

/// Tutto il resto: la bilancia parla anche di batteria, di utenti memorizzati
/// e di pesate conservate. Si annota l'opcode e si tira dritto — una trama non
/// capita non è un errore.
@immutable
final class QnUnknownFrame extends QnFrame {
  const QnUnknownFrame({
    required this.opcode,
    required super.raw,
    required super.checksumOk,
  });

  final int opcode;

  @override
  String toString() => 'trama 0x${opcode.toRadixString(16).padLeft(2, '0')}';
}

/// Legge una trama.
///
/// [weightScaleFactor] arriva dalla presentazione: prima di riceverla vale
/// 100, che è il caso comune.
QnFrame? decodeQnFrame(List<int> data, {double weightScaleFactor = 100}) {
  if (data.isEmpty) {
    return null;
  }
  final bytes = List<int>.unmodifiable(data.map((b) => b & 0xFF));
  final opcode = bytes.first;
  // L'ultimo byte è la somma dei precedenti. Le trame di un byte non ne hanno
  // e passano per buone.
  final checksumOk =
      bytes.length < 2 ||
      qnChecksum(bytes.take(bytes.length - 1)) == bytes.last;

  switch (opcode) {
    case QnScale.opcodeHandshake:
      if (bytes.length <= 10) {
        return QnUnknownFrame(
          opcode: opcode,
          raw: bytes,
          checksumOk: checksumOk,
        );
      }
      return QnHandshakeFrame(
        protocolType: bytes[2],
        weightScaleFactor: bytes[10] == 1 ? 100 : 10,
        raw: bytes,
        checksumOk: checksumOk,
      );

    case QnScale.opcodeWeight:
      return _decodeWeight(bytes, weightScaleFactor, checksumOk);

    default:
      return QnUnknownFrame(opcode: opcode, raw: bytes, checksumOk: checksumOk);
  }
}

QnFrame? _decodeWeight(List<int> bytes, double scaleFactor, bool checksumOk) {
  if (bytes.length < 6) {
    return null;
  }

  // Due disposizioni diverse sotto lo stesso opcode. Le distingue il quinto
  // byte: nella disposizione originale è la parte bassa del peso e vale quasi
  // sempre più di 2, in quella dei modelli ES-30M è l'indicatore di
  // stabilità. La regola è quella di openScale, ed è l'unica che regge sul
  // campo con entrambe le famiglie.
  final byte4 = bytes[4];
  final isAlternateLayout = byte4 <= 0x02 && scaleFactor == 10;

  final bool stable;
  final int rawWeight;
  final int r1;
  final int r2;
  if (isAlternateLayout) {
    if (bytes.length < 11) {
      return null;
    }
    stable = byte4 == 0x01 || byte4 == 0x02;
    rawWeight = _u16be(bytes[5], bytes[6]);
    r1 = _u16be(bytes[7], bytes[8]);
    r2 = _u16be(bytes[9], bytes[10]);
  } else {
    if (bytes.length < 10) {
      return null;
    }
    stable = bytes[5] == 0x01;
    rawWeight = _u16be(bytes[3], bytes[4]);
    r1 = _u16be(bytes[6], bytes[7]);
    r2 = _u16be(bytes[8], bytes[9]);
  }

  var weightKg = rawWeight / scaleFactor;
  // Rete di sicurezza di openScale: quando il fattore dichiarato non
  // corrisponde a quello usato davvero, il peso esce di un ordine di
  // grandezza. Un valore fuori dal possibile umano si divide una volta e si
  // riprova, invece di salvare 958 kg.
  if (weightKg <= 5 || weightKg >= 250) {
    weightKg = weightKg / 10;
  }
  if (!weightKg.isFinite || weightKg < 20 || weightKg > 300) {
    // Non è una pesata: probabilmente è la bilancia che si sta accendendo.
    return QnUnknownFrame(
      opcode: QnScale.opcodeWeight,
      raw: bytes,
      checksumOk: checksumOk,
    );
  }

  return QnWeightFrame(
    weightKg: weightKg,
    stable: stable,
    resistance1: r1.toDouble(),
    resistance2: r2.toDouble(),
    raw: bytes,
    checksumOk: checksumOk,
  );
}

int _u16be(int high, int low) => ((high & 0xFF) << 8) | (low & 0xFF);

/// Il comando che fissa l'unità di misura (`0x13`).
///
/// Nove byte, l'ultimo è la somma: è la bilancia che si aspetta questa
/// lunghezza, dichiarata dal secondo byte.
List<int> qnConfigCommand({
  int protocolType = QnScale.defaultProtocolType,
  int unit = QnScale.unitKilograms,
}) {
  final frame = <int>[
    QnScale.opcodeConfigReply,
    0x09,
    protocolType & 0xFF,
    unit & 0xFF,
    0x10,
    0x00,
    0x00,
    0x00,
    0x00,
  ];
  frame[frame.length - 1] = qnChecksum(frame.take(frame.length - 1));
  return List<int>.unmodifiable(frame);
}

/// Il comando che sincronizza l'orologio della bilancia (`0x20`).
///
/// I secondi viaggiano **little-endian**, al contrario del peso: è così, e
/// invertirli sposterebbe le pesate conservate di decenni.
List<int> qnTimeCommand({
  required DateTime now,
  int protocolType = QnScale.defaultProtocolType,
}) {
  final seconds =
      (now.toUtc().millisecondsSinceEpoch ~/ 1000) - QnScale.epochOffsetSeconds;
  final t = seconds < 0 ? 0 : seconds;
  final frame = <int>[
    QnScale.opcodeTimeReply,
    0x08,
    protocolType & 0xFF,
    t & 0xFF,
    (t >> 8) & 0xFF,
    (t >> 16) & 0xFF,
    (t >> 24) & 0xFF,
    0x00,
  ];
  frame[frame.length - 1] = qnChecksum(frame.take(frame.length - 1));
  return List<int>.unmodifiable(frame);
}

/// I byte in esadecimale minuscolo, senza separatori: è la forma che finisce
/// nel registro diagnostico e in `raw_payload`.
String qnHex(Iterable<int> bytes) =>
    bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();

/// L'inverso di [qnHex]. Serve a ridecodificare uno storico salvato, che è
/// tutto il motivo per cui `raw_payload` esiste.
List<int>? qnBytesFromHex(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.isEmpty || clean.length.isOdd) {
    return null;
  }
  final bytes = <int>[];
  for (var i = 0; i < clean.length; i += 2) {
    final value = int.tryParse(clean.substring(i, i + 2), radix: 16);
    if (value == null) {
      return null;
    }
    bytes.add(value);
  }
  return List<int>.unmodifiable(bytes);
}
