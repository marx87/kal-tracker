import 'dart:async';

import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';

/// **La bilancia finta.**
///
/// Nessun test può salire su una bilancia, e nessun test può accendere un
/// Bluetooth. Questo file è la risposta: una QN-Scale di carta che parla lo
/// stesso protocollo di quella vera, e che sa anche comportarsi male —
/// radio spenta, permesso negato, elettrodi che non fanno contatto,
/// collegamento che cade a metà pesata.
///
/// Le trame le costruiscono le funzioni in fondo al file, byte per byte,
/// dalla stessa specifica che legge il decodificatore. Se un giorno la
/// specifica si scoprirà sbagliata, questi due pezzi vanno cambiati insieme —
/// ed è giusto così: un finto che si adatta alla decodifica invece che al
/// protocollo non proverebbe niente.
class FakeScaleLink implements ScaleLink {
  FakeScaleLink({
    this.radio = ScaleRadioState.on,
    List<ScaleDevice>? devices,
    this.radioException,
    this.connectException,
    this.autoFrames = const <List<int>>[],
    this.frameDelay = const Duration(milliseconds: 10),
    this.keepScanning = false,
    this.connectDelay = Duration.zero,
  }) : devices =
           devices ??
           const [ScaleDevice(id: 'aa:bb:cc', name: QnScale.advertisedName)];

  ScaleRadioState radio;

  /// Quello che si annuncia, nell'ordine in cui si annuncia. L'ordine conta:
  /// chi arriva prima ha la prima possibilità di essere riconosciuto, ed è
  /// così che si prova che una scelta esplicita di Marco batte un dispositivo
  /// che *sembra* una bilancia e si è fatto vedere per primo.
  final List<ScaleDevice> devices;

  /// Se vero la scansione **non si chiude** dopo aver annunciato i
  /// dispositivi, come quella vera che dura mezzo minuto.
  ///
  /// Serve a riprodurre l'unico istante che conta: Marco è già in piedi sulla
  /// bilancia, la ricerca è ancora in corso, e la riga giusta compare adesso.
  /// Con una scansione che si spegne appena finiti i dispositivi quell'istante
  /// non esisterebbe, e la scelta a mano si potrebbe provare solo a ricerca
  /// finita — cioè nel caso meno interessante dei due.
  final bool keepScanning;

  /// Quanto ci mette il collegamento ad aprirsi.
  ///
  /// Serve a riprodurre l'istante in cui la schermata si chiude **mentre** il
  /// Bluetooth sta agganciando: una richiesta di collegamento non si può
  /// richiamare indietro, quindi è l'unico modo di provare che la sessione
  /// interrotta chiude subito quello che ha aperto invece di lasciare la
  /// bilancia occupata per tre quarti di minuto.
  final Duration connectDelay;

  /// Annuncia un dispositivo a scansione già in corso.
  ///
  /// È la bilancia che compare quando Marco ci sale sopra, mezzo minuto dopo
  /// l'inizio della ricerca — l'unico momento in cui la Renpho esiste per la
  /// radio. Richiede [keepScanning].
  void announce(ScaleDevice device) {
    final controller = _scanController;
    if (controller != null && !controller.isClosed) {
      controller.add(device);
    }
  }

  /// Trame mandate da sola appena qualcuno si collega, una ogni [frameDelay].
  ///
  /// Serve ai test di interfaccia: lì il dialogo non si può guidare a mano
  /// perché il tempo è finto e avanza solo con i fotogrammi, quindi la
  /// bilancia deve recitare la sua parte da sé.
  final List<List<int>> autoFrames;
  final Duration frameDelay;

  /// Se valorizzata, `radioState` la lancia invece di rispondere.
  ScaleLinkException? radioException;

  /// Se valorizzata, `connect` la lancia.
  ScaleLinkException? connectException;

  /// Se valorizzata, la scansione la mette nello stream invece dei
  /// dispositivi. È il caso vero di Android 12: la radio si dichiara accesa e
  /// il permesso salta fuori solo quando si prova a cercare.
  ScaleLinkException? scanException;

  bool scanStopped = false;
  final connections = <FakeScaleConnection>[];

  final _opened = Completer<FakeScaleConnection>();

  /// Si completa quando qualcuno si collega: è il momento in cui il test può
  /// cominciare a mandare trame.
  Future<FakeScaleConnection> get opened => _opened.future;

  final _announced = Completer<void>();

  /// Si completa quando tutti i dispositivi sono stati annunciati.
  ///
  /// È il segnale che dice al test «adesso l'elenco è pieno»: senza,
  /// scegliere a scansione aperta vorrebbe dire aspettare un numero di
  /// millisecondi scelto a caso e sperare.
  Future<void> get announced => _announced.future;

  StreamController<ScaleDevice>? _scanController;

  /// Fa scadere la scansione tenuta aperta da [keepScanning].
  Future<void> endScan() async {
    final controller = _scanController;
    // A scansione già disdetta chiudere non serve e non si può: chi cercava ha
    // trovato e se n'è andato per i fatti suoi.
    if (controller == null || controller.isClosed || scanStopped) {
      return;
    }
    await controller.close();
  }

