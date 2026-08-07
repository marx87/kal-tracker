import 'package:flutter/foundation.dart';

/// Il protocollo della **Renpho R-MSC02**, ricavato dalle sue trame vere.
///
/// **Da dove viene.** Non da una specifica: non ne esiste una. Il servizio
/// `1a10` non sta nei numeri assegnati dal Bluetooth SIG, openScale non ha un
/// driver per lui e cercando non salta fuori niente. Viene da una cattura
/// fatta con la bilancia sotto i piedi di Marco il 6 agosto 2026, con l'app
/// che registrava senza interpretare.
///
/// **La struttura**, ricavata da quindici trame distinte:
///
/// ```
///   55 AA │ opcode │ lunghezza (16 bit, big endian) │ payload │ somma
/// ```
///
/// La somma è il totale di **tutti** i byte precedenti, modulo 256 — verificata
/// a mano su tre trame di opcode diversi prima di scrivere una riga di codice.
///
/// **Cosa manda.** Mentre uno ci sale sopra arriva un flusso di `0x21` con il
/// peso corrente; quando si assesta arriva un `0x24` con lo stesso valore. Fra
/// una pesata e l'altra passano dei `0x20` che sembrano avanzamenti di stato.
///
/// **L'impedenza, e perché non arrivava.** La bilancia non la manda a nessuno
/// finché non sa **chi** ha sotto i piedi: senza altezza, sesso ed età non ha
/// niente da calcolare. Il 7 agosto 2026 il registro HCI di Android ha mostrato
/// i due comandi che l'app Renpho scrive su `2a11` e noi no — l'orologio
/// ([renphoClockCommand]) e il profilo ([renphoProfileCommand]) — e subito dopo
/// la trama `0x25` con nove impedenze segmentali. Non era una bilancia muta:
/// era una domanda che nessuno le aveva fatto.
///
/// **Le trame lunghe arrivano a pezzi.** Sopra i venti byte c'è un livello di
/// frammentazione tutto suo, prima dell'intestazione: `sequenza | 04 | quanti
/// ne mancano`. Il contatore scende a zero sull'ultimo pezzo. È il motivo per
/// cui la prima cattura non aveva mai visto la `0x25`: cercando `55 aa` in
/// testa, due frammenti su tre non somigliavano a niente.
abstract final class RenphoMsc {
  static const serviceUuid = '00001a10-0000-1000-8000-00805f9b34fb';

  /// Da qui è arrivato il flusso del peso corrente.
  static const liveUuid = '00002a10-0000-1000-8000-00805f9b34fb';

  /// Da qui sono arrivati il peso stabile e gli avanzamenti di stato.
  static const statusUuid = '00002a12-0000-1000-8000-00805f9b34fb';

  /// L'unica delle tre che non ha mai parlato: quasi certamente ci si scrive.
  static const writeUuid = '00002a11-0000-1000-8000-00805f9b34fb';

  static const header0 = 0x55;
  static const header1 = 0xAA;

  /// I due byte di intestazione, l'opcode, i due di lunghezza e la somma:
  /// sotto i sei byte non c'è nemmeno una trama vuota.
  static const overhead = 6;

  /// Peso corrente, mentre si sale e ci si assesta.
  static const opcodeLive = 0x21;

  /// Peso stabile: la pesata è finita.
  static const opcodeStable = 0x24;

  /// Avanzamenti di stato, di significato ancora ignoto.
  static const opcodeStatus = 0x20;

  /// **La composizione**: peso e nove impedenze segmentali.
  static const opcodeBody = 0x25;

  /// Risposta al profilo e all'orologio: seq + esito.
  static const opcodeProfileAck = 0x22;
  static const opcodeClockAck = 0x23;

  /// Comando: l'ora corrente, in secondi Unix.
  static const opcodeSetClock = 0xB3;

  /// Comando: chi sta salendo — altezza, peso, sesso ed età.
  static const opcodeSetProfile = 0xB2;

  /// Comando: **mandami la misura che hai in sospeso**.
  ///
  /// Il pezzo che mancava. La bilancia tiene in memoria le pesate fatte
  /// quando nessuno era collegato, e il loro numero viaggia nel battito;
  /// finché quella coda non si svuota **non ne fa altre**. Tre sessioni di
  /// fila si erano chiuse col solo peso per questo, col contatore fermo a 1.
  ///
  /// **Chiede, non butta.** La prima lettura del registro era stata «le
  /// scarto», ed era sbagliata: appena mandato questo comando la bilancia ha
  /// risposto con una [opcodeStoredBody], cioè con la pesata intera. È così
  /// che si recuperano le pesate fatte senza il telefono vicino.
  static const opcodeFetchStored = 0xB6;

