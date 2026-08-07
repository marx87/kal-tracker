/// Quante serie a settimana ha ricevuto ogni gruppo muscolare.
///
/// La domanda che l'ha fatta nascere è concreta: l'obiettivo dichiarato sono
/// braccia, spalle e addome, ma con una spalla limitata e mezza scheda
/// sostituita un gruppo può essersi svuotato senza che nessuna schermata lo
/// dica. Contare le serie però è solo metà della risposta — dodici serie sono
/// tante o poche a seconda di cosa si sta facendo.
///
/// Per questo il riferimento è una BANDA e non un numero da centrare: è la
/// stessa filosofia di `MaintenanceBand` sul peso. Dentro la banda non c'è
/// niente da correggere, e in deficit la lente giusta è il mantenimento (vedi
/// [VolumeIntent]).
///
/// Niente Flutter e niente database: qui si contano righe già lette.
library;

import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// La banda di volume: **non un numero, un intervallo**.
///
/// Sotto si perde terreno, sopra si spende recupero che in deficit non c'è.
/// In mezzo — che è larga apposta — non succede niente.
class WeeklyVolumeBand {
  const WeeklyVolumeBand({required this.lowSets, required this.highSets});

  /// Estremi INCLUSI: dieci serie sono già dentro la banda della crescita,
  /// non un soffio sotto. Un confine esclusivo trasformerebbe la banda nel
  /// bersaglio che non deve essere.
  final int lowSets;
  final int highSets;

  VolumeBandStatus statusOf(int sets) {
    if (sets < lowSets) {
      return VolumeBandStatus.below;
    }
    if (sets > highSets) {
      return VolumeBandStatus.above;
    }
    return VolumeBandStatus.inside;
  }

  /// Come si scrive: «10 – 20 serie».
  String get label => '$lowSets – $highSets serie';
}

enum VolumeBandStatus {
  inside(label: 'Dentro la banda'),
  above(label: 'Sopra la banda'),
  below(label: 'Sotto la banda'),

  /// Nessuna banda su questo gruppo: le serie si contano ma non si giudicano.
  unbanded(label: 'Senza banda');

  const VolumeBandStatus({required this.label});

  final String label;
}

/// Con che lente si legge la banda.
///
/// **In deficit la lente giusta è [maintenance]**, e non è un ripiego: con le
/// calorie sotto il pareggio il muscolo non cresce, si difende. Leggere la
/// banda della crescita mentre si dimagrisce vuol dire vedere «sotto»
/// dappertutto e aggiungere serie che il recupero non regge.
enum VolumeIntent {
  growth(label: 'Crescita', band: WeeklyVolumeBand(lowSets: 10, highSets: 20)),

  /// Circa metà del volume della crescita: per NON perdere basta molto meno
  /// che per guadagnare, ed è la parte di verità che rende la banda
  /// sopportabile in deficit.
  maintenance(
    label: 'Mantenimento',
    band: WeeklyVolumeBand(lowSets: 6, highSets: 10),
  );

  const VolumeIntent({required this.label, required this.band});

  final String label;
  final WeeklyVolumeBand band;

  /// La frase da mettere accanto al numero. Descrive, non rimprovera: sotto
  /// la banda si dice cosa succede al gruppo, non cosa Marco ha sbagliato.
  String readingOf(VolumeBandStatus status) => switch (status) {
    VolumeBandStatus.unbanded =>
      'Queste serie si contano ma non si misurano con la banda.',
    VolumeBandStatus.inside => switch (this) {
      VolumeIntent.growth => 'Dentro la banda della crescita.',
      VolumeIntent.maintenance => 'Dentro la banda del mantenimento.',
    },
    VolumeBandStatus.below => switch (this) {
      VolumeIntent.growth =>
        'Sotto la banda della crescita: con questo volume il gruppo si '
            'mantiene, non cresce.',
      VolumeIntent.maintenance =>
        'Sotto anche per il mantenimento: qui il gruppo perde terreno.',
    },
    VolumeBandStatus.above => switch (this) {
      VolumeIntent.growth =>
        'Sopra la banda della crescita: tanto volume, guarda il recupero.',
      VolumeIntent.maintenance =>
        'Sopra la banda del mantenimento. In deficit non è un traguardo da '
            'riempire: se il recupero regge va bene così.',
    },
  };
}