  @override
  Future<ScaleRadioState> radioState() async {
    final failure = radioException;
    if (failure != null) {
      throw failure;
    }
    return radio;
  }

  @override
  Stream<ScaleDevice> scan({required Duration timeout}) {
    final controller = StreamController<ScaleDevice>();
    _scanController = controller;
    controller.onListen = () async {
      final failure = scanException;
      if (failure != null) {
        controller.addError(failure);
        await controller.close();
        return;
      }
      for (final device in devices) {
        if (controller.isClosed) {
          return;
        }
        controller.add(device);
        await Future<void>.delayed(Duration.zero);
      }
      if (!_announced.isCompleted) {
        _announced.complete();
      }
      if (keepScanning || controller.isClosed) {
        return;
      }
      await controller.close();
    };
    controller.onCancel = () => scanStopped = true;
    return controller.stream;
  }

  @override
  Future<ScaleConnection> connect(ScaleDevice device) async {
    final failure = connectException;
    if (failure != null) {
      throw failure;
    }
    if (connectDelay > Duration.zero) {
      await Future<void>.delayed(connectDelay);
    }
    final connection = FakeScaleConnection();
    connections.add(connection);
    if (!_opened.isCompleted) {
      _opened.complete(connection);
    }
    if (autoFrames.isNotEmpty) {
      unawaited(_play(connection));
    }
    return connection;
  }

  Future<void> _play(FakeScaleConnection connection) async {
    for (final frame in autoFrames) {
      await Future<void>.delayed(frameDelay);
      if (connection.closed) {
        return;
      }
      connection.emitRaw(frame);
    }
  }
}

class FakeScaleConnection implements ScaleConnection {
  final _incoming = StreamController<List<int>>();

  /// Le trame che l'app ha mandato alla bilancia, in ordine.
  final sent = <List<int>>[];

  bool closed = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> send(List<int> bytes) async => sent.add(List<int>.of(bytes));

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }

  /// Manda una trama, senza aspettare.
  void emitRaw(List<int> frame) {
    if (!_incoming.isClosed) {
      _incoming.add(frame);
    }
  }

  /// Manda una trama e lascia girare la coda degli eventi, così il test può
  /// scrivere il dialogo riga per riga invece di aspettare a caso.
  Future<void> emit(List<int> frame) async {
    emitRaw(frame);
    await _settle();
  }

  /// La bilancia che si spegne, o esce dal raggio, in mezzo a una pesata.
  Future<void> dropConnection() async {
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
    await _settle();
  }

  Future<void> failWith(Object error) async {
    _incoming.addError(error);
    await _settle();
  }

  static Future<void> _settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

// ---------------------------------------------------------------------
// Le trame, byte per byte.
// ---------------------------------------------------------------------

/// `0x12` — la bilancia si presenta. Il byte 10 vale 1 quando il peso viaggia
/// in centesimi di chilo.
List<int> fakeHandshakeFrame({
  int protocolType = QnScale.defaultProtocolType,
  bool hundredths = true,
}) {
  final frame = <int>[
    0x12,
    0x0C,
    protocolType,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    hundredths ? 0x01 : 0x02,
    0x00,
  ];
  frame[frame.length - 1] = qnChecksum(frame.take(frame.length - 1));
  return frame;
}

/// `0x10` nella disposizione originale: peso nei byte 3-4, stabilità nel 5,
/// resistenze nei 6-7 e 8-9.
List<int> fakeWeightFrame({
  required double weightKg,
  required bool stable,
  double resistance1 = 442,
  double resistance2 = 500,
  int protocolType = QnScale.defaultProtocolType,
}) {
  final raw = (weightKg * 100).round();
  final r1 = resistance1.round();
  final r2 = resistance2.round();
  final frame = <int>[
    0x10,
    0x0B,
    protocolType,
    (raw >> 8) & 0xFF,
    raw & 0xFF,
    stable ? 0x01 : 0x00,
    (r1 >> 8) & 0xFF,
    r1 & 0xFF,
    (r2 >> 8) & 0xFF,
    r2 & 0xFF,
    0x00,
  ];
  frame[frame.length - 1] = qnChecksum(frame.take(frame.length - 1));
  return frame;
}

/// `0x10` nella disposizione dei modelli ES-30M: peso nei byte 5-6, con il
/// fattore di scala a 10 e la stabilità nel byte 4.
List<int> fakeAlternateWeightFrame({
  required double weightKg,
  required bool stable,
  double resistance1 = 442,
  double resistance2 = 500,
}) {
  final raw = (weightKg * 10).round();
  final r1 = resistance1.round();
  final r2 = resistance2.round();
  final frame = <int>[
    0x10,
    0x0C,
    QnScale.defaultProtocolType,
    0x00,
    stable ? 0x02 : 0x00,
    (raw >> 8) & 0xFF,
    raw & 0xFF,
    (r1 >> 8) & 0xFF,
    r1 & 0xFF,
    (r2 >> 8) & 0xFF,
    r2 & 0xFF,
    0x00,
  ];
  frame[frame.length - 1] = qnChecksum(frame.take(frame.length - 1));
  return frame;
}