  /// **Una pesata presa dalla memoria**, in risposta a [opcodeFetchStored].
  ///
  /// Stessa struttura della [opcodeBody] con quattro byte in più davanti al
  /// peso: quanto tempo fa è stata fatta. Nell'unica osservazione valeva 15,
  /// e i quindici secondi combaciano con la finestra fra i due battiti in cui
  /// la scansione è finita — quindi **secondi**, con un campione solo.
  static const opcodeStoredBody = 0x26;

  /// Oltre questo, l'età dichiarata non si usa: un valore assurdo daterebbe
  /// la pesata in un altro anno, e con una sola osservazione dell'unità è il
  /// tipo di errore che va fermato prima del database.
  static const maxStoredAge = Duration(days: 7);

  /// Il secondo byte dell'intestazione di frammentazione, costante in tutte
  /// le trame spezzate osservate.
  static const fragmentTag = 0x04;

  /// L'impedenza viaggia in decimi di ohm: `0x0be3` = 3043 = 304,3 Ω.
  static const impedanceDivisor = 10.0;

  /// Quante impedenze porta la `0x25`. Nove, e a cosa corrisponda ognuna non
  /// si sa ancora — vedi [RenphoBodyFrame.wholeBodyOhm].
  static const impedanceCount = 9;

  /// L'altezza viaggia in decimi di centimetro: `0x071c` = 1820 = 182,0 cm.
  static const heightDivisor = 10.0;

  /// Il bit alto del byte sesso-età. Acceso nelle catture di Marco, che è
  /// uomo: che sia proprio «maschio» è l'ipotesi più semplice, e finché non
  /// c'è una cattura di una donna resta un'ipotesi.
  static const maleFlag = 0x80;

  /// Il peso arriva in centesimi di chilogrammo: `0x25b2` = 9650 = 96,50 kg.
  static const weightDivisor = 100.0;

  /// Fuori da questa forbice non è un corpo umano, ed è la difesa contro una
  /// decodifica che sembra funzionare e invece ha sbagliato allineamento.
  static const minWeightKg = 10.0;
  static const maxWeightKg = 300.0;

  /// Sotto questo peso il profilo NON si manda.
  ///
  /// Mandarlo troppo presto è un errore che è costato una pesata: il profilo
  /// partiva alla prima trama di peso utile, che è quella di quando si sta
  /// ancora salendo, e dichiarava alla bilancia un uomo di 182 cm da 31 kg.
  /// L'app Renpho manda sempre un peso plausibile, e la bilancia non ha
  /// prodotto nessuna composizione per quella assurdità.
  static const minProfileWeightKg = 40.0;
}

/// Una trama letta, qualunque essa sia.
@immutable
sealed class RenphoFrame {
  const RenphoFrame({required this.hex, required this.checksumOk});

  final String hex;

  /// Falsa quando la somma non torna. Non si butta via la trama per questo:
  /// si segnala e si va avanti, perché perdere l'unica pesata della giornata
  /// per un bit storto sarebbe peggio del male che il controllo previene.
  final bool checksumOk;
}

/// Un peso, corrente o definitivo.
@immutable
class RenphoWeightFrame extends RenphoFrame {
  const RenphoWeightFrame({
    required super.hex,
    required super.checksumOk,
    required this.weightKg,
    required this.stable,
  });

  final double weightKg;

  /// Vero per `0x24`: la bilancia dichiara che il peso si è assestato.
  final bool stable;

  /// Vero quando non c'è nessuno sopra.
  bool get isEmpty => weightKg <= 0;

  @override
  String toString() => isEmpty
      ? 'bilancia libera'
      : '${stable ? 'peso stabile' : 'peso'} '
            '${weightKg.toStringAsFixed(2)} kg';
}

/// Un avanzamento di stato: se ne conosce la forma, non il significato.
@immutable
class RenphoStatusFrame extends RenphoFrame {
  const RenphoStatusFrame({
    required super.hex,
    required super.checksumOk,
    required this.payload,
  });

  final List<int> payload;

  /// Il contatore che cresce a ogni trama, dentro una stessa sessione.
  int? get sequence => payload.isEmpty ? null : payload[0];

