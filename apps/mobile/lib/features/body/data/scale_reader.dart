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
    this.scanTimeout = const Duration(seconds: 30),
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

  /// I dispositivi visti nella scansione in corso, per indirizzo.
  final _candidates = <String, ScaleDevice>{};

  /// La scelta ancora aperta, quando la scansione è in corso. Completarla da
  /// fuori è ciò che permette a Marco di toccare la bilancia appena compare,
  /// senza aspettare che la ricerca finisca.
  Completer<ScaleDevice?>? _selection;

  /// L'indirizzo scelto a mano una volta e ricordato. Vince su qualunque
  /// riconoscimento: se Marco ha già detto «è questa», non c'è euristica che
  /// debba poterlo smentire.
  String? _preferredDeviceId;

  /// Vero da quando [cancel] è stata chiamata fino alla lettura successiva.
  ///
  /// Serve perché il collegamento Bluetooth, una volta chiesto, non si può
  /// richiamare indietro: se la schermata si chiude proprio in quell'istante,
  /// l'unica cosa onesta è aprirlo e chiuderlo subito, invece di lasciare la
  /// bilancia agganciata a un'app che non la ascolta più.
  bool _cancelled = false;

  /// Interrompe la sessione in corso, se c'è. La chiama la schermata quando
  /// viene chiusa: senza, il collegamento Bluetooth resterebbe aperto fino
  /// allo scadere dei timeout.
  void cancel() {
    // L'interruzione va segnata prima di tutto: fra la scelta del dispositivo
    // e il collegamento aperto c'è un `await` sul Bluetooth che non si può
    // interrompere a metà, e senza questa memoria la sessione andrebbe avanti
    // a collegarsi a schermata già chiusa.
    _cancelled = true;

    // La scansione era il buco: `_session` esiste solo dentro `_converse`,
    // quindi chiudere la schermata mentre si cercava non fermava proprio
    // niente. La ricerca proseguiva per i suoi trenta secondi, poi si
    // collegava lo stesso a una bilancia che nessuno stava più guardando, e
    // il collegamento restava aperto fino allo scadere del tempo di salita.
    final selection = _selection;
    if (selection != null && !selection.isCompleted) {
      _note('sessione interrotta durante la ricerca');
      selection.complete(null);
    }

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
    String? preferredDeviceId,
  }) async {
    _log.clear();
    _onStatus = onStatus;
    _preferredDeviceId = preferredDeviceId;
    _candidates.clear();
    _cancelled = false;
    if (preferredDeviceId != null) {
      _note('bilancia già scelta una volta: cerco $preferredDeviceId');
    }

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
      // Interrotta a mano: non è «non trovata» e non è «scegli tu». Chiedere
      // di scegliere a chi ha appena chiuso la schermata sarebbe assurdo, e
      // per giunta lascerebbe l'ultima parola a un elenco raccolto a metà.
      if (_cancelled) {
        return _emit(ScalePhase.failed, errorDetail: 'Sessione interrotta.');
      }
      // Due esiti diversi, e distinguerli è il punto: se qualcosa si è visto,
      // la radio funziona e la bilancia è probabilmente lì sotto un nome che
      // non conosco — allora sceglie Marco. Se non si è visto nulla, il
      // problema è a monte e un elenco vuoto non aiuterebbe nessuno.
      return _emit(
        _candidates.isEmpty ? ScalePhase.notFound : ScalePhase.chooseDevice,
      );
    }

    return connectTo(device);
  }

  /// Si collega a un dispositivo già scelto e porta avanti la pesata.
  ///
  /// La usa la scelta manuale: quando il riconoscimento automatico ha
  /// fallito, la scansione è finita e non c'è più niente da cercare — c'è solo
  /// un indirizzo su cui andare.
  Future<ScaleStatus> connectTo(
    ScaleDevice device, {
    void Function(ScaleStatus status)? onStatus,
  }) async {
    // Chi arriva da una scansione ha già il suo ascoltatore: si sovrascrive
    // solo se ne viene passato uno nuovo, altrimenti gli avanzamenti del
    // collegamento non arriverebbero a nessuno.
    _onStatus = onStatus ?? _onStatus;
    if (_cancelled) {
      return _emit(ScalePhase.failed, errorDetail: 'Sessione interrotta.');
    }
    _emit(ScalePhase.connecting);
    _note('mi collego a ${_etichetta(device)}');
    final ScaleConnection connection;
    try {
      connection = await _link.connect(device);
    } on ScaleLinkException catch (error) {
      return _fail(error);
    } on Object catch (error) {
      return _emit(ScalePhase.failed, errorDetail: '$error');
    }
    if (_cancelled) {
      // Chiuso mentre il collegamento si apriva. Non c'era modo di fermarlo
      // prima: lo si chiude subito, che è l'unica differenza che conta per la
      // bilancia — resta libera per il prossimo tentativo invece di restare
      // agganciata per tre quarti di minuto.
      _note('interrotta a collegamento aperto: chiudo subito');
      unawaited(connection.close());
      return _emit(ScalePhase.failed, errorDetail: 'Sessione interrotta.');
    }

    return _converse(connection, device);
  }

  /// Sceglie a mano un dispositivo **mentre la scansione è ancora in corso**.
  ///
  /// Torna vero quando la scelta è stata raccolta: da lì in poi ci pensa la
  /// [read] già in volo, che prosegue col collegamento. Torna falso quando non
  /// c'è nessuna scansione aperta — allora tocca a [connectTo].
  bool chooseWhileScanning(ScaleDevice device) {
    final selection = _selection;
    if (selection == null || selection.isCompleted) {
      return false;
    }
    _note('scelta a mano: ${_etichetta(device)}');
    selection.complete(device);
    return true;
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
    final found = _selection = Completer<ScaleDevice?>();
    // Una che *sembra* una bilancia mentre però se ne aspetta una scelta già
    // fatta: si tiene da parte invece di prenderla subito.
    ScaleDevice? ripiego;
    // Si ascolta invece di usare `await for`, e la disiscrizione non si
    // aspetta: uscire da un `await for` significa attendere il `cancel` dello
    // stream, e se la sorgente ci mette un istante a chiudersi la sessione
    // resta ferma sulla scansione con la bilancia già trovata. Qui appena la
    // bilancia c'è si va avanti, e la scansione si spegne per conto suo.
    final subscription = _link
        .scan(timeout: scanTimeout)
        .listen(
          (device) {
            if (found.isCompleted) {
              return;
            }
            // Ogni dispositivo entra nell'elenco, riconosciuto o no: è quello
            // che la schermata mostra mentre cerca, ed è l'unica via d'uscita
            // quando il riconoscimento automatico non ce la fa.
            //
            // L'aggiornamento avviene PRIMA del filtro sui doppioni, e non è
            // un dettaglio: la radio ripubblica lo stesso dispositivo a ogni
            // giro con la potenza aggiornata, e scartarlo come «già visto»
            // congelava i dBm al primo avvistamento. Attraverso un corpo
            // bagnato quel numero oscilla di quindici decibel, quindi un
            // campione solo non dice niente — ed è l'unico appiglio che ha
            // Marco per distinguere la bilancia da un indirizzo anonimo.
            // Riassegnare una chiave che esiste già non sposta la sua
            // posizione nella mappa: l'ordine dell'elenco non cambia.
            final noto = _candidates[device.id];
            _candidates[device.id] = device;
            if (!seen.add(device.id)) {
              // Già raccontato nel registro. Si ridisegna solo se la potenza
              // si è mossa abbastanza da cambiare la riga: sotto i cinque
              // decibel è rumore, e ridisegnare a ogni annuncio farebbe
              // tremolare l'elenco senza dire niente di nuovo.
              if (noto != null && (noto.rssi - device.rssi).abs() >= 5) {
                _emit(ScalePhase.scanning);
              }
              return;
            }
            if (device.id == _preferredDeviceId) {
              _note('è la bilancia scelta la volta scorsa: vado dritto');
              found.complete(device);
              return;
            }
            if (looksLikeQnScale(
              name: device.name,
              serviceUuids: device.serviceUuids,
            )) {
              if (_preferredDeviceId != null) {
                // Marco ha già risposto alla domanda «qual è la tua
                // bilancia», e il riconoscimento è largo per scelta: «QN-»,
                // «RENPHO», i nomi di modello. Un altro apparecchio della
                // stessa famiglia — o il vicino di casa — che si annuncia un
                // istante prima non deve poter dirottare la sessione su di
                // sé. Resta un ripiego per il caso in cui la bilancia scelta
                // oggi non si faccia proprio vedere.
                ripiego ??= device;
                _note(
                  'sembra una bilancia ma non è quella scelta: '
                  '${_etichetta(device)} la tengo da parte',
                );
                _emit(ScalePhase.scanning);
                return;
              }
              _note(
                'trovata ${_etichetta(device)}'
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
            final etichetta = _etichetta(device);
            if (device.knownToSystem) {
              // Un accoppiato non ha annuncio, quindi niente servizi da
              // leggere: qui si dice solo che c'è, così se la bilancia è fra
              // questi si vede che il telefono la conosce già.
              _note('già accoppiato: $etichetta, non sembra una bilancia');
              _emit(ScalePhase.scanning);
              return;
            }
            final servizi = device.serviceUuids.isEmpty
                ? 'nessun servizio'
                : device.serviceUuids.map(_servizioBreve).join(' ');
            // I dati del costruttore vanno scritti perché sono **l'altra metà
            // dell'annuncio**, e finché non li guardavamo un dispositivo
            // «senza servizi» era indistinguibile da un frigorifero. Una
            // bilancia che si annuncia solo così si riconosce da qui.
            _note(
              'visto $etichetta [$servizi] ${device.rssi} dBm',
              hex: _datiCostruttore(device),
            );
            _emit(ScalePhase.scanning);
          },
          onError: (Object error) {
            if (!found.isCompleted) {
              found.completeError(error);
            }
          },
          onDone: () {
            if (!found.isCompleted) {
              // La bilancia scelta non è comparsa: se intanto se n'è vista una
              // che le somiglia, meglio provarci che mandare Marco a scegliere
              // di nuovo da un elenco.
              found.complete(ripiego);
            }
          },
        );
    try {
      return await found.future;
    } finally {
      _selection = null;
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
    candidates: _ordinati(),
  );

  /// I candidati nell'ordine in cui sono comparsi, e **mai riordinati**.
  ///
  /// La prima versione li ordinava per nome e potenza, e sembrava sensato
  /// finché non si è provato il gesto vero: Marco è in piedi sulla bilancia,
  /// la sua Renpho è l'unica riga — anonima, perché non annuncia nessun nome —
  /// e il dito parte. Nel frattempo il televisore di là si annuncia per la
  /// prima volta; ha un nome, quindi l'ordinamento lo mette sopra, la bilancia
  /// scivola alla riga due e il tocco atterra sul televisore. Che poi viene
  /// salvato come «la bilancia di Marco».
  ///
  /// Nessun criterio di ordinamento sopravvive a questo, perché il problema
  /// non è quale sia l'ordine giusto: è che l'ordine **cambia** mentre lui
  /// mira. L'ordine di comparsa è l'unico che non si riordina mai — i nuovi si
  /// accodano in fondo e ciò che ha già sotto gli occhi resta fermo. Ed è
  /// anche l'ordine più informativo che ci sia: la bilancia si annuncia solo
  /// mentre misura, quindi è quella comparsa **adesso**, mentre lui ci saliva.
  List<ScaleDevice> _ordinati() =>
      List<ScaleDevice>.unmodifiable(_candidates.values);

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

/// Come chiamare un dispositivo in una riga di registro o in un elenco.
String _etichetta(ScaleDevice device) =>
    device.name.isEmpty ? device.id : device.name;

/// I dati del costruttore in esadecimale, azienda per azienda.
///
/// Torna `null` quando non ce ne sono, così la riga di registro resta pulita.
/// L'identificatore d'azienda è quello assegnato dal Bluetooth SIG e da solo
/// dice spesso di che apparecchio si tratta.
String? _datiCostruttore(ScaleDevice device) {
  if (device.manufacturerData.isEmpty) {
    return null;
  }
  final parti = <String>[];
  for (final entry in device.manufacturerData.entries) {
    final id = entry.key.toRadixString(16).padLeft(4, '0');
    final bytes = entry.value
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    parti.add('$id:$bytes');
  }
  return parti.join(' ');
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
