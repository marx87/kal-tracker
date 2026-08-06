import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/gatt_scale_protocol.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';
import 'package:kal_tracker/features/body/domain/renpho_msc_protocol.dart';

/// L'unico punto dell'app che sa che esiste `flutter_blue_plus`.
///
/// È tenuto apposta sottile e senza decisioni: scansione, collegamento,
/// sottoscrizione, scrittura, e la traduzione degli errori della libreria
/// nelle quattro categorie che cambiano la risposta da dare a Marco. Tutto
/// quello che si può sbagliare ragionando — riconoscere la bilancia, capire
/// le trame, decidere quando una pesata è finita — sta sopra [ScaleLink], in
/// Dart puro e sotto test. Qui sotto resta solo ciò che si collauda salendo
/// su una bilancia vera.
///
/// **Licenza.** `flutter_blue_plus` dalla 2.0 è gratuito per uso personale e
/// non commerciale, e a pagamento per il resto; ogni collegamento va
/// dichiarato con [License.nonprofit]. Coach360 è l'app privata di Marco, non
/// è in vendita e non sta in nessun negozio: rientra nell'uso personale. Se un
/// giorno lo diventasse, questa riga è il posto da cui ripartire.
class FlutterBluePlusScaleLink implements ScaleLink {
  FlutterBluePlusScaleLink();

  /// I dispositivi visti durante la scansione, per non doverli ricostruire
  /// dall'identificatore quando arriva il momento di collegarsi.
  final _seen = <String, BluetoothDevice>{};

  @override
  Future<ScaleRadioState> radioState() async {
    if (!await FlutterBluePlus.isSupported) {
      return ScaleRadioState.unsupported;
    }
    // Il primo valore utile: appena dopo l'avvio lo stato è `unknown` per una
    // frazione di secondo, e rispondere «spento» in quella finestra sarebbe
    // una bugia. Se non si assesta, si prova a cercare lo stesso: l'errore
    // vero della scansione è più informativo di un'ipotesi.
    final state = await FlutterBluePlus.adapterState
        .where((value) => value != BluetoothAdapterState.unknown)
        .first
        .timeout(
          const Duration(seconds: 4),
          onTimeout: () => BluetoothAdapterState.on,
        );
    return switch (state) {
      BluetoothAdapterState.on ||
      BluetoothAdapterState.turningOn => ScaleRadioState.on,
      BluetoothAdapterState.off ||
      BluetoothAdapterState.turningOff => ScaleRadioState.off,
      BluetoothAdapterState.unauthorized => ScaleRadioState.unauthorized,
      BluetoothAdapterState.unavailable => ScaleRadioState.unsupported,
      BluetoothAdapterState.unknown => ScaleRadioState.on,
    };
  }