  /// Il byte che in **due sessioni diverse** ha percorso la stessa identica
  /// sequenza `01 09 11 05`, con gli stessi intervalli. Non è quindi un
  /// avanzamento della misura: è un battito periodico della bilancia.
  int? get state => payload.length > 1 ? payload[1] : null;

  /// Il byte che è passato da 0 a 1 dopo la prima pesata e da 2 a 3 dopo la
  /// seconda. **Sembra** il numero di pesate che la bilancia tiene in
  /// memoria — sembra, e finché è solo un'ipotesi si scrive così.
  int? get counter => payload.length > 3 ? payload[3] : null;

  @override
  String toString() =>
      'battito della bilancia (passo $sequence, stato '
      '0x${(state ?? 0).toRadixString(16).padLeft(2, '0')}, '
      'contatore $counter)';
}

/// La composizione corporea: il peso e le nove impedenze.
@immutable
class RenphoBodyFrame extends RenphoFrame {
  const RenphoBodyFrame({
    required super.hex,
    required super.checksumOk,
    required this.weightKg,
    required this.impedancesOhm,
    this.bodyFatPct,
    this.bmi,
    this.skeletalMusclePct,
    this.visceralFat,
    this.age,
  });

  /// Da quanto tempo è stata fatta, per le pesate prese dalla memoria.
  ///
  /// Nulla per quelle in diretta, che sono di adesso. Serve a datarle giuste:
  /// una pesata recuperata è comunque una pesata di stamattina, e metterla
  /// nell'ora in cui l'app si è collegata la sposterebbe nel giorno sbagliato
  /// ogni volta che ci si collega dopo mezzanotte.
  final Duration? age;

  final double weightKg;

  /// Tutte e nove, grezze e nell'ordine in cui arrivano.
  ///
  /// Si conservano intere perché **non si sa ancora quale segmento sia
  /// quale**. Sceglierne tre e buttare le altre sei significherebbe non poter
  /// più correggere l'ipotesi: così invece il giorno in cui si scoprisse che
  /// il braccio è un'altra, lo storico si ricalcola senza rifare una pesata.
  final List<double> impedancesOhm;

  /// Quello che la bilancia calcola per il proprio display. **Non entra nella
  /// composizione**, che resta calcolata da noi dall'impedenza con una formula
  /// versionata: serve da riscontro, ed è così che si è capito che la
  /// decodifica era giusta — questi numeri combaciano con quelli del CSV
  /// esportato dall'app Renpho.
  final double? bodyFatPct;
  final double? bmi;
  final double? skeletalMusclePct;
  final int? visceralFat;

  /// L'impedenza di corpo intero, per il percorso mano-piede.
  ///
  /// **È un'ipotesi, dichiarata.** Delle nove, una sola è inequivocabile: la
  /// più bassa di tutte è il tronco — un busto sta sui dieci-venti ohm mentre
  /// un arto sta sulle centinaia, e nelle catture vale 12,9 e 14,2 contro
  /// valori sopra 200. Sommando la più alta (un braccio), il tronco e la più
  /// bassa fra le restanti (una gamba) escono 571 Ω e 552 Ω nelle due
  /// misure — l'ordine di grandezza esatto di un'impedenza mano-piede.
  ///
  /// Non è una certezza e non va spacciata per tale. È però ricalcolabile:
  /// le nove restano salvate, e la formula BIA è versionata apposta.
  double? get wholeBodyOhm {
    if (impedancesOhm.length < 3) {
      return null;
    }
    final ordinate = impedancesOhm.toList()..sort();
    final tronco = ordinate.first;
    final resto = ordinate.sublist(1);
    final braccio = resto.last;
    final gamba = resto.first;
    return braccio + tronco + gamba;
  }

  @override
  String toString() {
    final z = wholeBodyOhm;
    return 'composizione: ${weightKg.toStringAsFixed(2)} kg, '
        '${impedancesOhm.length} impedenze'
        '${z == null ? '' : ', mano-piede ${z.toStringAsFixed(1)} Ω'}'
        '${bodyFatPct == null ? '' : ', la bilancia dice '
                  '${bodyFatPct!.toStringAsFixed(1)}% di grasso'}';
  }
}

/// La bilancia conferma un comando: `0x22` per il profilo, `0x23` per
/// l'orologio. Il primo byte è la sequenza che avevamo mandato noi, ed è così
/// che si sa a quale comando risponde.
@immutable
class RenphoAckFrame extends RenphoFrame {
  const RenphoAckFrame({
    required super.hex,
    required super.checksumOk,
    required this.forClock,
    required this.sequence,
    required this.ok,
  });

