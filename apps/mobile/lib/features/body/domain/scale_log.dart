import 'package:flutter/foundation.dart';

/// Una riga del registro della sessione.
@immutable
class ScaleLogEntry {
  const ScaleLogEntry({
    required this.at,
    required this.message,
    this.hex,
    this.isProblem = false,
  });

  /// Istante in UTC. La schermata lo mostra come ora di Roma, ma qui resta
  /// assoluto: un registro con dentro due fusi diversi non si legge.
  final DateTime at;

  /// In italiano e in chiaro: «trovata QN-Scale», «peso 95,80 kg stabile».
  final String message;

  /// I byte della trama, quando ce n'è una. Sono la prova: se un giorno la
  /// decodifica sbaglia, questa riga permette di rifarla a mano.
  final String? hex;

  final bool isProblem;

  @override
  String toString() {
    final time =
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    return hex == null ? '$time  $message' : '$time  $message  [$hex]';
  }
}

/// Il diario di bordo di una sessione con la bilancia.
///
/// Esiste per una ragione sola e concreta: **questa funzione non si può
/// provare su una bilancia vera prima di consegnarla**. Il primo tentativo
/// reale di Marco sarà anche il primo collaudo, e quando qualcosa non
/// funzionerà l'unica cosa che resterà sarà questo elenco. Per questo le trame
/// si annotano in esadecimale anche quando sono state capite, e per questo il
/// registro è copiabile.
///
/// È limitato: una sessione lunga con una bilancia che manda trame dieci volte
/// al secondo riempirebbe la memoria e renderebbe illeggibile la schermata.
/// Si tengono le ultime [capacity] righe.
class ScaleLog {
  ScaleLog({this.capacity = 120});

  final int capacity;
  final _entries = <ScaleLogEntry>[];

  List<ScaleLogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  void add(DateTime at, String message, {String? hex, bool isProblem = false}) {
    _entries.add(
      ScaleLogEntry(
        at: at.toUtc(),
        message: message,
        hex: hex,
        isProblem: isProblem,
      ),
    );
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  void clear() => _entries.clear();

  /// Il registro in una stringa sola, da incollare in un messaggio quando la
  /// bilancia farà i capricci lontano dal computer.
  String asText() => _entries.map((entry) => entry.toString()).join('\n');
}
