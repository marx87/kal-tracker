/// Chi è Marco **come atleta**: cosa ha in casa, cosa gli fa male, quanto può
/// allenarsi.
///
/// I `name` degli enum che finiscono su disco sono esattamente i valori
/// ammessi dai CHECK di `training_profiles` e `training_limitations`.
/// Dove il valore su disco contiene un trattino basso (`spalla_dx`) il `name`
/// non basta — il linter non vuole identificatori con l'underscore — e allora
/// c'è un campo [BodyPart.storage] esplicito. Cambiarne uno significa rompere
/// il database, non rinominare un'etichetta.
library;

import 'package:flutter/foundation.dart';

/// L'attrezzatura disponibile. La colonna `equipment` è una lista separata da
/// virgole: questi sono i suoi elementi ammessi, e `name` è ciò che si scrive.
enum Equipment {
  manubri('Manubri'),
  bilanciere('Bilanciere'),
  pancaRegolabile('Panca regolabile'),

  /// Anelli chiusi, senza maniglie: si calzano su cosce o braccia e la
  /// resistenza si scarica sul corpo stesso.
  elasticiAdAnello('Elastici ad anello'),

  /// Elastici con maniglie, da fissare a una porta o a un gancio.
  ///
  /// **La distinzione dagli anelli non è pignoleria.** Un push-down tricipiti
  /// è una spinta verso il basso contro una resistenza che arriva dall'alto:
  /// senza un punto sopra la testa a cui agganciare l'elastico quel movimento
  /// non esiste, e nessuna variante lo sostituisce. Lo stesso vale per lat
  /// machine, face pull e pallof press. Con una voce «elastici» sola l'app
  /// avrebbe proposto a Marco esercizi che in casa sua non può fare — che è
  /// esattamente ciò che questo profilo esiste per evitare.
  elasticiAncorabili('Elastici ancorabili'),
  tappetino('Tappetino'),
  sbarraTrazioni('Sbarra per trazioni'),
  kettlebell('Kettlebell'),

  /// Il corpo e basta. È una voce come le altre perché il profilo di chi non
  /// ha niente deve poter dire «ho scelto», non restare vuoto: la lista vuota
  /// significa «non ho ancora risposto», ed è un'altra cosa.
  corpoLibero('Corpo libero');

  const Equipment(this.label);

  final String label;

  static Equipment? fromStorage(String? value) {
    for (final item in Equipment.values) {
      if (item.name == value) {
        return item;
      }
    }
    return null;
  }

  /// Legge la colonna. Un elemento che non conosciamo viene lasciato cadere:
  /// arriverebbe da una versione futura dell'app via sincronizzazione, e
  /// tradurlo a caso in un attrezzo che c'è sarebbe peggio che ignorarlo.
  static Set<Equipment> parse(String? stored) {
    final result = <Equipment>{};
    for (final token in (stored ?? '').split(',')) {
      final item = fromStorage(token.trim());
      if (item != null) {
        result.add(item);
      }
    }
    return result;
  }

  /// Scrive la colonna sempre nell'ordine dell'enum: due profili con gli
  /// stessi attrezzi devono produrre la stessa stringa, altrimenti la
  /// sincronizzazione vede una modifica dove non c'è.
  static String encode(Iterable<Equipment> items) {
    final unique = items.toSet();
    return Equipment.values
        .where(unique.contains)
        .map((item) => item.name)
        .join(',');
  }
}

/// Il lato del corpo. `centrale` non è un ripiego: collo, costole e lombari
/// non hanno un destro e un sinistro da distinguere.
enum BodySide { destro, sinistro, centrale }

/// L'articolazione **senza lato**.
///
/// Serve allo screening: un esercizio carica «la spalla», non «la spalla
/// destra» — è il corpo di Marco ad avere un lato che fa male. Tenere le due
/// cose separate evita di dover scrivere la mappa degli esercizi due volte,
/// una per lato.
enum JointArea {
  spalla('Spalla'),
  gomito('Gomito'),
  polso('Polso'),
  collo('Collo'),
  costole('Costole'),
  lombari('Zona lombare'),
  anca('Anca'),
  ginocchio('Ginocchio'),
  caviglia('Caviglia');