  final bool forClock;
  final int sequence;
  final bool ok;

  @override
  String toString() =>
      '${forClock ? 'orologio' : 'profilo'} '
      '${ok ? 'accettato' : 'RIFIUTATO'} (comando $sequence)';
}

/// Una trama con un opcode mai visto. **Va mostrata per intero**: è la sola
/// pista verso l'impedenza, che nella cattura non è ancora comparsa.
@immutable
class RenphoUnknownFrame extends RenphoFrame {
  const RenphoUnknownFrame({
    required super.hex,
    required super.checksumOk,
    required this.opcode,
    required this.payload,
  });

  final int opcode;
  final List<int> payload;

  @override
  String toString() =>
      'opcode 0x${opcode.toRadixString(16).padLeft(2, '0')} sconosciuto, '
      '${payload.length} byte — questa è nuova';
}

/// Decodifica una trama. Torna `null` quando non è nemmeno una trama di questo
/// protocollo (intestazione sbagliata o lunghezza incoerente).
RenphoFrame? decodeRenphoFrame(List<int> bytes) {
  if (bytes.length < RenphoMsc.overhead) {
    return null;
  }
  if (bytes[0] != RenphoMsc.header0 || bytes[1] != RenphoMsc.header1) {
    return null;
  }
  final opcode = bytes[2];
  final length = (bytes[3] << 8) | bytes[4];
  if (length < 0 || 5 + length + 1 > bytes.length) {
    return null;
  }
  final payload = bytes.sublist(5, 5 + length);
  final hex = renphoHex(bytes);
  // La somma di tutti i byte che precedono, modulo 256. Verificata a mano su
  // tre trame di opcode diversi: se un giorno smettesse di tornare, il primo
  // sospetto è che il protocollo sia cambiato, non che il controllo sia
  // sbagliato.
  var somma = 0;
  for (var i = 0; i < 5 + length; i++) {
    somma = (somma + bytes[i]) & 0xFF;
  }
  final checksumOk = somma == bytes[5 + length];

  switch (opcode) {
    case RenphoMsc.opcodeLive:
    case RenphoMsc.opcodeStable:
      final weight = _weightFrom(payload);
      if (weight == null) {
        // Zero è la bilancia accesa con nessuno sopra, non una trama che non
        // si capisce: chiamarla «opcode sconosciuto» riempiva il registro di
        // allarmi per la cosa più normale che una bilancia possa dire.
        if (_isZeroWeight(payload)) {
          return RenphoWeightFrame(
            hex: hex,
            checksumOk: checksumOk,
            weightKg: 0,
            stable: false,
          );
        }
        return RenphoUnknownFrame(
          hex: hex,
          checksumOk: checksumOk,
          opcode: opcode,
          payload: payload,
        );
      }
      return RenphoWeightFrame(
        hex: hex,
        checksumOk: checksumOk,
        weightKg: weight,
        stable: opcode == RenphoMsc.opcodeStable,
      );
    case RenphoMsc.opcodeBody:
    case RenphoMsc.opcodeStoredBody:
      final body = _decodeBody(
        payload,
        hex,
        checksumOk,
        stored: opcode == RenphoMsc.opcodeStoredBody,
      );
      if (body != null) {
        return body;
      }
      return RenphoUnknownFrame(
        hex: hex,
        checksumOk: checksumOk,
        opcode: opcode,
        payload: payload,
      );
    case RenphoMsc.opcodeProfileAck:
    case RenphoMsc.opcodeClockAck:
      // Il profilo risponde con `seq esito`, l'orologio con `seq 07 esito`.
      return RenphoAckFrame(
        hex: hex,
        checksumOk: checksumOk,
        forClock: opcode == RenphoMsc.opcodeClockAck,
        sequence: payload.isEmpty ? -1 : payload.first,
        ok: payload.isNotEmpty && payload.last == 0x01,
      );
    case RenphoMsc.opcodeStatus:
      return RenphoStatusFrame(
        hex: hex,
        checksumOk: checksumOk,
        payload: payload,
      );
    default:
      return RenphoUnknownFrame(
        hex: hex,
        checksumOk: checksumOk,
        opcode: opcode,
        payload: payload,
      );
  }
}