  @override
  Stream<ScaleDevice> scan({required Duration timeout}) {
    final controller = StreamController<ScaleDevice>();
    StreamSubscription<List<ScanResult>>? results;

    Future<void> stop() async {
      await results?.cancel();
      results = null;
      if (FlutterBluePlus.isScanningNow) {
        try {
          await FlutterBluePlus.stopScan();
        } on Object {
          // Fermare una scansione già ferma non è un problema di nessuno.
        }
      }
    }

    /// I dispositivi che il telefono conosce già, prima ancora di cercare.
    ///
    /// **Questo è il caso che faceva dire «bilancia non trovata» a chi la
    /// bilancia ce l'aveva accesa davanti.** Un dispositivo BLE già accoppiato
    /// — per esempio dall'app del costruttore — smette di annunciarsi: è già
    /// noto al sistema, e nessuna scansione lo troverà mai, per quanto a lungo
    /// si cerchi. Vanno chiesti al sistema, non aspettati.
    Future<void> emitKnown() async {
      final known = <String, BluetoothDevice>{};
      try {
        for (final device in await FlutterBluePlus.bondedDevices) {
          known[device.remoteId.str] = device;
        }
      } on Object {
        // Non c'è su tutte le piattaforme: dove manca, si va di scansione.
      }
      try {
        for (final device in FlutterBluePlus.connectedDevices) {
          known[device.remoteId.str] = device;
        }
      } on Object {
        // Idem.
      }
      for (final device in known.values) {
        _seen[device.remoteId.str] = device;
        controller.add(
          ScaleDevice(
            id: device.remoteId.str,
            name: device.platformName,
            // Un dispositivo accoppiato non ha un annuncio da cui leggere i
            // servizi: si riconosce dal nome, oppure lo si scopre solo
            // connettendosi.
            knownToSystem: true,
          ),
        );
      }
    }

    Future<void> start() async {
      try {
        await emitKnown();
        results = FlutterBluePlus.onScanResults.listen((found) {
          for (final result in found) {
            controller.add(
              ScaleDevice(
                id: result.device.remoteId.str,
                name: _nameOf(result),
                // I servizi annunciati sono l'unico appiglio quando il nome
                // manca, che è il caso di buona parte dei dispositivi in giro.
                serviceUuids: [
                  for (final uuid in result.advertisementData.serviceUuids)
                    uuid.str128.toLowerCase(),
                ],
                // L'altro campo dove cercare, e quello che mancava: le bilance
                // che non dichiarano servizi mettono qui dentro il modello e
                // la misura in corso.
                manufacturerData: Map<int, List<int>>.unmodifiable(
                  result.advertisementData.manufacturerData,
                ),
                rssi: result.rssi,
              ),
            );
            _seen[result.device.remoteId.str] = result.device;
          }
        }, onError: (Object error) => controller.addError(_translate(error)));
        // NESSUN filtro, di proposito, ed è una correzione: prima si chiedeva
        // alla libreria solo chi annunciava gli UUID `ffe0`/`fff0` o il nome
        // esatto «QN-Scale». Sembrava prudente e invece rendeva l'app cieca —
        // una bilancia che si annuncia col nome del modello non arrivava mai,
        // e nemmeno finiva fra i «visti e scartati» del registro, che è
        // proprio la riga che dice come si chiama davvero.
        //
        // Filtrare tocca a chi legge (`ScaleReader`), come dichiara il
        // contratto di `ScaleLink.scan`. Sì, così passa mezzo condominio: sono
        // una manciata di righe in un registro che si guarda solo quando
        // qualcosa non va, ed è un prezzo bassissimo per non essere ciechi.
        await FlutterBluePlus.startScan(timeout: timeout);
        // `startScan` torna subito: la scansione finisce da sé allo scadere
        // del timeout, e questo è il momento in cui lo stream si chiude.
        await FlutterBluePlus.isScanning.where((value) => !value).first;
      } on Object catch (error) {
        if (!controller.isClosed) {
          controller.addError(_translate(error));
        }
      } finally {
        await stop();
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }

    controller.onListen = () => unawaited(start());
    controller.onCancel = stop;
    return controller.stream;
  }

  @override
  Future<ScaleConnection> connect(ScaleDevice device) async {
    final target = _seen[device.id] ?? BluetoothDevice.fromId(device.id);
    try {
      // Quindici secondi e non i trentacinque di libreria: davanti c'è
      // qualcuno in piedi in bagno, e mezzo minuto di rotella senza spiegazioni
      // è peggio di un «non ci riesco» detto subito.
      await target.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      final services = await target.discoverServices();
      // Un protocollo sconosciuto **non è più un vicolo cieco**.
      //
      // La bilancia di Marco è una R-MSC02 e parla `1a10`, un servizio che non
      // sta nello standard e che nessuno ha pubblicato. Prima ci si fermava
      // qui con un «non lo conosco», e ogni ipotesi sul formato delle trame
      // costava un giro di pubblicazione per essere smentita. Ma se non si sa
      // *cosa* dice, si può sempre registrare *quello che dice*: ci si collega
      // lo stesso, si ascolta tutto ciò che è ascoltabile, e i byte finiscono
      // nel registro. Da lì il protocollo si ricava una volta sola.
      final profile = _profileOf(services) ?? _captureProfile(services);
      // L'ascolto si apre PRIMA di accendere le notifiche: la bilancia manda
      // la sua presentazione appena la sottoscrizione è attiva, e sottoscrivere
      // dopo perderebbe proprio la trama che dichiara la scala del peso.
      final connection = _FlutterBluePlusConnection(
        device: target,
        profile: profile,
      );
      // Le caratteristiche standard viaggiano per *indication* e non per
      // notifica; il plugin sceglie da sé quale abilitare guardando le
      // proprietà, quindi qui non c'è niente da distinguere.
      for (final ascoltata in profile.notified) {
        try {
          await ascoltata.characteristic.setNotifyValue(true);
        } on Object {
          // In cattura si prova tutto: qualche caratteristica rifiuterà, e
          // rinunciare all'intera sessione per una sola sarebbe assurdo.
          if (profile.kind != ScaleProtocolKind.unknown) {
            rethrow;
          }
        }
      }
      if (profile.kind == ScaleProtocolKind.unknown) {
        unawaited(_dumpDiagnostics(connection, services));
      }
      return connection;
    } on ScaleLinkException {
      rethrow;
    } on Object catch (error) {
      try {
        await target.disconnect();
      } on Object {
        // Già scollegato: non c'è altro da fare.
      }
      throw _translate(error);
    }
  }

  /// Cosa espone il dispositivo, in una riga che si può copiare e mandare.
  ///
  /// I servizi standard del Bluetooth SIG occupano i quattro caratteri di
  /// mezzo (`0000XXXX-0000-1000-8000-00805f9b34fb`), quindi si scrivono corti;
  /// quelli di un costruttore sono UUID interi e vanno per esteso, perché è
  /// esattamente il numero da cercare per capire che apparecchio si ha
  /// davanti.
  static String _descriviServizi(List<BluetoothService> services) {
    if (services.isEmpty) {
      return 'nessun servizio.';
    }
    final parti = <String>[];
    for (final service in services) {
      final caratteristiche = service.characteristics
          .map((c) => _breve(c.characteristicUuid.str128))
          .join(' ');
      parti.add(
        '${_breve(service.serviceUuid.str128)}'
        '${caratteristiche.isEmpty ? '' : ' [$caratteristiche]'}',
      );
    }
    return parti.join(', ');
  }

  static String _breve(String uuid) {
    final clean = uuid.toLowerCase();
    if (clean.length == 36 &&
        clean.startsWith('0000') &&
        clean.endsWith('-0000-1000-8000-00805f9b34fb')) {
      return clean.substring(4, 8);
    }
    return clean;
  }

  /// L'ultima risorsa: ci si collega a un protocollo che non si conosce e si
  /// ascolta **tutto**.
  ///
  /// Non decodifica niente e non può farlo. Serve a una cosa sola: portare in
  /// schermata i byte veri di una bilancia vera, così il protocollo si scrive
  /// una volta e giusto invece di indovinarlo a distanza.
  static _QnProfile _captureProfile(List<BluetoothService> services) {
    final ascoltabili = <_Notified>[];
    final leggibili = <_Notified>[];
    for (final service in services) {
      // I servizi di sistema si saltano: `1800`, `1801` e `180a` ci sono su
      // ogni dispositivo Bluetooth del mondo e non hanno mai pesato nessuno.
      // L'aggiornamento firmware Nordic idem — e scriverci sopra per sbaglio
      // è l'unico modo di rompere una bilancia da un'app.
      final uuid = _breve(service.serviceUuid.str128);
      if (uuid == '1800' || uuid == '1801' || uuid == '180a') {
        continue;
      }
      if (service.serviceUuid.str128.toLowerCase().startsWith('00001530-')) {
        continue;
      }
      for (final c in service.characteristics) {
        final etichetta = _breve(c.characteristicUuid.str128);
        if (c.properties.notify || c.properties.indicate) {
          ascoltabili.add(_Notified(c, ScaleProtocolKind.unknown, etichetta));
        }
        if (c.properties.read) {
          leggibili.add(_Notified(c, ScaleProtocolKind.unknown, etichetta));
        }
      }
    }
    return _QnProfile(
      notified: ascoltabili,
      kind: ScaleProtocolKind.unknown,
      readable: leggibili,
      description: _descriviServizi(services),
    );
  }

  /// Mette nel flusso, come se fossero trame, ciò che si sa senza aspettare:
  /// l'elenco dei servizi e il contenuto di ogni caratteristica leggibile.
  ///
  /// Spesso è già metà della risposta — numero di serie, versione del
  /// firmware, unità impostata — e comunque arriva anche se poi la bilancia
  /// non dice una parola.
  static Future<void> _dumpDiagnostics(
    _FlutterBluePlusConnection connection,
    List<BluetoothService> services,
  ) async {
    for (final leggibile in connection.profile.readable) {
      try {
        final value = await leggibile.characteristic.read();
        connection.pushCapture(leggibile.label, value);
      } on Object {
        // Una caratteristica che si rifiuta di farsi leggere non è una notizia.
      }
    }
  }

  static String _nameOf(ScanResult result) {
    final advertised = result.advertisementData.advName.trim();
    return advertised.isNotEmpty ? advertised : result.device.platformName;
  }

  /// Cosa si può ascoltare su questo dispositivo, in ordine di preferenza.
  ///
  /// L'ordine è `181B` → Qingniu → `181D`, e ognuno dei tre posti è motivato:
  ///
  /// - Il *Body Composition* standard viene per primo perché dà tutto (peso e
  ///   impedenza) ed è **pubblicato**, mentre il dialogo di Qingniu è stato
  ///   ricavato per tentativi da chi l'ha decodificato.
  /// - Il *Weight Scale* standard viene per **ultimo**, dopo Qingniu, ed è una
  ///   correzione: dà il solo peso, quindi anteporlo a Qingniu su una bilancia
  ///   che espone entrambi sarebbe stato un peggioramento garantito — niente
  ///   impedenza significa niente composizione, per sempre. «Pubblicato batte
  ///   indovinato» vale finché il pubblicato non dà **meno**.
  ///
  /// Le due caratteristiche standard si ascoltano **insieme** quando ci sono
  /// entrambe: nel *Body Composition* il peso è un campo opzionale proprio
  /// perché è previsto che un dispositivo che espone anche il *Weight Scale*
  /// lo mandi di là. Ascoltandone una sola, da una bilancia fatta così
  /// arriverebbe l'impedenza senza mai un peso, e la pesata morirebbe per
  /// scadenza del tempo con il numero già pubblicato dall'altra parte.
  static _QnProfile? _profileOf(List<BluetoothService> services) {
    // La R-MSC02 per prima, e non per favoritismo: è l'unica bilancia vera che
    // questo codice abbia mai avuto sotto i piedi, e il suo formato è stato
    // ricavato dalle sue trame invece che da un documento. Se un giorno
    // esponesse anche uno dei servizi standard, quello resterebbe comunque un
    // ripiego rispetto a un protocollo verificato sul campo.
    for (final service in services) {
      if (service.serviceUuid == Guid(RenphoMsc.serviceUuid)) {
        final live = _find(service, RenphoMsc.liveUuid);
        final status = _find(service, RenphoMsc.statusUuid);
        if (live != null || status != null) {
          return _QnProfile(
            notified: [
              if (live != null)
                _Notified(live, ScaleProtocolKind.renphoMsc, '2a10'),
              if (status != null)
                _Notified(status, ScaleProtocolKind.renphoMsc, '2a12'),
            ],
            kind: ScaleProtocolKind.renphoMsc,
            config: _find(service, RenphoMsc.writeUuid),
          );
        }
      }
    }

    BluetoothCharacteristic? bodyComposition;
    BluetoothCharacteristic? weight;
    for (final service in services) {
      if (service.serviceUuid == Guid(GattScale.bodyCompositionService)) {
        bodyComposition ??= _find(
          service,
          GattScale.bodyCompositionMeasurement,
        );
      }
      if (service.serviceUuid == Guid(GattScale.weightScaleService)) {
        weight ??= _find(service, GattScale.weightMeasurement);
      }
    }
    if (bodyComposition != null) {
      return _QnProfile(
        notified: [
          _Notified(
            bodyComposition,
            ScaleProtocolKind.gattBodyComposition,
            '2a9c',
          ),
          if (weight != null)
            _Notified(weight, ScaleProtocolKind.gattWeight, '2a9d'),
        ],
        kind: ScaleProtocolKind.gattBodyComposition,
      );
    }

    for (final service in services) {
      if (service.serviceUuid == Guid(QnScale.serviceUuid)) {
        final notify = _find(service, QnScale.notifyUuid);
        final config = _find(service, QnScale.writeUuid);
        if (notify != null && config != null) {
          return _QnProfile(
            notified: [_Notified(notify, ScaleProtocolKind.qingniu, 'ffe1')],
            kind: ScaleProtocolKind.qingniu,
            config: config,
            time: _find(service, QnScale.timeUuid) ?? config,
          );
        }
      }
      if (service.serviceUuid == Guid(QnScale.altServiceUuid)) {
        final notify = _find(service, QnScale.altNotifyUuid);
        final write = _find(service, QnScale.altWriteUuid);
        if (notify != null && write != null) {
          // Nel profilo «tipo 2» orologio e unità viaggiano sulla stessa
          // caratteristica.
          return _QnProfile(
            notified: [_Notified(notify, ScaleProtocolKind.qingniu, 'fff1')],
            kind: ScaleProtocolKind.qingniu,
            config: write,
            time: write,
          );
        }
      }
    }

    if (weight != null) {
      return _QnProfile(
        notified: [_Notified(weight, ScaleProtocolKind.gattWeight, '2a9d')],
        kind: ScaleProtocolKind.gattWeight,
      );
    }
    return null;
  }

  static BluetoothCharacteristic? _find(BluetoothService service, String uuid) {
    final wanted = Guid(uuid);
    for (final characteristic in service.characteristics) {
      if (characteristic.characteristicUuid == wanted) {
        return characteristic;
      }
    }
    return null;
  }

  /// Traduce gli errori della libreria nelle categorie del dominio.
  ///
  /// Il messaggio originale si conserva: è quello che finisce nel registro
  /// diagnostico, e senza di lui una diagnosi a distanza è impossibile.
  static ScaleLinkException _translate(Object error) {
    if (error is ScaleLinkException) {
      return error;
    }
    final text = error.toString();
    if (error is FlutterBluePlusException) {
      final lower = text.toLowerCase();
      if (lower.contains('permission') || lower.contains('unauthorized')) {
        return ScaleLinkException(ScaleLinkFailure.permissionDenied, text);
      }
      if (lower.contains('adapter is off') ||
          lower.contains('bluetooth must be turned on') ||
          lower.contains('poweredoff')) {
        return ScaleLinkException(ScaleLinkFailure.radioOff, text);
      }
      if (lower.contains('not supported') || lower.contains('unavailable')) {
        return ScaleLinkException(ScaleLinkFailure.unsupported, text);
      }
      return ScaleLinkException(ScaleLinkFailure.connection, text);
    }
    if (error is TimeoutException) {
      return ScaleLinkException(
        ScaleLinkFailure.connection,
        'Tempo scaduto: $text',
      );
    }
    return ScaleLinkException(ScaleLinkFailure.unknown, text);
  }
}

/// Le caratteristiche che servono, già trovate, e che protocollo sono.
///
/// Il profilo standard ha la sola caratteristica di notifica: non si scrive
/// niente, non c'è nessun orologio da sincronizzare e nessuna unità da
/// imporre. Per questo [config] e [time] sono nulle lì — e chiunque provi a
/// scrivere se ne accorge subito invece di mandare byte nel vuoto.
/// Una caratteristica da ascoltare, con l'etichetta da mettere nel registro.
class _Notified {
  const _Notified(this.characteristic, this.kind, this.label);