  const JointArea(this.label);

  final String label;
}

/// La zona che al momento limita: è il valore che sta su disco, lato incluso.
enum BodyPart {
  spallaDx('spalla_dx', 'Spalla destra', JointArea.spalla, BodySide.destro),
  spallaSx('spalla_sx', 'Spalla sinistra', JointArea.spalla, BodySide.sinistro),
  gomitoDx('gomito_dx', 'Gomito destro', JointArea.gomito, BodySide.destro),
  gomitoSx('gomito_sx', 'Gomito sinistro', JointArea.gomito, BodySide.sinistro),
  polsoDx('polso_dx', 'Polso destro', JointArea.polso, BodySide.destro),
  polsoSx('polso_sx', 'Polso sinistro', JointArea.polso, BodySide.sinistro),
  collo('collo', 'Collo', JointArea.collo, BodySide.centrale),
  costole('costole', 'Costole', JointArea.costole, BodySide.centrale),
  lombari('lombari', 'Zona lombare', JointArea.lombari, BodySide.centrale),
  ancaDx('anca_dx', 'Anca destra', JointArea.anca, BodySide.destro),
  ancaSx('anca_sx', 'Anca sinistra', JointArea.anca, BodySide.sinistro),
  ginocchioDx(
    'ginocchio_dx',
    'Ginocchio destro',
    JointArea.ginocchio,
    BodySide.destro,
  ),
  ginocchioSx(
    'ginocchio_sx',
    'Ginocchio sinistro',
    JointArea.ginocchio,
    BodySide.sinistro,
  ),
  cavigliaDx(
    'caviglia_dx',
    'Caviglia destra',
    JointArea.caviglia,
    BodySide.destro,
  ),
  cavigliaSx(
    'caviglia_sx',
    'Caviglia sinistra',
    JointArea.caviglia,
    BodySide.sinistro,
  );

  const BodyPart(this.storage, this.label, this.area, this.side);

  /// Il valore nella colonna `body_part`, vincolato dal CHECK.
  final String storage;

  final String label;
  final JointArea area;
  final BodySide side;

  /// Nulla quando il valore non è dei nostri. Il CHECK del database lo rende
  /// impossibile, ma la sincronizzazione può portare una zona che questa
  /// versione dell'app non conosce: chi legge la conta e lo dichiara (vedi
  /// [TrainingProfile.unreadableLimitations]) invece di far finta di niente.
  static BodyPart? fromStorage(String? value) {
    for (final part in BodyPart.values) {
      if (part.storage == value) {
        return part;
      }
    }
    return null;
  }
}

/// Quanto pesa una limitazione. L'ordine dell'enum è la gravità crescente:
/// [rank] lo usa lo screening per far vincere la peggiore quando due
/// limitazioni toccano lo stesso esercizio.
enum LimitationSeverity {
  fastidio('Fastidio', 'Si può fare, ma con un\'alternativa pronta.'),
  dolore('Dolore', 'Fuori quando è quell\'articolazione a fare il movimento.'),
  stop('Stop', 'Fuori tutto quello che la carica, anche di striscio.');

  const LimitationSeverity(this.label, this.description);

  final String label;
  final String description;

  int get rank => index;

  bool isAtLeast(LimitationSeverity other) => rank >= other.rank;

  static LimitationSeverity? fromStorage(String? value) {
    for (final severity in LimitationSeverity.values) {
      if (severity.name == value) {
        return severity;
      }
    }
    return null;
  }
}