/// `0x25` — la composizione.
///
/// Struttura ricavata da due misure complete a confronto: due byte di testa,
/// il peso a 32 bit **big endian** come nelle altre trame, poi un campo che
/// vale 10 in entrambe, poi nove impedenze a 16 bit **little endian**, e in
/// coda quattro valori a 16 bit big endian che la bilancia si calcola da sé.
///
/// Sì, le impedenze sono little endian e il peso big endian nella stessa
/// trama. Non è un errore di lettura: è quello che fa il firmware, e provare a
/// «uniformare» produrrebbe numeri assurdi — 0x0be3 letto al contrario è
/// 58123, cioè cinquemila ohm.
RenphoBodyFrame? _decodeBody(
  List<int> payload,
  String hex,
  bool checksumOk, {
  bool stored = false,
}) {
  // La trama presa dalla memoria è identica salvo quattro byte infilati fra
  // l'intestazione e il peso: tutto il resto scorre di conseguenza, e leggerla
  // con gli offset dell'altra darebbe numeri plausibili e sbagliati.
  final scarto = stored ? 4 : 0;
  final inizioImpedenze = 8 + scarto;
  final inizioDerivati = 28 + scarto;
  if (payload.length < inizioDerivati) {
    return null;
  }
  final weight = _weightFrom(payload.sublist(0, 6 + scarto));
  if (weight == null) {
    return null;
  }
  Duration? eta;
  if (stored) {
    final secondi =
        (payload[2] << 24) |
        (payload[3] << 16) |
        (payload[4] << 8) |
        payload[5];
    final candidata = Duration(seconds: secondi);
    eta = candidata <= RenphoMsc.maxStoredAge ? candidata : null;
  }

  final impedenze = <double>[];
  for (
    var i = inizioImpedenze;
    i + 1 < inizioDerivati && impedenze.length < RenphoMsc.impedanceCount;
    i += 2
  ) {
    final grezzo = payload[i] | (payload[i + 1] << 8);
    impedenze.add(grezzo / RenphoMsc.impedanceDivisor);
  }

  double? derivato(int offset, double scala) {
    offset += scarto;
    if (offset + 1 >= payload.length) {
      return null;
    }
    return ((payload[offset] << 8) | payload[offset + 1]) / scala;
  }

  return RenphoBodyFrame(
    hex: hex,
    checksumOk: checksumOk,
    weightKg: weight,
    impedancesOhm: List<double>.unmodifiable(impedenze),
    bodyFatPct: derivato(28, 10),
    bmi: derivato(30, 10),
    skeletalMusclePct: derivato(32, 10),
    visceralFat: derivato(34, 1)?.round(),
    age: eta,
  );
}

/// Il peso sta negli **ultimi quattro byte** del payload, non a un offset
/// fisso.
///
/// È una scelta deliberata. Il `0x21` porta cinque byte (`01` + peso) e il
/// `0x24` ne porta sei (`01 11` + peso): contando dalla fine si leggono
/// entrambi con la stessa riga, e soprattutto un byte in più aggiunto in testa
/// da un firmware futuro non sposterebbe il peso. Contando dall'inizio sì, e
/// il risultato non sarebbe un errore ma un numero plausibile e sbagliato.
double? _weightFrom(List<int> payload) {
  if (payload.length < 4) {
    return null;
  }
  final start = payload.length - 4;
  final raw =
      (payload[start] << 24) |
      (payload[start + 1] << 16) |
      (payload[start + 2] << 8) |
      payload[start + 3];
  final kg = raw / RenphoMsc.weightDivisor;
  if (kg < RenphoMsc.minWeightKg || kg > RenphoMsc.maxWeightKg) {
    return null;
  }
  return kg;
}

/// Costruisce una trama da mandare alla bilancia.
List<int> _comando(int opcode, List<int> payload) {
  final frame = <int>[
    RenphoMsc.header0,
    RenphoMsc.header1,
    opcode,
    (payload.length >> 8) & 0xFF,
    payload.length & 0xFF,
    ...payload,
  ];
  frame.add(frame.fold<int>(0, (a, b) => a + b) & 0xFF);
  return frame;
}

/// `0xB3` — l'ora corrente.
///
/// È il primo dei due comandi che l'app Renpho manda e noi non mandavamo. Il
/// timestamp è in secondi Unix, big endian: nelle catture valeva `07:02:47` e
/// `08:22:31` UTC, cioè esattamente l'ora delle due prove.
///
/// [sequence] è un contatore di transazione: la bilancia lo rimanda indietro
/// nella risposta, ed è così che si sa a quale comando appartiene.
List<int> renphoClockCommand({required DateTime now, required int sequence}) {
  final secondi = now.toUtc().millisecondsSinceEpoch ~/ 1000;
  return _comando(RenphoMsc.opcodeSetClock, [
    sequence & 0xFF,
    // I byte fissi delle catture. Non se ne conosce il significato, e per
    // questo si rimandano identici invece di inventarne di «più sensati»:
    // è il pezzo di protocollo che si sta copiando, non progettando.
    0x07, 0x01, 0x01,
    (secondi >> 24) & 0xFF,
    (secondi >> 16) & 0xFF,
    (secondi >> 8) & 0xFF,
    secondi & 0xFF,
    0x00, 0x78, 0x00,
  ]);
}