  final BluetoothCharacteristic characteristic;
  final ScaleProtocolKind kind;
  final String label;
}

class _QnProfile {
  const _QnProfile({
    required this.notified,
    required this.kind,
    this.config,
    this.time,
    this.readable = const <_Notified>[],
    this.description,
  });

  /// Tutto ciò che si ascolta. Sono più di una quando la bilancia espone
  /// insieme il *Body Composition* e il *Weight Scale*, e sono tante in
  /// cattura.
  final List<_Notified> notified;
  final ScaleProtocolKind kind;
  final BluetoothCharacteristic? config;
  final BluetoothCharacteristic? time;

  /// Solo in cattura: le caratteristiche da leggere una volta all'apertura.
  final List<_Notified> readable;

  /// Solo in cattura: cosa espone il dispositivo, per il registro.
  final String? description;
}

class _FlutterBluePlusConnection implements ScaleConnection {
  _FlutterBluePlusConnection({required this.device, required this.profile}) {
    // La sottoscrizione parte ora, prima che le notifiche siano accese: le
    // trame che arrivassero nel frattempo restano nel controller (che non è
    // broadcast, quindi accumula) e il lettore le trova appena si mette in
    // ascolto. Senza questo cuscinetto la presentazione della bilancia
    // andrebbe persa a ogni collegamento fortunato.
    for (final ascoltata in profile.notified) {
      _taps.add(
        ascoltata.characteristic.onValueReceived.listen(
          (bytes) => _buffer.add(
            ScaleFrame(bytes, ascoltata.kind, label: ascoltata.label),
          ),
          onError: _buffer.addError,
        ),
      );
    }
  }

