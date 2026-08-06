import 'package:flutter/foundation.dart';

/// Lo stato della radio, ridotto a quello che cambia la risposta da dare a
/// Marco. Le sfumature del sistema operativo (accensione in corso, stato
/// sconosciuto) non arrivano fin qui: o si può cercare, o c'è una cosa
/// precisa da fare prima.
enum ScaleRadioState {
  /// Si può cercare.
  on,

  /// Radio spenta: c'è un interruttore da toccare.
  off,

  /// Permesso negato dall'utente o mai chiesto.
  unauthorized,

  /// Niente Bluetooth Low Energy su questo dispositivo. Non si risolve
  /// riprovando.
  unsupported,
}

/// Una bilancia vista durante la scansione.
@immutable
class ScaleDevice {
  const ScaleDevice({
    required this.id,
    required this.name,
    this.serviceUuids = const <String>[],
  });

  /// L'indirizzo con cui il sistema la richiama. Su Android è il MAC, su iOS
  /// un identificatore locale: non è un dato da mostrare, serve a riconnettersi.
  final String id;

  /// Come si è annunciata. **Spesso è vuoto**: in un annuncio BLE ci stanno
  /// 31 byte, e chi ha qualcosa di meglio da metterci il nome lo omette.
  final String name;

  /// I servizi dichiarati nell'annuncio, in minuscolo.
  ///
  /// Sono l'altra metà del riconoscimento, e per molte bilance l'unica: una
  /// che si presenta col solo indirizzo è invisibile a un controllo che
  /// guardi il nome, ma dice comunque di parlare `ffe0`. Buttarli via
  /// significava non poterla riconoscere mai.
  final List<String> serviceUuids;

  @override
  String toString() => name.isEmpty ? id : '$name ($id)';
}

/// Perché un'operazione Bluetooth non è riuscita, in categorie che
/// corrispondono a **cosa può fare Marco**, non a codici di errore.
enum ScaleLinkFailure {
  permissionDenied,
  radioOff,
  unsupported,

  /// Collegamento caduto, caratteristiche mancanti, scrittura rifiutata.
  connection,

  unknown,
}

class ScaleLinkException implements Exception {
  ScaleLinkException(this.failure, this.message);

  final ScaleLinkFailure failure;

  /// Il testo tecnico originale. Si mostra: è quello che permette di capire
  /// cosa è andato storto quando la bilancia sarà davvero sotto i piedi.
  final String message;

  @override
  String toString() => 'ScaleLinkException(${failure.name}): $message';
}

/// Un collegamento aperto con la bilancia.
abstract class ScaleConnection {
  /// Le trame che arrivano, così come arrivano.
  Stream<List<int>> get incoming;

  /// Manda una trama. Dove scriverla lo decide l'implementazione: il
  /// protocollo QN ha due caratteristiche di scrittura e la scelta dipende
  /// dall'opcode, che è un dettaglio del trasporto e non del dominio.
  Future<void> send(List<int> bytes);

  Future<void> close();
}

/// La porta verso il Bluetooth.
///
/// Esiste perché `flutter_blue_plus` non entra in un test: parla con un
/// canale di piattaforma che in un test Flutter non c'è, e soprattutto
/// **nessun test può salire su una bilancia**. Tutto ciò che sta sopra questa
/// interfaccia — riconoscimento del dispositivo, dialogo, decodifica,
/// formula, stati leggibili — è Dart puro e si prova con un dispositivo
/// finto. Sotto resta un adattatore sottile, che si collauda solo sul campo.
abstract class ScaleLink {
  Future<ScaleRadioState> radioState();

  /// I dispositivi che si annunciano, uno per volta. Lo stream finisce da solo
  /// allo scadere di [timeout].
  ///
  /// Torna **tutto** quello che vede, non solo le bilance: la scelta la fa
  /// chi chiama, così il registro diagnostico può elencare anche i vicini
  /// scartati — che è esattamente il dato che serve quando la bilancia «non
  /// si trova».
  Stream<ScaleDevice> scan({required Duration timeout});

  Future<ScaleConnection> connect(ScaleDevice device);
}