/// I gruppi su cui la banda ha senso.
///
/// Fuori restano cardio, mobilità, full body e «altro»: le loro serie
/// esistono e si mostrano, ma «quindici serie di mobilità» non si legge come
/// «quindici serie di spalle», e dare loro una banda inviterebbe a riempirla.
const Set<MuscleGroup> bandedMuscleGroups = {
  MuscleGroup.petto,
  MuscleGroup.schiena,
  MuscleGroup.spalle,
  MuscleGroup.bicipiti,
  MuscleGroup.tricipiti,
  MuscleGroup.gambe,
  MuscleGroup.polpacci,
  MuscleGroup.addome,
};

/// Un gruppo muscolare e la sua settimana.
class MuscleGroupVolume {
  const MuscleGroupVolume({
    required this.group,
    required this.sets,
    required this.sessions,
    required this.band,
    required this.status,
  });

  final MuscleGroup group;

  /// Serie allenanti COMPLETATE nella settimana. Riscaldamento e defaticamento
  /// non ci sono: vedi [WeeklyMuscleVolume.warmupAndCooldownSets].
  final int sets;

  /// In quante sessioni distinte sono arrivate. Dieci serie in un giorno solo
  /// e dieci spalmate su tre allenamenti sono lo stesso numero e due
  /// settimane diverse, quindi il numero da solo non basta.
  final int sessions;

  /// Null sui gruppi che la banda non giudica ([bandedMuscleGroups]).
  final WeeklyVolumeBand? band;

  final VolumeBandStatus status;

  bool get isBanded => band != null;

  /// Il gruppo non ha ricevuto niente: è la risposta secca alla domanda «le
  /// esclusioni lo hanno svuotato?».
  bool get isEmpty => sets == 0;
}

/// La settimana: sette giorni civili romani, un conteggio per gruppo e quello
/// che è rimasto fuori.
class WeeklyMuscleVolume {
  const WeeklyMuscleVolume({
    required this.firstDay,
    required this.lastDay,
    required this.intent,
    required this.groups,
    required this.focus,
    required this.sessions,
    required this.setsWithoutMuscleGroup,
    required this.warmupAndCooldownSets,
  });

  /// Etichette di giorno (`DateTime.utc` a mezzanotte, come [bodyDayOf]), non
  /// istanti: [lastDay] è l'ultimo giorno INCLUSO.
  final DateTime firstDay;
  final DateTime lastDay;

  final VolumeIntent intent;

  /// In ordine di catalogo, non per numero di serie: la posizione di un
  /// gruppo nella lista non deve cambiare da una settimana all'altra, o
  /// leggerla diventa un esercizio di ricerca. I gruppi con banda ci sono
  /// SEMPRE, anche a zero — è il caso che conta di più; quelli senza banda
  /// solo se hanno ricevuto qualcosa.
  final List<MuscleGroupVolume> groups;

  /// I gruppi che Marco ha dichiarato obiettivo. Non cambiano il conteggio,
  /// decidono solo cosa si guarda per primo: la scelta di quali siano è di
  /// chi chiama, non di questa funzione.
  final Set<MuscleGroup> focus;

  /// Sessioni che hanno portato almeno una serie contata.
  final int sessions;

  /// Serie completate su righe SENZA gruppo congelato: non stanno in nessun
  /// gruppo. Tacerlo farebbe sembrare vuoto un gruppo che invece è stato
  /// allenato da una riga a cui manca lo scatto del catalogo.
  final int setsWithoutMuscleGroup;

  /// Riscaldamento e defaticamento, esclusi per regola. Sono lavoro vero ma
  /// non sono stimolo, e sommarli gonfierebbe ogni gruppo di qualche serie.
  final int warmupAndCooldownSets;

  /// Le serie effettivamente attribuite a un gruppo.
  int get totalSets =>
      groups.fold<int>(0, (total, entry) => total + entry.sets);

  MuscleGroupVolume? forGroup(MuscleGroup group) {
    for (final entry in groups) {
      if (entry.group == group) {
        return entry;
      }
    }
    return null;
  }

  /// I gruppi dell'obiettivo, nell'ordine della lista.
  List<MuscleGroupVolume> get focusGroups => [
    for (final entry in groups)
      if (focus.contains(entry.group)) entry,
  ];

  /// I gruppi con POCHE serie: quelli a zero non ci sono, stanno solo in
  /// [emptyBandedGroups]. Lo stato resta `below` anche a zero — la banda non
  /// mente — ma le due liste si leggono di fila nella stessa card, e un
  /// gruppo in tutt'e due farebbe nominare due volte le spalle.
  List<MuscleGroupVolume> get belowBand => [
    for (final entry in groups)
      if (entry.status == VolumeBandStatus.below && !entry.isEmpty) entry,
  ];