  /// Mette nel flusso una riga di diagnostica, come se fosse una trama.
  void pushCapture(String label, List<int> bytes) {
    if (!_buffer.isClosed) {
      _buffer.add(ScaleFrame(bytes, ScaleProtocolKind.unknown, label: label));
    }
  }

  /// Cosa espone il dispositivo, quando il protocollo non si conosce.
  String? get description => profile.description;

  final BluetoothDevice device;
  final _QnProfile profile;

  final _buffer = StreamController<ScaleFrame>();
  final _taps = <StreamSubscription<List<int>>>[];

  @override
  Stream<ScaleFrame> get incoming => _buffer.stream;

  @override
  ScaleProtocolKind get kind => profile.kind;

  @override
  Future<void> send(List<int> bytes) async {
    // L'instradamento dipende dall'opcode: nel profilo «tipo 1» l'orologio ha
    // una caratteristica sua. È conoscenza di trasporto, non di dominio, e per
    // questo sta qui e non nel lettore.
    final target = bytes.isNotEmpty && bytes.first == QnScale.opcodeTimeReply
        ? profile.time
        : profile.config;
    if (target == null) {
      // Il profilo standard non ha niente a cui scrivere, e non è un guasto:
      // non chiede presentazioni e non si configura. Chi manda comandi qui li
      // manda per abitudine, e il posto giusto per fermarli è questo.
      return;
    }
    // Con risposta quando la caratteristica la prevede: l'ack è dello stack
    // Bluetooth, non della bilancia, quindi non c'è niente da aspettare che
    // possa non arrivare. Se la caratteristica ammette solo la scrittura senza
    // risposta, si scrive così.
    return target.write(bytes, withoutResponse: !target.properties.write);
  }

  @override
  Future<void> close() async {
    for (final tap in _taps) {
      await tap.cancel();
    }
    if (!_buffer.isClosed) {
      await _buffer.close();
    }
    try {
      await device.disconnect();
    } on Object {
      // Se il collegamento è già caduto va bene così: l'importante è non
      // lasciare la bilancia agganciata a un'app che non la ascolta più.
    }
  }
}
