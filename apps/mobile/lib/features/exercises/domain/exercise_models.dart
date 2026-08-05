/// Il catalogo esercizi ereditato da Gym Tracker, in forma di dominio.
///
/// I due enum NON sono decorativi: i loro `.name` sono esattamente i valori
/// ammessi dai CHECK di `exercises` (muscle_group, tracking_mode) e la forma
/// già persistita nell'export. Cambiarne il nome significa rompere il
/// database, non rinominare un'etichetta.
library;

/// Gruppo muscolare. `name` è il valore su disco, `label` quello che legge
/// Marco.
enum MuscleGroup {
  petto('Petto'),
  schiena('Schiena'),
  spalle('Spalle'),
  bicipiti('Bicipiti'),
  tricipiti('Tricipiti'),
  gambe('Gambe'),
  polpacci('Polpacci'),
  addome('Addome'),
  cardio('Cardio'),
  fullbody('Full body'),
  mobilita('Mobilità'),
  altro('Altro');

  const MuscleGroup(this.label);

  final String label;

  /// Tollerante come in Gym: un valore sconosciuto diventa «altro» invece di
  /// far saltare la lettura di tutto il catalogo.
  static MuscleGroup fromStorage(String? value) =>
      MuscleGroup.values.firstWhere(
        (group) => group.name == value,
        orElse: () => MuscleGroup.altro,
      );
}

/// Come si misura una serie di questo esercizio. Decide quali campi compaiono
/// nella prescrizione (ripetizioni oppure durata).
enum ExerciseTrackingMode {
  weightReps('Peso × ripetizioni', 'Bilanciere, manubri, macchine'),
  bodyweightReps('Solo ripetizioni', 'Corpo libero: flessioni, trazioni'),
  timeOnly('Solo tempo', 'Plank e tenute isometriche'),
  timed('Tempo (peso facoltativo)', 'Squat 30", jumping jack 30"'),
  distanceTime('Distanza + tempo', 'Corsa, camminata, bici');

  const ExerciseTrackingMode(this.label, this.hint);

  final String label;

  /// Frase di esempio: da sola l'etichetta non dice quando sceglierlo.
  final String hint;

  /// Vero quando la serie si misura in secondi: la prescrizione chiede una
  /// durata, non delle ripetizioni.
  bool get isTimed =>
      this == ExerciseTrackingMode.timeOnly ||
      this == ExerciseTrackingMode.timed ||
      this == ExerciseTrackingMode.distanceTime;

  static ExerciseTrackingMode fromStorage(String? value) =>
      ExerciseTrackingMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => ExerciseTrackingMode.weightReps,
      );
}

/// Da dove arriva un esercizio, per il filtro della libreria. Non è una
/// colonna: è la lettura di `isPreset`, che in Gym distingueva i «base» dai
/// «miei» nella stessa lista.
enum ExerciseOrigin {
  all('Tutti'),
  mine('I miei'),
  base('Base');

  const ExerciseOrigin(this.label);

  final String label;
}

/// Un esercizio del catalogo di Marco.
class Exercise {
  const Exercise({
    required this.id,
    required this.name,
    required this.muscleGroup,
    required this.trackingMode,
    required this.isPreset,
    required this.source,
    required this.createdAt,
    this.notes,
    this.imageUrl,
    this.defaultRestSec,
  });

  final String id;
  final String name;
  final MuscleGroup muscleGroup;
  final ExerciseTrackingMode trackingMode;
  final String? notes;
  final String? imageUrl;

  /// Recupero suggerito, in secondi. Nullo = decide la scheda.
  final int? defaultRestSec;

  /// Esercizio della libreria di partenza, non creato da Marco.
  final bool isPreset;

  /// `manual`, `gym_tracker` o `cooldown_preset`: serve a capire da dove
  /// arriva una riga quando due sorgenti portano lo stesso nome.
  final String source;

  final DateTime createdAt;

  ExerciseOrigin get origin =>
      isPreset ? ExerciseOrigin.base : ExerciseOrigin.mine;

  /// Bozza pre-compilata per l'editor: modificare un esercizio è ripartire
  /// dai suoi valori, non da un modulo vuoto.
  ExerciseDraft toDraft() => ExerciseDraft(
    name: name,
    muscleGroup: muscleGroup,
    trackingMode: trackingMode,
    notes: notes,
    imageUrl: imageUrl,
    defaultRestSec: defaultRestSec,
  );
}

/// Quello che l'editor sa compilare. Separato da [Exercise] perché id, origine
/// e date non si scrivono a mano: le mette il repository.
class ExerciseDraft {
  const ExerciseDraft({
    required this.name,
    required this.muscleGroup,
    this.trackingMode = ExerciseTrackingMode.weightReps,
    this.notes,
    this.imageUrl,
    this.defaultRestSec,
  });

  final String name;
  final MuscleGroup muscleGroup;
  final ExerciseTrackingMode trackingMode;
  final String? notes;
  final String? imageUrl;
  final int? defaultRestSec;

  bool get isValid => name.trim().isNotEmpty;

  ExerciseDraft copyWith({
    String? name,
    MuscleGroup? muscleGroup,
    ExerciseTrackingMode? trackingMode,
    String? notes,
    String? imageUrl,
    int? defaultRestSec,
    bool clearNotes = false,
    bool clearImage = false,
    bool clearRest = false,
  }) => ExerciseDraft(
    name: name ?? this.name,
    muscleGroup: muscleGroup ?? this.muscleGroup,
    trackingMode: trackingMode ?? this.trackingMode,
    notes: clearNotes ? null : (notes ?? this.notes),
    imageUrl: clearImage ? null : (imageUrl ?? this.imageUrl),
    defaultRestSec: clearRest ? null : (defaultRestSec ?? this.defaultRestSec),
  );
}