  /// I gruppi con banda rimasti a zero. Sono DISGIUNTI da [belowBand] — un
  /// gruppo vuoto sta qui e in nessun altro posto — perché «poche serie» e
  /// «nessuna serie» hanno cause diverse: la seconda di solito è un esercizio
  /// saltato o escluso, non una scheda leggera.
  List<MuscleGroupVolume> get emptyBandedGroups => [
    for (final entry in groups)
      if (entry.isBanded && entry.isEmpty) entry,
  ];

  /// C'è qualcosa da dichiarare accanto ai numeri.
  bool get hasExclusions =>
      setsWithoutMuscleGroup > 0 || warmupAndCooldownSets > 0;
}

/// Conta le serie della settimana che comincia nel giorno di [weekStart].
///
/// La finestra è di sette giorni CIVILI romani e si confrontano etichette di
/// giorno, non istanti: sull'istante il cambio d'ora sposterebbe il confine
/// di un'ora e la sessione del lunedì alle 00:30 finirebbe nella settimana
/// prima. La sessione si assegna al giorno in cui è INIZIATA, che è l'unica
/// data che il modello ha (le singole serie non portano un'ora propria).
///
/// Le sessioni ancora aperte contribuiscono con le serie già spuntate: qui
/// l'unità è la serie, non la sessione, e una serie fatta un'ora fa è stimolo
/// ricevuto anche se l'allenamento non è stato chiuso. È di proposito diverso
/// da `aggregateHistory`, che somma sessioni e quindi le vuole finite.
WeeklyMuscleVolume weeklyMuscleVolume({
  required List<Workout> workouts,
  required DateTime weekStart,
  required VolumeIntent intent,
  Set<MuscleGroup> focus = const <MuscleGroup>{},
}) {
  final firstDay = bodyDayOf(weekStart);
  final lastDay = firstDay.add(const Duration(days: 6));

  final setsByGroup = <MuscleGroup, int>{};
  final sessionsByGroup = <MuscleGroup, Set<String>>{};
  final contributingSessions = <String>{};
  var setsWithoutMuscleGroup = 0;
  var warmupAndCooldownSets = 0;

  for (final workout in workouts) {
    final day = bodyDayOf(workout.startedAt);
    if (day.isBefore(firstDay) || day.isAfter(lastDay)) {
      continue;
    }
    for (final exercise in workout.exercises) {
      final preparation = exercise.isWarmup || exercise.isCooldown;
      for (final set in exercise.sets) {
        // Una serie prescritta e non spuntata non è stimolo: contarla
        // direbbe che il gruppo è coperto quando la scheda è stata solo
        // aperta.
        if (!set.completed) {
          continue;
        }
        if (preparation || set.isWarmup) {
          warmupAndCooldownSets++;
          continue;
        }
        final group = exercise.muscleGroup;
        if (group == null) {
          setsWithoutMuscleGroup++;
          continue;
        }
        // Il gruppo è quello congelato sulla riga e resta UNO: il full body
        // non si spalma sui gruppi che «avrebbe toccato». Quanta parte di uno
        // squat goblet vada alle gambe e quanta alla schiena è un'invenzione,
        // e inventarla qui gonfierebbe proprio i gruppi di cui questa
        // schermata deve poter dire che sono vuoti.
        setsByGroup.update(group, (count) => count + 1, ifAbsent: () => 1);
        (sessionsByGroup[group] ??= <String>{}).add(workout.id);
        contributingSessions.add(workout.id);
      }
    }
  }

  final groups = <MuscleGroupVolume>[];
  for (final group in MuscleGroup.values) {
    final sets = setsByGroup[group] ?? 0;
    final banded = bandedMuscleGroups.contains(group);
    // Un gruppo senza banda e senza serie non ha niente da dire; uno CON
    // banda a zero è esattamente la notizia da dare.
    if (!banded && sets == 0) {
      continue;
    }
    final band = banded ? intent.band : null;
    groups.add(
      MuscleGroupVolume(
        group: group,
        sets: sets,
        sessions: sessionsByGroup[group]?.length ?? 0,
        band: band,
        status: band?.statusOf(sets) ?? VolumeBandStatus.unbanded,
      ),
    );
  }

  return WeeklyMuscleVolume(
    firstDay: firstDay,
    lastDay: lastDay,
    intent: intent,
    groups: List.unmodifiable(groups),
    focus: focus,
    sessions: contributingSessions.length,
    setsWithoutMuscleGroup: setsWithoutMuscleGroup,
    warmupAndCooldownSets: warmupAndCooldownSets,
  );
}