/// `0xB2` — **chi sta salendo sulla bilancia**.
///
/// Il comando che sbloccava tutto. Senza, la bilancia pesa e tace: non ha
/// altezza, sesso ed età, quindi non ha niente da calcolare e nessuno a cui
/// rispondere. Con, arriva la `0x25` con le nove impedenze.
///
/// [weightKg] è il peso che la bilancia ha appena misurato, non un peso
/// storico: l'app Renpho manda quello corrente e lo rimanda aggiornato quando
/// la pesata si assesta.
List<int> renphoProfileCommand({
  required int sequence,
  required double heightCm,
  required double weightKg,
  required int age,
  required bool male,
}) {
  final altezza = (heightCm * RenphoMsc.heightDivisor).round();
  final peso = (weightKg * RenphoMsc.weightDivisor).round();
  return _comando(RenphoMsc.opcodeSetProfile, [
    sequence & 0xFF,
    0x01,
    (altezza >> 8) & 0xFF,
    altezza & 0xFF,
    (peso >> 8) & 0xFF,
    peso & 0xFF,
    // Sesso ed età in un byte solo: `0xa6` nelle catture, cioè bit alto acceso
    // e 0x26 = 38, che sono gli anni di Marco.
    (male ? RenphoMsc.maleFlag : 0x00) | (age & 0x7F),
    0x03, 0x02,
  ]);
}

/// `0xB6` — chiedi la pesata che la bilancia tiene in memoria.
///
/// I due byte di payload sono copiati **identici** dalla cattura. Cosa
/// significhino non si sa: potrebbero essere un sottocomando e un conteggio,
/// oppure due costanti. Con una sola osservazione — contatore a 1 — non c'è
/// modo di distinguere, e inventare una regola su un campione solo è il modo
/// migliore per scoprire fra un mese che era sbagliata. Si copia quello che
/// funziona, e si scrive che è una copia.
///
/// **Non butta niente.** La prima lettura era stata «svuota la coda», ed era
/// sbagliata: la bilancia risponde mandando la pesata intera. È il modo in cui
/// si recuperano le pesate fatte quando il telefono non era vicino — e la
/// ragione per cui vale la pena mandarlo sempre, non solo per sbloccarla.
List<int> renphoFetchStoredCommand() =>
    _comando(RenphoMsc.opcodeFetchStored, const [0x01, 0x01]);

/// Rimonta le trame spezzate.
///
/// Sopra i venti byte la bilancia frammenta con tre byte di testa —
/// `sequenza | 04 | quanti ne mancano` — e il contatore scende a zero
/// sull'ultimo pezzo. Chi cerca `55 aa` in testa vede solo il primo frammento
/// e butta gli altri due: è esattamente il motivo per cui la composizione era
/// sembrata non arrivare mai.
class RenphoReassembler {
  final _buffer = <int>[];

  /// Torna la trama completa quando ce n'è una, altrimenti `null`.
  List<int>? accept(List<int> chunk) {
    if (chunk.isEmpty) {
      return null;
    }
    if (chunk.length > 1 &&
        chunk[0] == RenphoMsc.header0 &&
        chunk[1] == RenphoMsc.header1) {
      // Una trama intera azzera qualunque rimontaggio a metà: se ne era
      // rimasto uno appeso, era comunque perso.
      _buffer.clear();
      return chunk;
    }
    if (chunk.length < 4 || chunk[1] != RenphoMsc.fragmentTag) {
      return null;
    }
    _buffer.addAll(chunk.sublist(3));
    if (chunk[2] != 0) {
      return null;
    }
    final completa = List<int>.unmodifiable(_buffer);
    _buffer.clear();
    return completa;
  }

  void reset() => _buffer.clear();
}

/// Vero quando gli ultimi quattro byte del payload sono tutti zero.
bool _isZeroWeight(List<int> payload) {
  if (payload.length < 4) {
    return false;
  }
  return payload.sublist(payload.length - 4).every((b) => b == 0);
}

/// La trama in esadecimale, per il registro.
String renphoHex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
