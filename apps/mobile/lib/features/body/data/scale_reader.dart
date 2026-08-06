import 'dart:async';

import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';
import 'package:kal_tracker/features/body/domain/scale_log.dart';
import 'package:kal_tracker/features/body/domain/scale_session.dart';

/// Una sessione con la bilancia, dall'accensione della radio alla pesata.
///
/// Tutta la logica sta qui e non nell'adattatore Bluetooth per una ragione
/// sola: **questa cosa non si può provare su una bilancia vera prima di
/// consegnarla**. Sopra [ScaleLink] si può invece far salire un dispositivo
/// finto e verificare ogni modo di sbagliare — radio spenta, permesso negato,
/// bilancia assente, elettrodi che non fanno contatto, collegamento che cade
/// a metà.
///
/// **Il momento delicato è la pesata incompleta.** La bilancia manda prima il
/// peso stabile e solo dopo, se gli elettrodi hanno fatto contatto, la trama
/// con l'impedenza. Chiudere sulla prima trama stabile butterebbe via
/// l'impedenza di quasi tutte le pesate buone; aspettarla per sempre lascerebbe
/// Marco in piedi a fissare uno spinner. Quindi: alla prima trama stabile si
/// tiene il peso da parte e si concede [impedanceGrace] all'impedenza. Se non
/// arriva, la pesata si chiude come «solo peso», che è un esito legittimo e
/// dichiarato, non un errore.
class ScaleReader {
  ScaleReader(
    this._link, {
    ScaleLog? log,
    DateTime Function()? clock,
    this.scanTimeout = const Duration(seconds: 12),
    this.handshakeTimeout = const Duration(seconds: 5),
    this.stepOnTimeout = const Duration(seconds: 45),
    this.impedanceGrace = const Duration(seconds: 8),
  }) : _log = log ?? ScaleLog(),
       _clock = clock ?? DateTime.now;

  final ScaleLink _link;
  final ScaleLog _log;
  final DateTime Function() _clock;

  /// Quanto si cerca prima di dire «non l'ho trovata». La bilancia resta
  /// sveglia una manciata di secondi dopo che ci si è saliti sopra.
  final Duration scanTimeout;

  /// Quanto si aspetta la presentazione `0x12` prima di andare avanti lo
  /// stesso: alcune bilance non la mandano mai, e insistere le perderebbe.
  final Duration handshakeTimeout;

  /// Quanto si aspetta che qualcuno ci salga sopra.
  final Duration stepOnTimeout;

  /// Quanto si concede all'impedenza dopo il peso stabile.
  final Duration impedanceGrace;

  ScaleLog get log => _log;

  Completer<ScaleStatus>? _session;

  /// Interrompe la sessione in corso, se c'è. La chiama la schermata quando
  /// viene chiusa: senza, il collegamento Bluetooth resterebbe aperto fino
  /// allo scadere dei timeout.
  void cancel() {
    final session = _session;
    if (session != null && !session.isCompleted) {
      _note('sessione interrotta');
      session.complete(
        _build(ScalePhase.failed, errorDetail: 'Sessione interrotta.'),
      );
    }
  }

  /// Fa tutto il giro e torna lo stato finale. [onStatus] riceve ogni
  /// avanzamento, registro compreso: la schermata non deve fare altro che
  /// disegnare quello che le arriva.
  Future<ScaleStatus> read({
    void Function(ScaleStatus status)? onStatus,
  }) async {
    _log.clear();
    _onStatus = onStatus;

    final radio = await _radioState();
    if (radio != ScaleRadioState.on) {
      return _emit(switch (radio) {
        ScaleRadioState.off => ScalePhase.radioOff,
        ScaleRadioState.unauthorized => ScalePhase.permissionDenied,
        ScaleRadioState.unsupported => ScalePhase.unsupported,
        ScaleRadioState.on => ScalePhase.scanning,
      });
    }

    final ScaleDevice? device;
    try {
      device = await _findScale();
    } on ScaleLinkException catch (error) {
      return _fail(error);
    }
    if (device == null) {
      return _emit(ScalePhase.notFound);
    }

    _emit(ScalePhase.connecting);
    _note('mi collego a ${device.name}');
    final ScaleConnection connection;
    try {
      connection = await _link.connect(device);
    } on ScaleLinkException catch (error) {
      return _fail(error);
    } on Object catch (error) {
      return _emit(ScalePhase.failed, errorDetail: '$error');
    }

    return _converse(connection, device);
  }

  // -------------------------------------------------------------------
  // Il dialogo vero e proprio.
  // -------------------------------------------------------------------

