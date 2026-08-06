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
/// **Cosa NON si sa ancora.** L'impedenza. Nella cattura non è mai arrivata:
/// o la bilancia la manda più tardi di quanto si fosse rimasti in ascolto, o
/// aspetta un comando su `2a11` — l'unica caratteristica che non ha detto
/// niente, e quindi quasi certamente quella su cui si scrive. Per questo ogni
/// trama che non si riconosce continua a finire nel registro per intero: è
/// così che si è arrivati fin qui.
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

  /// Il peso arriva in centesimi di chilogrammo: `0x25b2` = 9650 = 96,50 kg.
  static const weightDivisor = 100.0;

  /// Fuori da questa forbice non è un corpo umano, ed è la difesa contro una
  /// decodifica che sembra funzionare e invece ha sbagliato allineamento.
  static const minWeightKg = 10.0;
  static const maxWeightKg = 300.0;
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

  @override
  String toString() =>
      '${stable ? 'peso stabile' : 'peso'} '
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

  @override
  String toString() =>
      'avanzamento della bilancia (${payload.length} byte, '
      'significato ancora da capire)';
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

/// La trama in esadecimale, per il registro.
String renphoHex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
