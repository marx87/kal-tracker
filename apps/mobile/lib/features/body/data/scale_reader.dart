import 'dart:async';

import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/gatt_scale_protocol.dart';
import 'package:kal_tracker/features/body/domain/qn_scale_protocol.dart';
import 'package:kal_tracker/features/body/domain/renpho_msc_protocol.dart';
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
    this.bodyCompositionTimeout = const Duration(seconds: 30),
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

  /// Quanto si resta in ascolto **dopo il peso** su una bilancia a otto
  /// elettrodi.
  ///
  /// Trenta secondi: il tempo di accorgersi del messaggio, prendere la
  /// maniglia e stendere le braccia. Gli otto secondi dell'altra attesa
  /// scadrebbero mentre Marco è ancora nel gesto.
  ///
  /// **Ma non serve allungarlo oltre**, e la ragione la dà la bilancia: si
  /// spegne per conto suo dopo pochi secondi di inattività. Quando si spegne
  /// il collegamento cade, arriva `onDone` e la sessione chiude lì — questo
  /// timer è solo il tetto per il caso in cui resti accesa senza dire più
  /// niente. Portarlo a due minuti non darebbe più tempo per misurare:
  /// darebbe due minuti di rotella davanti a una bilancia già spenta.
  final Duration bodyCompositionTimeout;

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
    // Il profilo standard è un'altra conversazione, non una variante di
    // questa: non c'è presentazione da aspettare, non c'è orologio da
    // sincronizzare, non c'è unità da imporre, e le trame hanno un'altra
    // forma. Innestarlo qui dentro a colpi di `if` avrebbe reso illeggibili
    // due dialoghi invece di uno.
    if (connection.kind == ScaleProtocolKind.unknown) {
      return _converseCapture(connection);
    }
    if (connection.kind == ScaleProtocolKind.renphoMsc) {
      return _converseRenpho(connection, device);
    }
    if (connection.kind != ScaleProtocolKind.qingniu) {
      return _converseGatt(connection, device);
    }
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

    void onFrame(ScaleFrame incoming) {
      final bytes = incoming.bytes;
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

  /// Il dialogo con la Renpho R-MSC02.
  ///
  /// Due cose insieme, e la seconda è il motivo per cui questo metodo non
  /// somiglia agli altri.
  ///
  /// **La prima**: il peso si legge e si consegna. Appena arriva il `0x24` la
  /// pesata è disponibile da salvare — non c'è nessuna ragione di far
  /// aspettare Marco per un'impedenza che potrebbe non arrivare mai.
  ///
  /// **La seconda**: la sessione **non si chiude lì**. L'impedenza in questo
  /// protocollo non si è ancora vista, e l'unico modo di trovarla è restare in
  /// ascolto oltre il peso, scrivendo per intero ogni trama sconosciuta. La
  /// cattura che ha permesso di arrivare fin qui si era fermata undici secondi
  /// dopo l'ultima trama utile: fermarsi di nuovo lì significherebbe non
  /// scoprirlo mai. Quindi si consegna il peso **e** si continua ad ascoltare,
  /// e il registro cresce mentre Marco decide se salvare.
  Future<ScaleStatus> _converseRenpho(
    ScaleConnection connection,
    ScaleDevice device,
  ) async {
    final session = _session = Completer<ScaleStatus>();
    _note('protocollo Renpho R-MSC02, ricavato dalle sue trame');

    Timer? stepOnTimer;
    Timer? codaTimer;
    final grezzo = <String>[];
    ScaleReading? pesata;
    // Il contatore che la bilancia porta nel suo battito. **Se cresce durante
    // la sessione, la composizione corporea è stata calcolata e archiviata
    // dentro la bilancia** — e non trasmessa. È la differenza fra «non è
    // riuscita a misurare» e «ha misurato e non me lo dice», che sono due cose
    // opposte da raccontare a chi è appena sceso.
    int? contatoreIniziale;
    int? contatoreCorrente;

    /// Cosa dire a fine sessione quando l'impedenza non è arrivata.
    String dettaglioFinale() {
      final prima = contatoreIniziale;
      final dopo = contatoreCorrente;
      if (prima != null && dopo != null && dopo > prima) {
        return 'La bilancia il body scan lo ha fatto: mentre eri sopra ha '
            'archiviato una misura nuova (da $prima a $dopo). Semplicemente '
            'non la manda a nessuno finché non gliela si chiede, e il comando '
            'per chiederla non lo conosco ancora. Il peso però è buono.';
      }
      return 'Il body scan non è partito. Serve il circuito chiuso: piedi '
          'nudi sugli angoli e maniglia in mano con le braccia tese, senza '
          'scendere, fino a quando il display ha finito.';
    }

    void finish(ScaleStatus status) {
      if (!session.isCompleted) {
        session.complete(status);
      }
    }

    void onFrame(ScaleFrame incoming) {
      final frame = decodeRenphoFrame(incoming.bytes);
      if (frame == null) {
        _note(
          'da ${incoming.label ?? '?'}: trama che non è di questo protocollo',
          hex: renphoHex(incoming.bytes),
          isProblem: true,
        );
        return;
      }
      // Da quale caratteristica arriva fa parte della trama quanto i byte:
      // il peso corrente veniva da `2a10` e il resto da `2a12`, e senza
      // quell'etichetta due protocolli diversi sullo stesso collegamento
      // sarebbero indistinguibili. Era andata persa passando dalla cattura
      // grezza a questo dialogo.
      _note(
        'da ${incoming.label ?? '?'}: '
        '${frame.checksumOk ? '$frame' : '$frame — somma sbagliata'}',
        hex: frame.hex,
        // Una trama mai vista è la cosa più interessante che possa succedere:
        // finché l'impedenza non si trova, è lì che va cercata.
        isProblem: !frame.checksumOk || frame is RenphoUnknownFrame,
      );
      grezzo.add(frame.hex);

      switch (frame) {
        case RenphoWeightFrame(stable: false):
          _emit(ScalePhase.reading);
        case RenphoWeightFrame(stable: true, weightKg: final kg):
          stepOnTimer?.cancel();
          pesata = ScaleReading(
            measuredAt: _clock().toUtc(),
            weightKg: kg,
            deviceName: device.name,
            rawPayloadHex: grezzo.join(' | '),
          );
          // Consegnata subito — il pulsante «Salva» c'è già — ma la fase dice
          // **non scendere**, non «finito». È la correzione che conta: la
          // bilancia misura l'impedenza dopo il peso, e solo finché i piedi
          // sono sugli elettrodi. Mostrare «solo il peso» qui equivaleva a
          // dirgli di scendere un istante prima del dato che serviva.
          _emit(ScalePhase.holdStill, reading: pesata);
          // E si resta in ascolto: l'impedenza, se esiste, arriva dopo.
          codaTimer ??= Timer(bodyCompositionTimeout, () {
            _note('nessun’altra trama: chiudo con il solo peso');
            finish(
              _emit(
                ScalePhase.incomplete,
                reading: pesata,
                errorDetail: dettaglioFinale(),
              ),
            );
          });
        case RenphoStatusFrame(counter: final valore):
          if (valore != null) {
            contatoreIniziale ??= valore;
            contatoreCorrente = valore;
          }
          if (pesata == null) {
            _emit(ScalePhase.stepOn);
          }
        case RenphoUnknownFrame():
          if (pesata == null) {
            _emit(ScalePhase.stepOn);
          }
      }
    }

    _emit(ScalePhase.stepOn);
    final subscription = connection.incoming.listen(
      onFrame,
      onError: (Object error) {
        _note('errore dal collegamento: $error', isProblem: true);
        finish(_emit(ScalePhase.failed, errorDetail: '$error'));
      },
      onDone: () {
        if (session.isCompleted) {
          return;
        }
        final letta = pesata;
        if (letta != null) {
          _note('la bilancia si è scollegata: tengo la pesata che ho');
          finish(
            _emit(
              ScalePhase.incomplete,
              reading: letta,
              errorDetail: dettaglioFinale(),
            ),
          );
          return;
        }
        _note('la bilancia si è scollegata', isProblem: true);
        finish(
          _emit(
            ScalePhase.failed,
            errorDetail:
                'La bilancia si è scollegata prima di dare un peso stabile.',
          ),
        );
      },
      cancelOnError: false,
    );

    stepOnTimer = Timer(stepOnTimeout, () {
      finish(
        _emit(
          ScalePhase.failed,
          errorDetail:
              'Nessun peso stabile in ${stepOnTimeout.inSeconds} secondi.',
        ),
      );
    });

    try {
      return await session.future;
    } finally {
      stepOnTimer.cancel();
      codaTimer?.cancel();
      await subscription.cancel();
      await connection.close();
      _session = null;
    }
  }

  /// Non un dialogo: un **ascolto**.
  ///
  /// Quando il protocollo non si conosce non c'è niente da decodificare e non
  /// si deve fingere il contrario. Si registra e basta: ogni trama con la
  /// caratteristica da cui è arrivata e i byte in esadecimale. La bilancia di
  /// Marco parla `1a10`, un servizio che non sta nello standard e che nessuno
  /// ha pubblicato — le ipotesi sul formato costano un giro di pubblicazione
  /// ciascuna, i byte veri lo risolvono una volta sola.
  ///
  /// Non c'è nessuna scadenza breve: si ascolta per tutto il tempo di salita,
  /// perché più trame ci sono più il protocollo è ricostruibile. E l'esito è
  /// **buono** anche se non si è capito niente — la cattura è riuscita.
  Future<ScaleStatus> _converseCapture(ScaleConnection connection) async {
    final session = _session = Completer<ScaleStatus>();
    var trame = 0;
    _note(
      'protocollo sconosciuto: registro tutto quello che manda, '
      'senza interpretarlo',
    );

    Timer? ascolto;

    void finish(ScaleStatus status) {
      if (!session.isCompleted) {
        session.complete(status);
      }
    }

    // Le trame **distinte**, con quante volte ognuna si è ripetuta.
    //
    // Una bilancia che trasmette in continuo manda lo stesso peso decine di
    // volte mentre uno sta fermo: scritte tutte riempirebbero il registro di
    // righe identiche e caccerebbero fuori proprio le prime, che sono quelle
    // che dichiarano il protocollo. E per ricostruire un formato servono le
    // trame **diverse** fra loro — quante volte si ripetono è un'altra
    // informazione, che si conserva a parte invece di duplicare la riga.
    final viste = <String, int>{};

    final subscription = connection.incoming.listen(
      (frame) {
        trame++;
        final chiave = '${frame.label ?? '?'}:${gattHex(frame.bytes)}';
        final ripetizioni = (viste[chiave] ?? 0) + 1;
        viste[chiave] = ripetizioni;
        if (ripetizioni > 1) {
          // Già scritta. Si aggiorna solo il conteggio in schermata.
          _emit(ScalePhase.capturing);
          return;
        }
        _note(
          'da ${frame.label ?? 'caratteristica ignota'}: '
          '${frame.bytes.length} byte',
          hex: gattHex(frame.bytes),
        );
        _emit(ScalePhase.capturing);
      },
      onError: (Object error) {
        _note('errore dal collegamento: $error', isProblem: true);
      },
      onDone: () {
        // La bilancia che si scollega non interrompe niente: quello che ha
        // detto è già registrato, ed è tutto ciò che serviva.
        if (trame > 0) {
          _note('catturate $trame trame, ${viste.length} diverse fra loro');
        }
        finish(_emit(trame == 0 ? ScalePhase.failed : ScalePhase.captured));
      },
      cancelOnError: false,
    );

    _emit(ScalePhase.capturing);
    ascolto = Timer(stepOnTimeout, () {
      if (trame == 0) {
        finish(
          _emit(
            ScalePhase.failed,
            errorDetail:
                'La bilancia non ha mandato niente in '
                '${stepOnTimeout.inSeconds} secondi. Se il display si è '
                'acceso, forse aspetta un comando che non conosco: mandami '
                'comunque il registro, l’elenco dei servizi è già una pista.',
          ),
        );
        return;
      }
      _note('catturate $trame trame, ${viste.length} diverse fra loro');
      finish(_emit(ScalePhase.captured));
    });

    try {
      return await session.future;
    } finally {
      ascolto.cancel();
      await subscription.cancel();
      await connection.close();
      _session = null;
    }
  }

  /// Il dialogo con una bilancia che parla il profilo standard.
  ///
  /// È molto più corto dell'altro, e la ragione è che lo standard fa quasi
  /// tutto da sé: la bilancia manda una misura **solo quando ha finito**, con
  /// dentro tutto quello che ha. Non c'è nessuna trama «instabile» da
  /// scartare, quindi non c'è nessun momento in cui decidere se il peso si è
  /// assestato.
  ///
  /// Resta un caso da trattare: nel *Body Composition* il peso è un campo
  /// **opzionale**, e una bilancia può mandare l'impedenza in una trama e il
  /// peso in un'altra. Per questo i pezzi si accumulano invece di essere letti
  /// uno per uno, e si chiude quando c'è abbastanza per una pesata.
  Future<ScaleStatus> _converseGatt(
    ScaleConnection connection,
    ScaleDevice device,
  ) async {
    final session = _session = Completer<ScaleStatus>();
    final soloPeso = connection.kind == ScaleProtocolKind.gattWeight;
    _note(
      'protocollo standard del Bluetooth: '
      '${soloPeso ? 'solo peso' : 'peso e impedenza'}',
    );

    Timer? stepOnTimer;
    Timer? graceTimer;
    double? weightKg;
    double? impedanceOhm;
    // Tutte le trame della sessione, non solo l'ultima. Una misura spezzata su
    // due pacchetti — o un peso che arriva da una caratteristica e
    // un'impedenza dall'altra — è ricostruibile solo se si conservano
    // entrambi: tenere il solo pacchetto di coda avrebbe archiviato un grezzo
    // che il peso salvato non ce l'ha dentro, e sarebbe stata una bugia
    // rispetto a ciò che `rawPayloadHex` promette.
    final grezzo = <String>[];
    // Se l'impedenza può ancora arrivare da qualche parte. Su una bilancia che
    // espone il solo *Weight Scale* non arriverà mai, e concedere otto secondi
    // a un esito già deciso è solo tempo passato in piedi a fissare una rotella.
    final impedenzaPossibile =
        connection.kind == ScaleProtocolKind.gattBodyComposition;

    void finish(ScaleStatus status) {
      if (!session.isCompleted) {
        session.complete(status);
      }
    }

    ScaleReading? buildReading() {
      if (weightKg == null) {
        return null;
      }
      return ScaleReading(
        measuredAt: _clock().toUtc(),
        weightKg: weightKg!,
        deviceName: device.name,
        rawPayloadHex: grezzo.join(' | '),
        impedanceOhm: impedanceOhm,
      );
    }

    /// Chiude se c'è abbastanza per una pesata.
    ///
    /// La decisione si prende **sui pezzi raccolti**, mai sui flag della
    /// trama: il bit «misura spezzata» è acceso su entrambi i pacchetti, e
    /// usarlo come «aspetta il prossimo» significava non chiudere mai.
    void valuta() {
      final reading = buildReading();
      if (reading == null) {
        // Impedenza senza peso: capita, e non è un guasto. Il peso può
        // arrivare nel pacchetto dopo, o dall'altra caratteristica.
        _emit(ScalePhase.reading);
        return;
      }
      stepOnTimer?.cancel();
      if (reading.hasImpedance || !impedenzaPossibile) {
        graceTimer?.cancel();
        finish(
          _emit(
            reading.hasImpedance ? ScalePhase.ready : ScalePhase.incomplete,
            reading: reading,
          ),
        );
        return;
      }
      _emit(ScalePhase.reading, reading: reading);
      graceTimer ??= Timer(impedanceGrace, () {
        _note('impedenza non arrivata: chiudo con il solo peso');
        finish(_emit(ScalePhase.incomplete, reading: buildReading()));
      });
    }

    void onFrame(ScaleFrame incoming) {
      final frame = decodeGattFrame(
        incoming.bytes,
        characteristic: incoming.source == ScaleProtocolKind.gattWeight
            ? GattScaleCharacteristic.weight
            : GattScaleCharacteristic.bodyComposition,
      );
      if (frame == null) {
        _note(
          'trama vuota o illeggibile',
          hex: gattHex(incoming.bytes),
          isProblem: true,
        );
        return;
      }
      _note('$frame', hex: frame.hex);
      if (frame.failed) {
        // La bilancia dice che la pesata non è riuscita. È un esito suo, non
        // un guasto nostro, e insistere ad aspettare non porterebbe niente.
        stepOnTimer?.cancel();
        graceTimer?.cancel();
        finish(
          _emit(
            ScalePhase.failed,
            errorDetail:
                'La bilancia dichiara che la pesata non è riuscita. Succede '
                'quando ci si muove o si sale male: riprova stando fermo.',
          ),
        );
        return;
      }
      grezzo.add(frame.hex);
      if (frame.hasWeight) {
        weightKg = frame.weightKg;
      }
      if (frame.hasImpedance) {
        impedanceOhm = frame.impedanceOhm;
      }
      valuta();
    }

    _emit(ScalePhase.stepOn);
    final subscription = connection.incoming.listen(
      onFrame,
      onError: (Object error) {
        _note('errore dal collegamento: $error', isProblem: true);
        finish(_emit(ScalePhase.failed, errorDetail: '$error'));
      },
      onDone: () {
        if (!session.isCompleted) {
          // Una pesata parziale vale più del nulla: se il peso c'è, si chiude
          // con quello invece di buttare via la salita.
          final reading = buildReading();
          if (reading != null) {
            _note('collegamento chiuso: tengo la pesata che ho');
            finish(_emit(ScalePhase.incomplete, reading: reading));
            return;
          }
          _note('la bilancia si è scollegata', isProblem: true);
          finish(
            _emit(
              ScalePhase.failed,
              errorDetail:
                  'La bilancia si è scollegata prima di mandare una misura.',
            ),
          );
        }
      },
      cancelOnError: false,
    );

    stepOnTimer = Timer(stepOnTimeout, () {
      finish(
        _emit(
          ScalePhase.failed,
          errorDetail:
              'Nessuna misura in ${stepOnTimeout.inSeconds} secondi. Con il '
              'protocollo standard la bilancia manda tutto insieme a fine '
              'pesata: resta fermo finché il peso non si ferma sul display.',
        ),
      );
    });

    try {
      return await session.future;
    } finally {
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