  Future<ScaleStatus> _converse(
    ScaleConnection connection,
    ScaleDevice device,
  ) async {
    final session = _session = Completer<ScaleStatus>();
    var scaleFactor = 100.0;
    var protocolType = QnScale.defaultProtocolType;
    var introduced = false;
    ScaleReading? weightOnly;

    Timer? handshakeTimer;
    Timer? stepOnTimer;
    Timer? graceTimer;

    void finish(ScaleStatus status) {
      if (!session.isCompleted) {
        session.complete(status);
      }
    }

    Future<void> introduce() async {
      if (introduced) {
        return;
      }
      introduced = true;
      handshakeTimer?.cancel();
      try {
        final time = qnTimeCommand(now: _clock(), protocolType: protocolType);
        await connection.send(time);
        _note('orologio sincronizzato', hex: qnHex(time));
        final config = qnConfigCommand(protocolType: protocolType);
        await connection.send(config);
        _note('unità impostata su chilogrammi', hex: qnHex(config));
      } on Object catch (error) {
        // Non è fatale: molte bilance mandano il peso anche senza risposta.
        // Vale però la pena scriverlo, perché una bilancia rimasta in libbre
        // si spiega esattamente così.
        _note(
          'la bilancia non ha accettato i comandi: $error',
          isProblem: true,
        );
      }
      _emit(ScalePhase.stepOn);
    }

    void onFrame(List<int> bytes) {
      final frame = decodeQnFrame(bytes, weightScaleFactor: scaleFactor);
      if (frame == null) {
        _note('trama vuota o illeggibile', hex: qnHex(bytes), isProblem: true);
        _emit(introduced ? ScalePhase.stepOn : ScalePhase.handshake);
        return;
      }
      _note(
        frame.checksumOk ? '$frame' : '$frame — somma di controllo sbagliata',
        hex: frame.hex,
        isProblem: !frame.checksumOk,
      );

      switch (frame) {
        case QnHandshakeFrame(
          protocolType: final type,
          weightScaleFactor: final factor,
        ):
          scaleFactor = factor;
          protocolType = type;
          unawaited(introduce());

        case QnWeightFrame():
          if (!introduced) {
            // Bilancia che salta le presentazioni: si va avanti lo stesso.
            unawaited(introduce());
          }
          if (!frame.stable) {
            _emit(ScalePhase.reading);
            return;
          }
          stepOnTimer?.cancel();
          final reading = ScaleReading(
            measuredAt: _clock().toUtc(),
            weightKg: frame.weightKg,
            deviceName: device.name,
            rawPayloadHex: frame.hex,
            impedanceOhm: frame.hasImpedance ? frame.resistance1 : null,
            secondaryOhm: frame.resistance2 > 0 ? frame.resistance2 : null,
          );
          if (reading.hasImpedance) {
            graceTimer?.cancel();
            finish(_emit(ScalePhase.ready, reading: reading));
            return;
          }
          // Peso stabile senza impedenza: si tiene da parte e si concede
          // qualche secondo alla misura elettrica, che arriva sempre dopo.
          weightOnly = reading;
          _emit(ScalePhase.reading, reading: reading);
          graceTimer ??= Timer(impedanceGrace, () {
            _note('impedenza non arrivata: chiudo con il solo peso');
            finish(_emit(ScalePhase.incomplete, reading: weightOnly));
          });

        case QnUnknownFrame():
          _emit(introduced ? ScalePhase.stepOn : ScalePhase.handshake);
      }
    }

    _emit(ScalePhase.handshake);
    final subscription = connection.incoming.listen(
      onFrame,
      onError: (Object error) {
        _note('errore dal collegamento: $error', isProblem: true);
        finish(_emit(ScalePhase.failed, errorDetail: '$error'));
      },
      onDone: () {
        if (!session.isCompleted) {
          _note('la bilancia si è scollegata', isProblem: true);
          finish(
            _emit(
              ScalePhase.failed,
              errorDetail:
                  'La bilancia si è scollegata prima di dare una pesata '
                  'stabile.',
            ),
          );
        }
      },
      cancelOnError: false,
    );

    handshakeTimer = Timer(handshakeTimeout, () {
      _note('nessuna presentazione: vado avanti lo stesso');
      unawaited(introduce());
    });
    stepOnTimer = Timer(stepOnTimeout, () {
      finish(
        _emit(
          ScalePhase.failed,
          errorDetail:
              'Nessuna pesata stabile in ${stepOnTimeout.inSeconds} secondi.',
        ),
      );
    });

    try {
      return await session.future;
    } finally {
      handshakeTimer.cancel();
      stepOnTimer.cancel();
      graceTimer?.cancel();
      await subscription.cancel();
      await connection.close();
      _session = null;
    }
  }

