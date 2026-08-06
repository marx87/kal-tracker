import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/scale_log.dart';

/// Quello che la bilancia ha davvero prodotto: peso, impedenza e la trama
/// grezza. Nessuna percentuale — quelle le calcola la formula, dopo.
@immutable
class ScaleReading {
  const ScaleReading({
    required this.measuredAt,
    required this.weightKg,
    required this.deviceName,
    required this.rawPayloadHex,
    this.impedanceOhm,
    this.secondaryOhm,
  });

  /// Istante in UTC.
  final DateTime measuredAt;

  final double weightKg;

  /// Il nome con cui la bilancia si è annunciata («QN-Scale»): finisce in
  /// `device_model` e servirà il giorno in cui le bilance saranno due, o
  /// durante la taratura in doppia lettura.
  final String deviceName;

  /// La trama che ha prodotto questa lettura, in esadecimale. Si conserva
  /// perché la decodifica di oggi potrebbe non essere quella definitiva.
  final String rawPayloadHex;

  /// Resistenza di corpo intero. **Nulla quando gli elettrodi non hanno fatto
  /// contatto**: in quel caso la bilancia ha pesato e basta, e questa pesata
  /// entra nelle medie del peso ma non in quelle della composizione.
  final double? impedanceOhm;

  /// La seconda resistenza mandata dalla bilancia, di cui non si conosce la
  /// frequenza. Non si salva in una colonna: resta in [rawPayloadHex].
  final double? secondaryOhm;

  bool get hasImpedance => impedanceOhm != null && impedanceOhm! > 0;
}

/// Il tono con cui la schermata deve dire quello che sta succedendo. Il
/// dominio decide il significato, la presentazione sceglie il colore.
enum ScaleTone { working, good, warning, critical }

/// Dove siamo arrivati.
///
/// Gli stati sono tanti di proposito: «non funziona» è la risposta peggiore
/// che si possa dare a chi è in piedi in bagno alle sette del mattino. Ogni
/// modo di fallire ha un nome, una spiegazione e — quando esiste — la mossa
/// che lo risolve.
enum ScalePhase {
  /// Prima di cominciare.
  idle(
    'Pesata dalla bilancia',
    // Terza stesura di questa riga, e stavolta dalla bocca di chi la usa: la
    // bilancia **si annuncia soltanto mentre misura**. Non è «spenta e da
    // svegliare» — appena scendi smette di esistere per il Bluetooth, ed è per
    // questo che una scansione fatta a bilancia libera non trovava niente per
    // quanto durasse.
    'Tocca «Cerca» e sali subito sulla bilancia, restandoci sopra: si fa '
        'vedere solo mentre pesa.',
    ScaleTone.working,
  ),

  checkingRadio(
    'Controllo il Bluetooth',
    'Un attimo: guardo se la radio è accesa e se ho il permesso.',
    ScaleTone.working,
  ),

  radioOff(
    'Bluetooth spento',
    'La bilancia parla solo via Bluetooth. Accendilo e riprova.',
    ScaleTone.warning,
  ),

  permissionDenied(
    'Permesso negato',
    'Android chiede il permesso «Dispositivi nelle vicinanze» per cercare '
        'la bilancia. Concedilo dalle impostazioni dell’app e riprova.',
    ScaleTone.warning,
  ),

  unsupported(
    'Bluetooth non disponibile',
    'Questo dispositivo non espone il Bluetooth Low Energy: la pesata resta '
        'da inserire a mano.',
    ScaleTone.critical,
  ),

  scanning(
    'Cerco la bilancia',
    'Sali ora e resta fermo. Se compare qui sotto prima che la riconosca, '
        'toccala pure: faccio da lì.',
    ScaleTone.working,
  ),

  /// La scansione ha visto dei dispositivi ma nessuno si dichiara bilancia.
  ///
  /// **È l'esito più utile che ci sia**, e prima non esisteva: si diceva «non
  /// trovata» anche quando la bilancia era lì, semplicemente sotto un nome che
  /// non conoscevamo o senza dichiarare i suoi servizi. Riconoscere un
  /// dispositivo BLE dall'annuncio è un'euristica, e un'euristica sbagliata non
  /// deve poter chiudere la strada: se non ci arrivo io, sceglie Marco — che
  /// la bilancia ce l'ha sotto i piedi e sa benissimo qual è.
  chooseDevice(
    'Quale di questi è la bilancia?',
    'Non l’ho riconosciuta da sola. Tocca quello giusto: me lo ricordo e da '
        'domani ci vado dritto.',
    ScaleTone.warning,
  ),

  notFound(
    'Nessun dispositivo nel raggio',
    // Niente «controlla che il Bluetooth sia acceso»: qui ci si arriva solo
    // dopo che la radio è risultata accesa, quindi sarebbe un consiglio già
    // smentito da noi stessi. Quello che resta davvero da controllare è
    // l'altra app.
    'Non ho visto niente, nemmeno i vicini: succede quando l’app Renpho è '
        'aperta e tiene lei il collegamento — mentre ce l’ha, la bilancia non '
        'parla con nessun altro. Chiudila del tutto e riprova.',
    ScaleTone.warning,
  ),

