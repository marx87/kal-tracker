import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';

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

    Future<void> start() async {
      try {
        results = FlutterBluePlus.onScanResults.listen((found) {
          for (final result in found) {
            controller.add(
              ScaleDevice(
                id: result.device.remoteId.str,
                name: _nameOf(result),
              ),
            );
            _seen[result.device.remoteId.str] = result.device;
          }
        }, onError: (Object error) => controller.addError(_translate(error)));
        // I filtri della libreria sono in OR: si prende sia chi si annuncia
        // col servizio sia chi si annuncia col nome. Serve, perché non tutte
        // le QN mettono l'UUID nell'annuncio, e `ffe0` da solo tirerebbe su
        // mezzo condominio.
        await FlutterBluePlus.startScan(
          withServices: [
            Guid(QnScale.serviceUuid),
            Guid(QnScale.altServiceUuid),
          ],
          withNames: [QnScale.advertisedName],
          timeout: timeout,
        );
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
      final profile = _profileOf(services);
      if (profile == null) {
        await target.disconnect();
        throw ScaleLinkException(
          ScaleLinkFailure.connection,
          'Il dispositivo non espone il servizio della bilancia '
          '(${QnScale.serviceUuid} né ${QnScale.altServiceUuid}).',
        );
      }
      // L'ascolto si apre PRIMA di accendere le notifiche: la bilancia manda
      // la sua presentazione appena la sottoscrizione è attiva, e sottoscrivere
      // dopo perderebbe proprio la trama che dichiara la scala del peso.
      final connection = _FlutterBluePlusConnection(
        device: target,
        profile: profile,
      );
      await profile.notify.setNotifyValue(true);
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

  static String _nameOf(ScanResult result) {
    final advertised = result.advertisementData.advName.trim();
    return advertised.isNotEmpty ? advertised : result.device.platformName;
  }

  static _QnProfile? _profileOf(List<BluetoothService> services) {
    for (final service in services) {
      if (service.serviceUuid == Guid(QnScale.serviceUuid)) {
        final notify = _find(service, QnScale.notifyUuid);
        final config = _find(service, QnScale.writeUuid);
        if (notify != null && config != null) {
          return _QnProfile(
            notify: notify,
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
          return _QnProfile(notify: notify, config: write, time: write);
        }
      }
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

/// Le tre caratteristiche che servono, già trovate.
class _QnProfile {
  const _QnProfile({
    required this.notify,
    required this.config,
    required this.time,
  });

  final BluetoothCharacteristic notify;
  final BluetoothCharacteristic config;
  final BluetoothCharacteristic time;
}

class _FlutterBluePlusConnection implements ScaleConnection {
  _FlutterBluePlusConnection({required this.device, required this.profile}) {
    // La sottoscrizione parte ora, prima che le notifiche siano accese: le
    // trame che arrivassero nel frattempo restano nel controller (che non è
    // broadcast, quindi accumula) e il lettore le trova appena si mette in
    // ascolto. Senza questo cuscinetto la presentazione della bilancia
    // andrebbe persa a ogni collegamento fortunato.
    _tap = profile.notify.onValueReceived.listen(
      _buffer.add,
      onError: _buffer.addError,
    );
  }

  final BluetoothDevice device;
  final _QnProfile profile;

  final _buffer = StreamController<List<int>>();
  late final StreamSubscription<List<int>> _tap;

  @override
  Stream<List<int>> get incoming => _buffer.stream;

  @override
  Future<void> send(List<int> bytes) {
    // L'instradamento dipende dall'opcode: nel profilo «tipo 1» l'orologio ha
    // una caratteristica sua. È conoscenza di trasporto, non di dominio, e per
    // questo sta qui e non nel lettore.
    final target = bytes.isNotEmpty && bytes.first == QnScale.opcodeTimeReply
        ? profile.time
        : profile.config;
    // Con risposta quando la caratteristica la prevede: l'ack è dello stack
    // Bluetooth, non della bilancia, quindi non c'è niente da aspettare che
    // possa non arrivare. Se la caratteristica ammette solo la scrittura senza
    // risposta, si scrive così.
    return target.write(bytes, withoutResponse: !target.properties.write);
  }

  @override
  Future<void> close() async {
    await _tap.cancel();
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