/// Cosa fare quando il semaforo del sovrallenamento chiede uno scarico.
///
/// `suggerito` è il valore di partenza, e non è un caso: l'app propone, Marco
/// conferma. `automatico` esiste perché è Marco a poterlo scegliere — non è
/// un default che gli capita addosso.
enum DeloadPreference {
  suggerito('Chiedimelo prima', 'L\'app propone lo scarico, decidi tu.'),
  automatico('Applicalo da solo', 'L\'app alleggerisce la settimana da sé.');

  const DeloadPreference(this.label, this.description);

  final String label;
  final String description;

  static DeloadPreference fromStorage(String? value) {
    for (final preference in DeloadPreference.values) {
      if (preference.name == value) {
        return preference;
      }
    }
    // Il default della colonna, e il default del prodotto: nel dubbio si
    // chiede.
    return DeloadPreference.suggerito;
  }
}

/// I giorni preferiti, come stanno nella colonna `preferred_days`.
enum TrainingDay {
  lun('Lunedì', DateTime.monday),
  mar('Martedì', DateTime.tuesday),
  mer('Mercoledì', DateTime.wednesday),
  gio('Giovedì', DateTime.thursday),
  ven('Venerdì', DateTime.friday),
  sab('Sabato', DateTime.saturday),
  dom('Domenica', DateTime.sunday);

  const TrainingDay(this.label, this.weekday);

  final String label;

  /// Il numero di `DateTime.weekday`, così chi pianifica non deve rifare la
  /// corrispondenza a mano.
  final int weekday;

  static TrainingDay? fromStorage(String? value) {
    for (final day in TrainingDay.values) {
      if (day.name == value) {
        return day;
      }
    }
    return null;
  }

  static List<TrainingDay> parse(String? stored) {
    final result = <TrainingDay>{};
    for (final token in (stored ?? '').split(',')) {
      final day = fromStorage(token.trim().toLowerCase());
      if (day != null) {
        result.add(day);
      }
    }
    // Sempre in ordine di settimana: «mer,lun» e «lun,mer» sono lo stesso
    // piano, e devono produrre la stessa riga.
    return TrainingDay.values.where(result.contains).toList(growable: false);
  }

  static String encode(Iterable<TrainingDay> days) {
    final unique = days.toSet();
    return TrainingDay.values
        .where(unique.contains)
        .map((day) => day.name)
        .join(',');
  }
}

/// Una parte del corpo che al momento limita cosa si può fare.
///
/// **Nessuna scadenza automatica**: [resolvedAt] si valorizza quando Marco
/// chiude la limitazione, non quando è passato abbastanza tempo. Un'app che
/// «guarisce» una spalla per conto suo è un'app che prescrive male.
@immutable
class TrainingLimitation {
  const TrainingLimitation({
    required this.id,
    required this.bodyPart,
    required this.severity,
    required this.startedAt,
    this.note,
    this.resolvedAt,
  });

  final String id;
  final BodyPart bodyPart;
  final LimitationSeverity severity;

  /// Cosa è successo, con parole di Marco: «rotazione esterna sopra i 90°».
  final String? note;

  final DateTime startedAt;
  final DateTime? resolvedAt;

  /// Solo le aperte filtrano qualcosa. Una limitazione chiusa resta nello
  /// storico — serve a spiegare perché tre mesi fa la scheda era quella — ma
  /// non toglie più niente dal catalogo.
  bool get isActive => resolvedAt == null;

  TrainingLimitation copyWith({
    BodyPart? bodyPart,
    LimitationSeverity? severity,
    String? note,
    DateTime? startedAt,
    DateTime? resolvedAt,
    bool clearNote = false,
    bool clearResolvedAt = false,
  }) => TrainingLimitation(
    id: id,
    bodyPart: bodyPart ?? this.bodyPart,
    severity: severity ?? this.severity,
    note: clearNote ? null : (note ?? this.note),
    startedAt: startedAt ?? this.startedAt,
    resolvedAt: clearResolvedAt ? null : (resolvedAt ?? this.resolvedAt),
  );
}