  // -------------------------------------------------------------------
  // Passi singoli.
  // -------------------------------------------------------------------

  Future<ScaleRadioState> _radioState() async {
    _emit(ScalePhase.checkingRadio);
    try {
      final state = await _link.radioState();
      _note('radio: ${state.name}');
      return state;
    } on ScaleLinkException catch (error) {
      _note(error.message, isProblem: true);
      return switch (error.failure) {
        ScaleLinkFailure.permissionDenied => ScaleRadioState.unauthorized,
        ScaleLinkFailure.radioOff => ScaleRadioState.off,
        _ => ScaleRadioState.unsupported,
      };
    }
  }

  Future<ScaleDevice?> _findScale() async {
    _emit(ScalePhase.scanning);
    final seen = <String>{};
    final found = Completer<ScaleDevice?>();
    // Si ascolta invece di usare `await for`, e la disiscrizione non si
    // aspetta: uscire da un `await for` significa attendere il `cancel` dello
    // stream, e se la sorgente ci mette un istante a chiudersi la sessione
    // resta ferma sulla scansione con la bilancia già trovata. Qui appena la
    // bilancia c'è si va avanti, e la scansione si spegne per conto suo.
    final subscription = _link
        .scan(timeout: scanTimeout)
        .listen(
          (device) {
            if (found.isCompleted || !seen.add(device.id)) {
              return;
            }
            if (looksLikeQnScale(
              name: device.name,
              serviceUuids: device.serviceUuids,
            )) {
              _note(
                'trovata ${device.name.isEmpty ? device.id : device.name}'
                '${device.name.isEmpty ? ' (riconosciuta dal servizio)' : ''}',
              );
              found.complete(device);
              return;
            }
            // I vicini scartati sono la prima cosa da guardare quando la
            // bilancia «non si trova»: dicono se la scansione stava
            // funzionando. Con i servizi annunciati, perché senza il nome
            // — che moltissimi dispositivi non mettono — una riga con il solo
            // indirizzo non aiuta nessuno a capire cosa fosse.
            final etichetta = device.name.isEmpty ? device.id : device.name;
            final servizi = device.serviceUuids.isEmpty
                ? 'nessun servizio annunciato'
                : device.serviceUuids.map(_servizioBreve).join(' ');
            _note('visto $etichetta [$servizi], non è una bilancia');
            _emit(ScalePhase.scanning);
          },
          onError: (Object error) {
            if (!found.isCompleted) {
              found.completeError(error);
            }
          },
          onDone: () {
            if (!found.isCompleted) {
              found.complete(null);
            }
          },
        );
    try {
      return await found.future;
    } finally {
      unawaited(subscription.cancel());
    }
  }

  // -------------------------------------------------------------------
  // Registro e stato.
  // -------------------------------------------------------------------

  void Function(ScaleStatus status)? _onStatus;

  void _note(String message, {String? hex, bool isProblem = false}) =>
      _log.add(_clock(), message, hex: hex, isProblem: isProblem);

  ScaleStatus _build(
    ScalePhase phase, {
    ScaleReading? reading,
    String? errorDetail,
  }) => ScaleStatus(
    phase: phase,
    reading: reading,
    errorDetail: errorDetail,
    log: _log.entries,
  );

  ScaleStatus _emit(
    ScalePhase phase, {
    ScaleReading? reading,
    String? errorDetail,
  }) {
    final status = _build(phase, reading: reading, errorDetail: errorDetail);
    _onStatus?.call(status);
    return status;
  }

  ScaleStatus _fail(ScaleLinkException error) {
    _note(error.message, isProblem: true);
    return _emit(switch (error.failure) {
      ScaleLinkFailure.permissionDenied => ScalePhase.permissionDenied,
      ScaleLinkFailure.radioOff => ScalePhase.radioOff,
      ScaleLinkFailure.unsupported => ScalePhase.unsupported,
      _ => ScalePhase.failed,
    }, errorDetail: error.message);
  }
}

/// La forma corta di un UUID di servizio, per il registro.
///
/// `0000ffe0-0000-1000-8000-00805f9b34fb` diventa `ffe0`: è l'unica parte che
/// cambia fra un servizio e l'altro, e il resto riempirebbe la riga senza
/// dire niente.
String _servizioBreve(String uuid) {
  final clean = uuid.trim().toLowerCase();
  if (clean.length == 36 && clean.startsWith('0000')) {
    return clean.substring(4, 8);
  }
  return clean;
}