  connecting(
    'Mi collego',
    'Trovata. Sto aprendo il collegamento.',
    ScaleTone.working,
  ),

  handshake(
    'Ci stiamo capendo',
    'Scambio di presentazioni: le dico che lavoriamo in chilogrammi.',
    ScaleTone.working,
  ),

  stepOn(
    'Sali sulla bilancia',
    'A piedi nudi e asciutti, fermo, con tutti e quattro gli angoli sotto i '
        'piedi. L’impedenza passa dalla pianta: con le calze non si legge.',
    ScaleTone.working,
  ),

  reading(
    'Sto leggendo',
    'Il peso si sta assestando. Resta fermo ancora un momento.',
    ScaleTone.working,
  ),

  /// Il caso reale: peso sì, impedenza no.
  incomplete(
    'Solo il peso',
    'La bilancia ha pesato ma non è riuscita a leggere l’impedenza: succede '
        'con i piedi asciutti o le calze. Il peso vale ed entra nelle medie, '
        'la composizione no.',
    ScaleTone.warning,
  ),

  /// Lettura completa: si può salvare.
  ready(
    'Pesata completa',
    'Peso e impedenza letti. Controlla e salva.',
    ScaleTone.good,
  ),

  saved('Pesata salvata', 'È nello storico e nelle medie.', ScaleTone.good),

  failed(
    'Lettura interrotta',
    'Qualcosa si è messo di mezzo. Il registro qui sotto dice cosa.',
    ScaleTone.critical,
  );

  const ScalePhase(this.title, this.detail, this.tone);

  final String title;
  final String detail;
  final ScaleTone tone;

  /// Vero quando non c'è più niente da aspettare: o si salva, o si riprova.
  bool get isFinal => switch (this) {
    ScalePhase.radioOff ||
    ScalePhase.permissionDenied ||
    ScalePhase.unsupported ||
    ScalePhase.notFound ||
    ScalePhase.chooseDevice ||
    ScalePhase.incomplete ||
    ScalePhase.ready ||
    ScalePhase.saved ||
    ScalePhase.failed => true,
    _ => false,
  };

  /// Vero quando riprovare ha senso. Su `unsupported` non ce l'ha: il
  /// Bluetooth non compare riprovando.
  bool get canRetry => isFinal && this != ScalePhase.unsupported;

  /// Vero quando c'è una pesata da salvare.
  bool get hasReading =>
      this == ScalePhase.ready || this == ScalePhase.incomplete;

  /// Vero quando l'elenco dei dispositivi è in schermata e sceglierne uno ha
  /// un senso.
  ///
  /// Sta qui, e non nella schermata, perché **due posti che decidono la stessa
  /// cosa prima o poi decidono cose diverse**. Quando la regola era scritta
  /// due volte, l'elenco si disegnava in tre fasi e il controllore ne
  /// riconosceva una sola: due tocchi ravvicinati passavano entrambi e
  /// aprivano due collegamenti sulla stessa bilancia — che sulla Renpho, che
  /// ne accetta uno solo, fa fallire anche il primo.
  bool get canChooseDevice =>
      this == ScalePhase.scanning ||
      this == ScalePhase.chooseDevice ||
      this == ScalePhase.failed;
}

/// Lo stato completo della sessione: la fase, quello che si è letto e il
/// registro di bordo.
@immutable
class ScaleStatus {
  const ScaleStatus({
    required this.phase,
    this.reading,
    this.errorDetail,
    this.log = const <ScaleLogEntry>[],
    this.candidates = const <ScaleDevice>[],
  });

  const ScaleStatus.idle() : this(phase: ScalePhase.idle);

  final ScalePhase phase;

  /// Presente da [ScalePhase.incomplete] in poi.
  final ScaleReading? reading;

  /// Il dettaglio tecnico di un guasto, in aggiunta alla spiegazione della
  /// fase: il testo del `FlutterBluePlusException`, il timeout scaduto. Va
  /// mostrato, non nascosto — è quello che permette di capire cosa fare.
  final String? errorDetail;

  final List<ScaleLogEntry> log;

  /// I dispositivi visti finora, i più promettenti per primi.
  ///
  /// Si aggiorna **durante** la scansione e non solo alla fine, ed è
  /// deliberato: la bilancia compare nell'istante in cui Marco ci sale, e
  /// mentre lui è già in piedi lì sopra deve poterla toccare subito, senza
  /// aspettare che scadano trenta secondi di ricerca.
  final List<ScaleDevice> candidates;

  String get title => phase.title;

  String get detail => phase.detail;

  /// Vero mentre c'è qualcosa in corso. `idle` non è «in corso»: è il momento
  /// prima, quello in cui si mostra il pulsante invece della rotella.
  bool get isBusy => !phase.isFinal && phase != ScalePhase.idle;

  ScaleStatus copyWith({
    ScalePhase? phase,
    ScaleReading? reading,
    String? errorDetail,
    List<ScaleLogEntry>? log,
    List<ScaleDevice>? candidates,
  }) => ScaleStatus(
    phase: phase ?? this.phase,
    reading: reading ?? this.reading,
    errorDetail: errorDetail ?? this.errorDetail,
    log: log ?? this.log,
    candidates: candidates ?? this.candidates,
  );
}