/// Il profilo di allenamento: attrezzatura, disponibilità e limitazioni.
@immutable
class TrainingProfile {
  const TrainingProfile({
    required this.profileId,
    this.equipment = const {},
    this.sessionsPerWeek,
    this.minutesPerSession,
    this.preferredDays = const [],
    this.deloadPreference = DeloadPreference.suggerito,
    this.limitations = const [],
    this.unreadableLimitations = 0,
  });

  /// Il profilo di chi non ha ancora risposto a niente.
  ///
  /// Esiste perché la riga di `training_profiles` può mancare mentre le
  /// limitazioni ci sono già: la tabella delle limitazioni pende da
  /// `app_profiles`, non da questa. Chi legge deve poter dire «nessuna
  /// attrezzatura dichiarata» senza inventarsi una riga sul database.
  const TrainingProfile.empty(this.profileId)
    : equipment = const {},
      sessionsPerWeek = null,
      minutesPerSession = null,
      preferredDays = const [],
      deloadPreference = DeloadPreference.suggerito,
      limitations = const [],
      unreadableLimitations = 0;

  final String profileId;
  final Set<Equipment> equipment;
  final int? sessionsPerWeek;
  final int? minutesPerSession;
  final List<TrainingDay> preferredDays;
  final DeloadPreference deloadPreference;

  /// Tutte, aperte e chiuse, dalla più recente.
  final List<TrainingLimitation> limitations;

  /// Quante righe di limitazione questa versione dell'app non ha saputo
  /// leggere. Non è un contatore per curiosi: se è maggiore di zero lo
  /// screening sta filtrando con meno informazioni di quante ce ne sono, e
  /// va detto invece che nascosto.
  final int unreadableLimitations;

  bool has(Equipment item) => equipment.contains(item);

  List<TrainingLimitation> get activeLimitations => limitations
      .where((limitation) => limitation.isActive)
      .toList(growable: false);

  /// Le limitazioni aperte su un'articolazione, senza distinzione di lato:
  /// una spalla destra ferma toglie la shoulder press, che si fa con due.
  List<TrainingLimitation> activeFor(JointArea area) => limitations
      .where(
        (limitation) => limitation.isActive && limitation.bodyPart.area == area,
      )
      .toList(growable: false);

  /// La gravità peggiore aperta su quell'articolazione, o nulla se è libera.
  LimitationSeverity? severityFor(JointArea area) {
    LimitationSeverity? worst;
    for (final limitation in activeFor(area)) {
      if (worst == null || limitation.severity.rank > worst.rank) {
        worst = limitation.severity;
      }
    }
    return worst;
  }

  /// Vero quando Marco ha dichiarato almeno un attrezzo.
  ///
  /// **La lista vuota non è «non ho niente»**: è «non ho ancora risposto», e
  /// lo screening la tratta come silenzio invece che come un no — altrimenti
  /// il primo avvio dell'app escluderebbe l'intero catalogo.
  bool get hasDeclaredEquipment => equipment.isNotEmpty;

  TrainingProfile copyWith({
    Set<Equipment>? equipment,
    int? sessionsPerWeek,
    int? minutesPerSession,
    List<TrainingDay>? preferredDays,
    DeloadPreference? deloadPreference,
    List<TrainingLimitation>? limitations,
    int? unreadableLimitations,
    bool clearSessionsPerWeek = false,
    bool clearMinutesPerSession = false,
  }) => TrainingProfile(
    profileId: profileId,
    equipment: equipment ?? this.equipment,
    sessionsPerWeek: clearSessionsPerWeek
        ? null
        : (sessionsPerWeek ?? this.sessionsPerWeek),
    minutesPerSession: clearMinutesPerSession
        ? null
        : (minutesPerSession ?? this.minutesPerSession),
    preferredDays: preferredDays ?? this.preferredDays,
    deloadPreference: deloadPreference ?? this.deloadPreference,
    limitations: limitations ?? this.limitations,
    unreadableLimitations: unreadableLimitations ?? this.unreadableLimitations,
  );
}
