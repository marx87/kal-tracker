import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

@DataClassName('LocalProfile')
/// Dati anagrafici del profilo. Altezza, nascita e sesso sono nullable perché
/// i profili già installati non li hanno: senza di loro non si calcolano BMI,
/// BMR né le formule di composizione corporea, e le schermate che ne dipendono
/// devono chiederli invece di inventarli.
///
/// Non hanno CHECK a livello di tabella di proposito: `app_profiles` è
/// referenziata da dieci tabelle, quindi la migrazione la estende con
/// `addColumn` e non può ricrearla per applicare nuovi vincoli. I limiti li
/// impone il dominio, così un database migrato e uno nuovo si comportano
/// allo stesso modo.
class AppProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text().withLength(min: 1, max: 80)();
  RealColumn get heightCm => real().nullable()();
  DateTimeColumn get birthDate => dateTime().nullable()();
  TextColumn get sex => text().withLength(max: 1).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(name: 'idx_meals_profile_eaten_at', columns: {#profileId, #eatenAt})
class Meals extends Table {
  TextColumn get id => text()();
  TextColumn get profileId => text().references(AppProfiles, #id)();
  TextColumn get mealType => text().withLength(min: 1, max: 16)();
  DateTimeColumn get eatenAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(name: 'idx_meal_items_meal_id', columns: {#mealId})
class MealItems extends Table {
  TextColumn get id => text()();
  TextColumn get mealId =>
      text().references(Meals, #id, onDelete: KeyAction.cascade)();
  TextColumn get foodName => text().withLength(min: 1, max: 160)();
  RealColumn get grams => real()();
  RealColumn get caloriesPer100g => real()();
  RealColumn get proteinPer100g => real()();
  RealColumn get carbsPer100g => real()();
  RealColumn get fatPer100g => real()();
  RealColumn get totalCalories => real()();
  RealColumn get totalProtein => real()();
  RealColumn get totalCarbs => real()();
  RealColumn get totalFat => real()();
  TextColumn get source => text().withDefault(const Constant('manual'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(name: 'idx_sync_outbox_created_at', columns: {#createdAt})
class SyncOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('LocalNutritionTarget')
class NutritionTargets extends Table {
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  RealColumn get dailyCalories => real()();
  RealColumn get dailyProtein => real()();
  RealColumn get dailyCarbs => real()();
  RealColumn get dailyFat => real()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};

  @override
  List<String> get customConstraints => [
    'CHECK (daily_calories > 0)',
    'CHECK (daily_protein >= 0)',
    'CHECK (daily_carbs >= 0)',
    'CHECK (daily_fat >= 0)',
  ];
}

@DataClassName('LocalWaterLog')
@TableIndex(
  name: 'idx_water_logs_profile_logged_at',
  columns: {#profileId, #loggedAt},
)
class WaterLogs extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get milliliters => integer()();
  DateTimeColumn get loggedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (milliliters > 0 AND milliliters <= 10000)',
  ];
}

@DataClassName('LocalBodyMeasurement')
@TableIndex(
  name: 'idx_body_measurements_profile_measured_at',
  columns: {#profileId, #measuredAt},
)
/// Pesate e composizione corporea.
///
/// Si conserva la misura grezza, non i giudizi della bilancia: `impedanceOhm`
/// è l'unica cosa che il dispositivo misura davvero, tutto il resto è formula.
/// Le percentuali derivate vengono salvate insieme alla `formulaVersion` che
/// le ha prodotte, così cambiando formula si ricalcola lo storico invece di
/// spezzarlo in due serie incoerenti.
///
/// Le masse in kg non sono colonne: si ottengono da peso × percentuale. Non lo
/// è nemmeno il BMI (peso / altezza²). `bmrKcal` invece si conserva perché è
/// il valore dichiarato dalla sorgente, utile a confrontare il consumo stimato
/// con quello poi misurato sui dati reali.
///
/// `hasImpedance` distingue la pesata completa da quella con i soli piedi
/// appoggiati male: in quel caso la bilancia restituisce solo il peso, e i
/// derivati devono restare vuoti invece di sembrare misure vere.
///
/// La v7 aggiunge le due cose che mancavano a una lettura Bluetooth completa,
/// entrambe con `addColumn` perché da `body_measurement_values` in poi questa
/// tabella è REFERENZIATA e non si può più ricreare:
/// [deviceModel], cioè quale bilancia ha prodotto la riga (serve alla taratura
/// in doppia lettura e al giorno in cui le bilance saranno due), e
/// [rawPayload], la trama grezza così com'è arrivata. Se un domani si scopre
/// che quel pacchetto conteneva un campo che non sapevamo leggere, lo storico
/// si ridecodifica invece di ricominciare: è lo stesso motivo per cui si salva
/// l'impedenza e non le masse.
///
/// I valori di impedenza multipli — più frequenze, oppure i segmenti di una
/// bilancia a otto elettrodi — vivono in `body_impedance_readings`.
/// [impedanceOhm] resta il valore di corpo intero che alimenta la formula BIA:
/// è denormalizzato apposta, perché ogni lettore (formula, grafici, medie a 7
/// giorni) lo vuole senza una join.
class BodyMeasurements extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  RealColumn get weightKg => real()();
  DateTimeColumn get measuredAt => dateTime()();
  BoolColumn get hasImpedance => boolean().withDefault(const Constant(false))();
  RealColumn get impedanceOhm => real().nullable()();
  RealColumn get bodyFatPct => real().nullable()();
  RealColumn get musclePct => real().nullable()();
  RealColumn get skeletalMusclePct => real().nullable()();
  RealColumn get bonePct => real().nullable()();
  RealColumn get proteinPct => real().nullable()();
  RealColumn get waterPct => real().nullable()();
  RealColumn get subcutaneousFatPct => real().nullable()();
  IntColumn get visceralFatIndex => integer().nullable()();
  IntColumn get bmrKcal => integer().nullable()();
  TextColumn get formulaVersion => text().withLength(max: 40).nullable()();
  TextColumn get source =>
      text().withLength(max: 30).withDefault(const Constant('manual'))();
  TextColumn get externalId => text().withLength(max: 120).nullable()();
  TextColumn get deviceModel => text().withLength(max: 60).nullable()();
  TextColumn get rawPayload => text().withLength(max: 512).nullable()();
  TextColumn get note => text().withLength(max: 240).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (weight_kg >= 20 AND weight_kg <= 500)',
    'CHECK (impedance_ohm IS NULL OR '
        '(impedance_ohm > 0 AND impedance_ohm <= 2000))',
    'CHECK (body_fat_pct IS NULL OR '
        '(body_fat_pct >= 0 AND body_fat_pct <= 100))',
    'CHECK (muscle_pct IS NULL OR (muscle_pct >= 0 AND muscle_pct <= 100))',
    'CHECK (skeletal_muscle_pct IS NULL OR '
        '(skeletal_muscle_pct >= 0 AND skeletal_muscle_pct <= 100))',
    'CHECK (bone_pct IS NULL OR (bone_pct >= 0 AND bone_pct <= 100))',
    'CHECK (protein_pct IS NULL OR (protein_pct >= 0 AND protein_pct <= 100))',
    'CHECK (water_pct IS NULL OR (water_pct >= 0 AND water_pct <= 100))',
    'CHECK (subcutaneous_fat_pct IS NULL OR '
        '(subcutaneous_fat_pct >= 0 AND subcutaneous_fat_pct <= 100))',
    'CHECK (visceral_fat_index IS NULL OR '
        '(visceral_fat_index >= 1 AND visceral_fat_index <= 60))',
    'CHECK (bmr_kcal IS NULL OR (bmr_kcal > 0 AND bmr_kcal < 10000))',
    "CHECK (source IN ('manual', 'renpho_ble', 'renpho_csv', "
        "'gym_tracker', 'health_connect'))",
    // Le importazioni si deduplicano sulla chiave della sorgente. Le pesate
    // manuali hanno external_id NULL e in SQLite due NULL non collidono mai,
    // quindi restano libere di ripetersi.
    'UNIQUE (profile_id, source, external_id)',
  ];
}

@DataClassName('CatalogFood')
@TableIndex(name: 'idx_foods_name', columns: {#name})
class Foods extends Table {
  TextColumn get id => text()();
  TextColumn get ownerProfileId => text()
      .references(AppProfiles, #id, onDelete: KeyAction.setNull)
      .nullable()();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get brand => text().withLength(max: 120).nullable()();
  TextColumn get barcode => text().withLength(max: 32).nullable().unique()();
  RealColumn get caloriesPer100g => real()();
  RealColumn get proteinPer100g => real()();
  RealColumn get carbsPer100g => real()();
  RealColumn get fatPer100g => real()();
  RealColumn get defaultServingGrams =>
      real().withDefault(const Constant(100.0))();
  TextColumn get source => text().withDefault(const Constant('custom'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (calories_per100g >= 0)',
    'CHECK (protein_per100g >= 0)',
    'CHECK (carbs_per100g >= 0)',
    'CHECK (fat_per100g >= 0)',
    'CHECK (default_serving_grams > 0)',
  ];
}

@DataClassName('LocalFoodPreference')
@TableIndex(
  name: 'idx_food_preferences_profile_recent',
  columns: {#profileId, #lastUsedAt},
)
class FoodPreferences extends Table {
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get foodId =>
      text().references(Foods, #id, onDelete: KeyAction.cascade)();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  IntColumn get useCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastUsedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {profileId, foodId};

  @override
  List<String> get customConstraints => ['CHECK (use_count >= 0)'];
}

@DataClassName('LocalFitRecipe')
@TableIndex(
  name: 'idx_fit_recipes_profile_updated_at',
  columns: {#profileId, #updatedAt},
)
class FitRecipes extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get description => text().withLength(max: 600).nullable()();
  TextColumn get instructions => text().withLength(max: 4000).nullable()();
  TextColumn get tags => text().withLength(max: 240).nullable()();
  IntColumn get servings => integer()();
  IntColumn get prepMinutes => integer().withDefault(const Constant(0))();
  RealColumn get totalCalories => real()();
  RealColumn get totalProtein => real()();
  RealColumn get totalCarbs => real()();
  RealColumn get totalFat => real()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (servings > 0 AND servings <= 100)',
    'CHECK (prep_minutes >= 0 AND prep_minutes <= 10080)',
    'CHECK (total_calories >= 0)',
    'CHECK (total_protein >= 0)',
    'CHECK (total_carbs >= 0)',
    'CHECK (total_fat >= 0)',
  ];
}

@DataClassName('LocalRecipeIngredient')
@TableIndex(
  name: 'idx_recipe_ingredients_recipe_position',
  columns: {#recipeId, #position},
)
class RecipeIngredients extends Table {
  TextColumn get id => text()();
  TextColumn get recipeId =>
      text().references(FitRecipes, #id, onDelete: KeyAction.cascade)();
  TextColumn get foodId =>
      text().references(Foods, #id, onDelete: KeyAction.setNull).nullable()();
  IntColumn get position => integer()();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  RealColumn get grams => real()();
  RealColumn get caloriesPer100g => real()();
  RealColumn get proteinPer100g => real()();
  RealColumn get carbsPer100g => real()();
  RealColumn get fatPer100g => real()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (position >= 0)',
    'CHECK (grams > 0)',
    'CHECK (calories_per100g >= 0)',
    'CHECK (protein_per100g >= 0)',
    'CHECK (carbs_per100g >= 0)',
    'CHECK (fat_per100g >= 0)',
    'UNIQUE (recipe_id, position)',
  ];
}

@DataClassName('LocalMealTemplate')
@TableIndex(
  name: 'idx_meal_templates_profile_updated_at',
  columns: {#profileId, #updatedAt},
)
class MealTemplates extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withLength(min: 1, max: 80)();
  TextColumn get mealType => text().withLength(min: 1, max: 16)();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('LocalMealTemplateItem')
@TableIndex(
  name: 'idx_meal_template_items_template_position',
  columns: {#templateId, #position},
)
class MealTemplateItems extends Table {
  TextColumn get id => text()();
  TextColumn get templateId =>
      text().references(MealTemplates, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get foodName => text().withLength(min: 1, max: 160)();
  RealColumn get grams => real()();
  RealColumn get caloriesPer100g => real()();
  RealColumn get proteinPer100g => real()();
  RealColumn get carbsPer100g => real()();
  RealColumn get fatPer100g => real()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (position >= 0)',
    'CHECK (grams > 0)',
    'CHECK (calories_per100g >= 0)',
    'CHECK (protein_per100g >= 0)',
    'CHECK (carbs_per100g >= 0)',
    'CHECK (fat_per100g >= 0)',
    'UNIQUE (template_id, position)',
  ];
}

/// Piano settimanale generato dall'AI sul Mac. La riga vive SOLO in locale
/// (nessun outbox, nessun tipo entità nel sync): la coda remota è
/// `weekly_plan_jobs` e qui ne resta solo il riferimento [remoteJobId].
/// [requestJson] è la richiesta esatta inviata al pianificatore: serve a
/// rileggere il piano con gli stessi vincoli con cui è stato generato.
@DataClassName('LocalWeeklyPlan')
@TableIndex(
  name: 'idx_weekly_plans_profile_start',
  columns: {#profileId, #startDate},
)
class WeeklyPlans extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get startDate => dateTime()();
  IntColumn get days => integer()();
  TextColumn get mealsCsv => text().withLength(min: 1, max: 80)();
  TextColumn get status => text().withLength(min: 1, max: 16)();
  TextColumn get remoteJobId => text().withLength(max: 64).nullable()();
  TextColumn get notes => text().withLength(max: 400).nullable()();
  TextColumn get requestJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (days >= 1 AND days <= 14)',
    "CHECK (status IN ('generating', 'ready', 'failed'))",
  ];
}

/// Una casella del piano: un pasto di un giorno con la ricetta scelta.
/// [recipeId] diventa NULL se la ricetta viene cancellata, ma
/// [recipeNameSnapshot] resta: lo slot si mostra come "non più disponibile",
/// mai come errore. Il piano è una previsione: finché [doneAt] è NULL non
/// esiste nulla nel diario, e [diaryEntryIds] è la CSV delle voci create
/// quando Marco tocca "Fatto".
@DataClassName('LocalWeeklyPlanSlot')
@TableIndex(name: 'idx_weekly_plan_slots_plan_date', columns: {#planId, #date})
class WeeklyPlanSlots extends Table {
  TextColumn get id => text()();
  TextColumn get planId =>
      text().references(WeeklyPlans, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get date => dateTime()();
  TextColumn get meal => text().withLength(min: 1, max: 16)();
  TextColumn get recipeId => text()
      .references(FitRecipes, #id, onDelete: KeyAction.setNull)
      .nullable()();
  TextColumn get recipeNameSnapshot => text().withLength(min: 1, max: 160)();
  RealColumn get servings => real()();
  TextColumn get why => text().withLength(max: 200).nullable()();
  DateTimeColumn get doneAt => dateTime().nullable()();
  TextColumn get diaryEntryIds => text().withLength(max: 400).nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (servings > 0)',
    'UNIQUE (plan_id, date, meal)',
  ];
}

// ---------------------------------------------------------------------
// Allenamenti (v6, traguardo M5.2) — assorbiti da Gym Tracker.
//
// In Firestore erano documenti annidati: gli esercizi dentro il workout,
// le serie dentro l'esercizio, le liste ordinate dentro la scheda. Qui
// diventano tabelle figlie con una posizione densa, perché la logica
// portata invariata da Gym (superset_flow, kcal_estimator,
// personal_records) ragiona per indici posizionali.
// ---------------------------------------------------------------------

/// Catalogo esercizi di Marco, ereditato da Gym Tracker.
///
/// `muscleGroup` e `trackingMode` sono i `.name` degli enum di Gym, non gli
/// ordinali: sono la forma già persistita nell'export, e i fallback (`altro`,
/// `weightReps`) restano tolleranti come lì.
///
/// [isSynthetic] marca le otto righe di defaticamento (`cd-childpose`, …):
/// non sono esercizi di Marco, sono la sequenza di stretch che l'app genera
/// da sola. Esistono come righe perché lo storico le cita per id; ogni
/// schermata di catalogo filtra `is_synthetic = 0`.
/// I loro nome/durata/hint NON si riscrivono a mano: si prendono da
/// `kCoolDownSequence` portato verbatim (vedi importer), altrimenti lo stesso
/// slug finisce con due nomi diversi nello stesso database.
@DataClassName('LocalExercise')
@TableIndex(name: 'idx_exercises_profile_name', columns: {#profileId, #name})
class Exercises extends Table {
  TextColumn get id => text().withLength(min: 1, max: 64)();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get muscleGroup => text().withLength(min: 1, max: 16)();
  TextColumn get trackingMode => text().withLength(min: 1, max: 16)();
  TextColumn get notes => text().withLength(max: 600).nullable()();
  TextColumn get imageUrl => text().withLength(max: 500).nullable()();
  IntColumn get defaultRestSec => integer().nullable()();
  BoolColumn get isPreset => boolean().withDefault(const Constant(false))();
  BoolColumn get isSynthetic => boolean().withDefault(const Constant(false))();
  TextColumn get source =>
      text().withLength(max: 30).withDefault(const Constant('manual'))();
  TextColumn get externalId => text().withLength(max: 120).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (muscle_group IN ('petto', 'schiena', 'spalle', 'bicipiti', "
        "'tricipiti', 'gambe', 'polpacci', 'addome', 'cardio', 'fullbody', "
        "'mobilita', 'altro'))",
    "CHECK (tracking_mode IN ('weightReps', 'bodyweightReps', 'timeOnly', "
        "'timed', 'distanceTime'))",
    "CHECK (source IN ('manual', 'gym_tracker', 'cooldown_preset'))",
    'CHECK (default_rest_sec IS NULL OR '
        '(default_rest_sec >= 0 AND default_rest_sec <= 3600))',
    'UNIQUE (profile_id, source, external_id)',
  ];
}

/// Scheda di allenamento. I sei parametri a tempo servono solo quando
/// [isCircuit] è vero, ma restano NOT NULL con i default di Gym
/// (`UserProfile`/`Routine`: 30/30/60/3 e 30/15): sono la configurazione
/// proposta quando la scheda diventa un circuito, e un NULL costringerebbe
/// ogni lettore a riapplicare gli stessi default a mano.
@DataClassName('LocalRoutine')
@TableIndex(name: 'idx_routines_profile_name', columns: {#profileId, #name})
class Routines extends Table {
  TextColumn get id => text().withLength(min: 1, max: 64)();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get notes => text().withLength(max: 1000).nullable()();
  BoolColumn get isCircuit => boolean().withDefault(const Constant(false))();
  IntColumn get workSec => integer().withDefault(const Constant(30))();
  IntColumn get shortRestSec => integer().withDefault(const Constant(30))();
  IntColumn get longRestSec => integer().withDefault(const Constant(60))();
  IntColumn get rounds => integer().withDefault(const Constant(3))();
  IntColumn get warmupWorkSec => integer().withDefault(const Constant(30))();
  IntColumn get warmupRestSec => integer().withDefault(const Constant(15))();
  TextColumn get source =>
      text().withLength(max: 30).withDefault(const Constant('manual'))();
  TextColumn get externalId => text().withLength(max: 120).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (work_sec > 0 AND work_sec <= 3600)',
    'CHECK (short_rest_sec >= 0 AND short_rest_sec <= 3600)',
    'CHECK (long_rest_sec >= 0 AND long_rest_sec <= 3600)',
    'CHECK (rounds >= 1 AND rounds <= 50)',
    'CHECK (warmup_work_sec > 0 AND warmup_work_sec <= 3600)',
    'CHECK (warmup_rest_sec >= 0 AND warmup_rest_sec <= 3600)',
    "CHECK (source IN ('manual', 'gym_tracker'))",
    'UNIQUE (profile_id, source, external_id)',
  ];
}

/// Le tre liste ordinate di una scheda in una sola tabella.
///
/// In Gym erano `warmupSteps`, `exerciseIds` e `finisherExerciseIds`: stessa
/// forma (un esercizio in una posizione), attributi diversi. [block] le
/// distingue e [position] è densa e ripartita per blocco, perché
/// `IntervalSegment.start/end` indicizza esattamente il blocco `main`.
///
/// [exerciseRefId] è l'id ORIGINALE dell'esercizio e non è mai nullo: è la
/// chiave con cui il dominio portato ragiona (`Routine.prescriptions`,
/// `exerciseGroups[...]`). [exerciseId] è solo la FK viva, che diventa NULL
/// se l'esercizio viene cancellato — se la chiave di raggruppamento fosse
/// quella, due esercizi cancellati diversi collasserebbero nella stessa voce.
///
/// `supersetIndices` sparisce: l'indice i significava «i è incatenato a i-1»,
/// che in SQL è il booleano [inSupersetWithPrevious] sulla riga.
@DataClassName('LocalRoutineExercise')
@TableIndex(
  name: 'idx_routine_exercises_routine_block_position',
  columns: {#routineId, #block, #position},
)
class RoutineExercises extends Table {
  TextColumn get id => text()();
  TextColumn get routineId =>
      text().references(Routines, #id, onDelete: KeyAction.cascade)();
  TextColumn get block => text().withLength(min: 1, max: 10)();
  IntColumn get position => integer()();
  TextColumn get exerciseRefId => text().withLength(min: 1, max: 64)();
  TextColumn get exerciseId => text()
      .references(Exercises, #id, onDelete: KeyAction.setNull)
      .nullable()();
  TextColumn get exerciseNameSnapshot => text().withLength(min: 1, max: 160)();
  BoolColumn get inSupersetWithPrevious =>
      boolean().withDefault(const Constant(false))();
  IntColumn get warmupDurationSec => integer().nullable()();
  IntColumn get prescSets => integer().nullable()();
  IntColumn get prescReps => integer().nullable()();
  IntColumn get prescDurationSec => integer().nullable()();
  IntColumn get prescRestSec => integer().nullable()();

  /// L'intervallo di ripetizioni della doppia progressione: `8-12` invece di
  /// `10`. Quando in tutte le serie si arriva in cima con margine dichiarato,
  /// l'app propone il carico superiore e riporta le ripetizioni in fondo.
  IntColumn get prescRepsMin => integer().nullable()();
  IntColumn get prescRepsMax => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (block IN ('warmup', 'main', 'finisher'))",
    'CHECK (position >= 0)',
    // La FK, quando c'è, deve puntare all'id originale: non sono due dati.
    'CHECK (exercise_id IS NULL OR exercise_id = exercise_ref_id)',
    // Un passo di riscaldamento ha sempre una durata; gli altri blocchi no.
    "CHECK ((block = 'warmup') = (warmup_duration_sec IS NOT NULL))",
    'CHECK (warmup_duration_sec IS NULL OR '
        '(warmup_duration_sec > 0 AND warmup_duration_sec <= 3600))',
    // La catena di superserie esiste solo nel blocco principale, e la prima
    // riga non può essere incatenata a niente.
    "CHECK (in_superset_with_previous = 0 OR "
        "(block = 'main' AND position > 0))",
    'CHECK (presc_sets IS NULL OR (presc_sets >= 1 AND presc_sets <= 50))',
    'CHECK (presc_reps IS NULL OR (presc_reps >= 1 AND presc_reps <= 500))',
    'CHECK (presc_duration_sec IS NULL OR '
        '(presc_duration_sec > 0 AND presc_duration_sec <= 7200))',
    'CHECK (presc_rest_sec IS NULL OR '
        '(presc_rest_sec >= 0 AND presc_rest_sec <= 3600))',
    'UNIQUE (routine_id, block, position)',
  ];
}

/// Blocco a tempo dentro il blocco principale: finestra semiaperta
/// [startIdx, endIdx) sulle posizioni di `routine_exercises` con block='main'.
///
/// [segmentIndex] è la chiave con cui i workout registrano il completamento
/// (`workout_interval_segments.segment_index`) e con cui le route passano
/// `?seg=N`: deve restare densa da 0 e stabile, quindi è parte della UNIQUE e
/// non un id opaco.
@DataClassName('LocalRoutineIntervalSegment')
@TableIndex(
  name: 'idx_routine_interval_segments_routine',
  columns: {#routineId, #segmentIndex},
)
class RoutineIntervalSegments extends Table {
  TextColumn get id => text()();
  TextColumn get routineId =>
      text().references(Routines, #id, onDelete: KeyAction.cascade)();
  IntColumn get segmentIndex => integer()();
  IntColumn get startIdx => integer()();
  IntColumn get endIdx => integer()();
  IntColumn get workSec => integer().withDefault(const Constant(40))();
  IntColumn get restSec => integer().withDefault(const Constant(20))();
  IntColumn get longRestSec => integer().withDefault(const Constant(0))();
  IntColumn get rounds => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (segment_index >= 0)',
    'CHECK (start_idx >= 0)',
    'CHECK (end_idx > start_idx)',
    'CHECK (work_sec > 0 AND work_sec <= 3600)',
    'CHECK (rest_sec >= 0 AND rest_sec <= 3600)',
    'CHECK (long_rest_sec >= 0 AND long_rest_sec <= 3600)',
    'CHECK (rounds >= 1 AND rounds <= 50)',
    'UNIQUE (routine_id, segment_index)',
  ];
}

/// Il piano settimanale di Gym: giorno ISO 1-7 -> scheda. I giorni assenti
/// sono riposo, quindi la riga mancante È l'informazione (in Firestore
/// serviva un `set()` senza merge: qui basta DELETE).
///
/// [id] è un uuid di riga e non la chiave naturale: la chiave naturale
/// (profilo, giorno) resta UNIQUE. Serve perché la tabella remota ha
/// `id uuid primary key` e senza una colonna id la riga non è costruibile
/// lato server (è l'errore che ha reso `food_preferences` non sincronizzabile).
///
/// [routineExternalId] conserva l'id anche quando la scheda non esiste più:
/// nell'export il giorno 3 punta a `e91fda05…`, cancellata.
@DataClassName('LocalRoutineWeeklyPlanDay')
class RoutineWeeklyPlan extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get weekday => integer()();
  TextColumn get routineId => text()
      .references(Routines, #id, onDelete: KeyAction.setNull)
      .nullable()();
  TextColumn get routineExternalId => text().withLength(max: 120).nullable()();
  TextColumn get routineNameSnapshot =>
      text().withLength(max: 160).nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (weekday BETWEEN 1 AND 7)',
    'CHECK (routine_id IS NULL OR routine_id = routine_external_id)',
    'UNIQUE (profile_id, weekday)',
  ];
}

/// Una sessione. [startedAt] è l'unica cosa certa: [endedAt] NULL significa
/// «in corso», ed è l'invariante protetta dall'indice unico parziale
/// `idx_workouts_one_active` (in Firestore serviva il documento puntatore
/// `state/activeWorkout`).
///
/// La durata NON è una colonna derivata: si legge con la regola di Gym
/// invariata — [finalDurationSeconds] se c'è, altrimenti
/// endedAt - startedAt - [accumulatedPauseSeconds]. NESSUN tetto a 86400 sui
/// due contatori: il clamp a 24 h in Gym vive SOLO nel getter `duration`, non
/// nello scrittore (`finalizeWorkoutSnapshot` scrive `activeDuration.inSeconds`
/// senza limite). Un CHECK qui rifiuterebbe la chiusura di una sessione
/// dimenticata aperta 30 ore, che in Gym si chiudeva mostrando 24 h.
///
/// [durationSuspect] marca le sessioni in cui l'orologio da solo mente (una è
/// rimasta aperta 536 ore): il dato resta GREZZO e marcato, non rettificato.
///
/// [routineId] diventa NULL se la scheda viene cancellata, ma
/// [routineNameSnapshot] e [routineExternalId] restano: nove sessioni
/// puntano a sei schede che non esistono più, e ricollegarle per nome
/// creerebbe una falsa storia (esiste una scheda viva 'Giorno1 spalle petto
/// tricipiti' con id diverso da quella storica).
@DataClassName('LocalWorkout')
@TableIndex(
  name: 'idx_workouts_profile_started',
  columns: {#profileId, #startedAt},
)
class Workouts extends Table {
  TextColumn get id => text().withLength(min: 1, max: 64)();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  DateTimeColumn get pausedAt => dateTime().nullable()();
  IntColumn get accumulatedPauseSeconds =>
      integer().withDefault(const Constant(0))();
  IntColumn get finalDurationSeconds => integer().nullable()();
  BoolColumn get durationSuspect =>
      boolean().withDefault(const Constant(false))();
  TextColumn get routineId => text()
      .references(Routines, #id, onDelete: KeyAction.setNull)
      .nullable()();
  TextColumn get routineExternalId => text().withLength(max: 120).nullable()();
  TextColumn get routineNameSnapshot =>
      text().withLength(max: 160).nullable()();
  TextColumn get notes => text().withLength(max: 1000).nullable()();
  RealColumn get totalKcal => real().nullable()();
  IntColumn get mood => integer().nullable()();
  IntColumn get rpe => integer().nullable()();
  IntColumn get satisfaction => integer().nullable()();
  TextColumn get feedbackNotes => text().withLength(max: 1000).nullable()();
  IntColumn get xpEarned => integer().nullable()();
  TextColumn get resumePath => text().withLength(max: 200).nullable()();
  TextColumn get circuitCheckpointJson => text().nullable()();
  BoolColumn get syncedToHealthConnect =>
      boolean().withDefault(const Constant(false))();
  TextColumn get healthSyncState => text().withLength(max: 12).nullable()();
  TextColumn get healthSyncClaimId => text().withLength(max: 64).nullable()();
  DateTimeColumn get healthSyncAttemptedAt => dateTime().nullable()();
  DateTimeColumn get healthSyncCompletedAt => dateTime().nullable()();
  TextColumn get source =>
      text().withLength(max: 30).withDefault(const Constant('manual'))();
  TextColumn get externalId => text().withLength(max: 120).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (ended_at IS NULL OR ended_at >= started_at)',
    'CHECK (paused_at IS NULL OR ended_at IS NULL)',
    // Solo il segno: il tetto di 24 h è una regola di LETTURA, non di
    // scrittura (vedi doc comment).
    'CHECK (accumulated_pause_seconds >= 0)',
    'CHECK (final_duration_seconds IS NULL OR final_duration_seconds >= 0)',
    'CHECK (routine_id IS NULL OR routine_id = routine_external_id)',
    'CHECK (total_kcal IS NULL OR total_kcal >= 0)',
    'CHECK (mood IS NULL OR (mood >= 1 AND mood <= 5))',
    'CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10))',
    'CHECK (satisfaction IS NULL OR (satisfaction >= 1 AND satisfaction <= 5))',
    'CHECK (xp_earned IS NULL OR xp_earned >= 0)',
    "CHECK (health_sync_state IS NULL OR health_sync_state IN "
        "('writing', 'synced', 'uncertain'))",
    "CHECK (source IN ('manual', 'gym_tracker'))",
    'UNIQUE (profile_id, source, external_id)',
  ];
}

/// Una riga della sessione. In Firestore le liste erano tre (`exercises`
/// immutabile, `activeExercises` di lavoro, `intervalSegmentExercises`
/// append-only) perché il documento non aveva transazioni: qui la lista è una
/// sola e [intervalSegmentIndex] distingue le righe appese da un blocco a
/// tempo. L'ordine di lettura resta quello di Gym — prima le righe base, poi
/// quelle dei segmenti — ed è materializzato in [position].
///
/// [exerciseRefId] è l'id ORIGINALE e non è mai nullo. È la chiave che
/// `personal_records` (`out[ex.exerciseId]`, `bestW[ex.exerciseId]`) e
/// `kcal_estimator` (`exerciseGroups[ex.exerciseId]`) usano per RAGGRUPPARE:
/// ricostruirla da [exerciseId] (che diventa NULL alla cancellazione)
/// farebbe collassare esercizi diversi in un'unica voce e cambierebbe
/// `prCountFromHistory`, cioè i trofei pr_1/pr_10/pr_25 già sbloccati.
///
/// [exerciseNameSnapshot], [trackingMode] e [muscleGroupSnapshot] sono
/// congelati apposta: il nome sopravvive alle rinomine, la modalità è quella
/// EFFETTIVA di quella sessione (72 righe su 250, distribuite su 22 esercizi
/// distinti, divergono dal catalogo) e il gruppo muscolare è ciò che
/// `kcal_estimator` chiede.
@DataClassName('LocalWorkoutExercise')
@TableIndex(
  name: 'idx_workout_exercises_workout_position',
  columns: {#workoutId, #position},
)
@TableIndex(
  name: 'idx_workout_exercises_exercise_ref',
  columns: {#exerciseRefId},
)
class WorkoutExercises extends Table {
  TextColumn get id => text()();
  TextColumn get workoutId =>
      text().references(Workouts, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get exerciseRefId => text().withLength(min: 1, max: 64)();
  TextColumn get exerciseId => text()
      .references(Exercises, #id, onDelete: KeyAction.setNull)
      .nullable()();
  TextColumn get exerciseNameSnapshot => text().withLength(min: 1, max: 160)();
  TextColumn get trackingMode => text().withLength(min: 1, max: 16)();
  TextColumn get muscleGroupSnapshot => text().withLength(max: 16).nullable()();
  IntColumn get restSeconds => integer().nullable()();
  BoolColumn get isWarmup => boolean().withDefault(const Constant(false))();
  BoolColumn get isCooldown => boolean().withDefault(const Constant(false))();
  BoolColumn get isFinisher => boolean().withDefault(const Constant(false))();
  BoolColumn get isInSupersetWithPrevious =>
      boolean().withDefault(const Constant(false))();
  IntColumn get intervalSegmentIndex => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (position >= 0)',
    'CHECK (exercise_id IS NULL OR exercise_id = exercise_ref_id)',
    "CHECK (tracking_mode IN ('weightReps', 'bodyweightReps', 'timeOnly', "
        "'timed', 'distanceTime'))",
    "CHECK (muscle_group_snapshot IS NULL OR muscle_group_snapshot IN "
        "('petto', 'schiena', 'spalle', 'bicipiti', 'tricipiti', 'gambe', "
        "'polpacci', 'addome', 'cardio', 'fullbody', 'mobilita', 'altro'))",
    'CHECK (rest_seconds IS NULL OR '
        '(rest_seconds >= 0 AND rest_seconds <= 3600))',
    // I quattro blocchi sono esclusivi: riscaldamento, principale, finisher,
    // defaticamento. Nell'export: 68 warm-up, 12 cool-down, 4 finisher, 166
    // senza flag, ZERO righe con due flag insieme.
    'CHECK (is_warmup + is_cooldown + is_finisher <= 1)',
    'CHECK (is_in_superset_with_previous = 0 OR position > 0)',
    'CHECK (interval_segment_index IS NULL OR interval_segment_index >= 0)',
    'UNIQUE (workout_id, position)',
  ];
}

/// Una serie. I cinque campi metrici restano NULLABLE e senza DEFAULT: in Gym
/// «non inserito» e «zero» sono valori diversi e `copyWith` ha i flag
/// `clearWeight`/`clearReps`/… apposta. Nessun CHECK lega la metrica alla
/// modalità: nell'export esistono serie `weightReps` con le sole ripetizioni
/// e serie `timed` col peso, e un vincolo del tipo «se weightReps allora
/// weight_kg NOT NULL» farebbe fallire l'import sui dati veri.
///
/// [position] è il numero di serie: in Gym la posizione nella lista ERA
/// l'identità (i cursori vivi sono coppie (exerciseIndex, setIndex)), quindi
/// è UNIQUE e va tenuta densa.
///
/// `volume` non è una colonna: è `isWarmup ? 0 : (weightKg ?? 0) * (reps ?? 0)`
/// e si calcola.
@DataClassName('LocalWorkoutSet')
@TableIndex(
  name: 'idx_workout_sets_exercise_position',
  columns: {#workoutExerciseId, #position},
)
class WorkoutSets extends Table {
  TextColumn get id => text()();
  TextColumn get workoutExerciseId =>
      text().references(WorkoutExercises, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  RealColumn get weightKg => real().nullable()();
  IntColumn get reps => integer().nullable()();
  IntColumn get durationSec => integer().nullable()();
  RealColumn get distanceM => real().nullable()();
  IntColumn get rpe => integer().nullable()();
  BoolColumn get isWarmup => boolean().withDefault(const Constant(false))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (position >= 0)',
    'CHECK (weight_kg IS NULL OR (weight_kg >= 0 AND weight_kg <= 1000))',
    'CHECK (reps IS NULL OR (reps >= 0 AND reps <= 1000))',
    'CHECK (duration_sec IS NULL OR '
        '(duration_sec >= 0 AND duration_sec <= 86400))',
    'CHECK (distance_m IS NULL OR (distance_m >= 0 AND distance_m <= 200000))',
    'CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10))',
    'UNIQUE (workout_exercise_id, position)',
  ];
}

/// I punti dolenti segnalati dopo la sessione. In Gym erano una lista dentro
/// il documento, ma nell'UI sono un Set di etichette chiuse e la domanda vera
/// è «quante volte la spalla destra negli ultimi due mesi»: una CSV in colonna
/// (stile `mealsCsv`) non la sa rispondere.
///
/// [id] è un uuid di riga, la chiave naturale (workout, label) resta UNIQUE:
/// senza una colonna id la riga non è costruibile su Supabase.
@DataClassName('LocalWorkoutPainPoint')
class WorkoutPainPoints extends Table {
  TextColumn get id => text()();
  TextColumn get workoutId =>
      text().references(Workouts, #id, onDelete: KeyAction.cascade)();
  TextColumn get label => text().withLength(min: 1, max: 40)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (workout_id, label)'];
}

/// Marcatori di completamento dei blocchi a tempo. In Gym erano tre campi
/// paralleli sul documento: `completedIntervalSegmentIndices`,
/// `partialIntervalSegmentIndices` e la mappa
/// `completedIntervalSegmentSignatures` (int -> String).
///
/// I due marker NON sono mutuamente esclusivi e non possono essere un enum a
/// due valori: sono liste indipendenti che possono contenere lo stesso indice.
/// Lo scenario è reale e voluto — `appendPartialIntervalSegment` calcola
/// `alreadyCompleted` con `isCurrentIntervalSegmentCompletion`, che è FALSO
/// quando il marker di completamento c'è ma la firma non combacia più; da lì
/// scrive `partialIntervalSegmentIndices` LASCIANDO l'indice anche fra i
/// completati. E i due campi hanno precedenze diverse: `workoutResumeRoute`
/// guarda PRIMA i parziali e instrada a `/workout/{id}/phase/segment?seg=N`,
/// i completati solo dopo. Comprimere in una colonna sola manda la ripresa
/// del circuito sulla schermata sbagliata.
///
/// [completionSignature] appartiene SOLO al marker di completamento
/// (`appendPartialIntervalSegment` non scrive mai una firma). È il JSON
/// canonico prodotto da `circuitPhaseConfigSignature`, non un hash: va
/// salvata verbatim perché il confronto avviene contro firme già scritte.
/// NULL non è un caso raro: `isCurrentIntervalSegmentCompletion` tratta la
/// firma assente come «vale sempre».
@DataClassName('LocalWorkoutIntervalSegment')
class WorkoutIntervalSegments extends Table {
  TextColumn get id => text()();
  TextColumn get workoutId =>
      text().references(Workouts, #id, onDelete: KeyAction.cascade)();
  IntColumn get segmentIndex => integer()();
  BoolColumn get completedMarker =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get partialMarker =>
      boolean().withDefault(const Constant(false))();
  TextColumn get completionSignature => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (segment_index >= 0)',
    // Una riga senza nessun marker non è un dato, è spazzatura.
    'CHECK (completed_marker = 1 OR partial_marker = 1)',
    // La firma è la firma DEL COMPLETAMENTO: senza quel marker non esiste.
    'CHECK (completion_signature IS NULL OR completed_marker = 1)',
    'UNIQUE (workout_id, segment_index)',
  ];
}

/// XP, streak, trofei e preferenze di allenamento: il singleton che in Gym era
/// `users/{uid}/profile/data`.
///
/// Non sono colonne di `app_profiles` perché quella tabella è referenziata da
/// dieci tabelle e per regola si estende solo con `addColumn` nullable e senza
/// CHECK. Stesso pattern di `NutritionTargets`, ma con [id] surrogato e
/// UNIQUE su profile_id, perché la riga deve poter esistere su Supabase.
///
/// [gymBodyWeightKg] è il `bodyWeightKg: 94.7` congelato nel profilo Gym.
/// Si conserva per non perdere il dato e per spiegare i `total_kcal` storici,
/// ma NON deve MAI essere mappato su `UserProfile.bodyWeightKg`: `pickBodyKg`
/// ha quel campo come priorità 1 e restituirebbe 94,7 invece dell'ultima
/// pesata reale (94,5 del 19/06), violando il vincolo 6. Il codice portato va
/// chiamato con `profile: null`.
///
/// [gymExportedAt] è l'`exportedAt` del file (2026-08-05T10:38:57.921390):
/// è il limite superiore certo per i trofei importati, che non hanno data.
@DataClassName('LocalWorkoutProfileStats')
class WorkoutProfileStats extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get totalXp => integer().withDefault(const Constant(0))();
  IntColumn get currentStreak => integer().withDefault(const Constant(0))();
  IntColumn get longestStreak => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastWorkoutDay => dateTime().nullable()();
  IntColumn get weeklyWorkoutGoal => integer().withDefault(const Constant(3))();
  IntColumn get weeklyKcalGoal => integer().withDefault(const Constant(1500))();
  BoolColumn get reminderEnabled =>
      boolean().withDefault(const Constant(false))();
  IntColumn get reminderHour => integer().withDefault(const Constant(18))();
  IntColumn get reminderMinute => integer().withDefault(const Constant(0))();
  BoolColumn get healthConnectEnabled =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get voiceEnabled => boolean().withDefault(const Constant(true))();
  RealColumn get gymBodyWeightKg => real().nullable()();
  DateTimeColumn get gymExportedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (total_xp >= 0)',
    'CHECK (current_streak >= 0 AND longest_streak >= 0)',
    'CHECK (longest_streak >= current_streak)',
    'CHECK (weekly_workout_goal >= 1 AND weekly_workout_goal <= 14)',
    'CHECK (weekly_kcal_goal >= 0 AND weekly_kcal_goal <= 100000)',
    'CHECK (reminder_hour >= 0 AND reminder_hour <= 23)',
    'CHECK (reminder_minute >= 0 AND reminder_minute <= 59)',
    'CHECK (gym_body_weight_kg IS NULL OR '
        '(gym_body_weight_kg >= 20 AND gym_body_weight_kg <= 500))',
    'UNIQUE (profile_id)',
  ];
}

/// Trofei sbloccati. Di persistito c'è solo lo slug: il catalogo dei 36
/// traguardi (nome, icona, bonus XP, predicato) resta codice Dart. Gli slug
/// vanno riportati parola per parola, altrimenti un trofeo già preso si
/// rivince e il bonus XP viene riassegnato.
///
/// [unlockedAt] è NULLABLE e per le righe importate resta NULL: l'export non
/// dice quando. Riempirlo con l'istante dell'import schiaccerebbe la timeline
/// dei trofei sul giorno della migrazione facendo sembrare vero un dato che
/// non lo è; il limite superiore certo è `workout_profile_stats.gym_exported_at`.
@DataClassName('LocalWorkoutAchievement')
class WorkoutAchievements extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get slug => text().withLength(min: 1, max: 60)();
  DateTimeColumn get unlockedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => ['UNIQUE (profile_id, slug)'];
}

/// Le circonferenze libere di una pesata (`custom` in Gym: 'Vita', 'Braccio',
/// 'Coscia', 'Petto', ma le chiavi le decide Marco). Non sono colonne di
/// `body_measurements` proprio perché l'insieme è aperto, e non sono un JSON
/// perché la domanda è «la vita negli ultimi sei mesi», cioè una serie.
///
/// ATTENZIONE: questa tabella rende `body_measurements` una tabella
/// REFERENZIATA. Da qui in poi si estende solo con `addColumn` nullable e
/// senza CHECK, come `app_profiles`: il `TableMigration` usato dalla v5 non è
/// più applicabile — la v7 lo ha rispettato, e le sue due colonne nuove sono
/// elencate anche fra i `newColumns` del ramo della v5 perché quel ramo
/// ricostruisce la tabella dalla definizione Dart di oggi. La regola vive
/// nelle note di handoff di `docs/ROADMAP.md`.
@DataClassName('LocalBodyMeasurementValue')
@TableIndex(
  name: 'idx_body_measurement_values_label',
  columns: {#measurementId, #label},
)
class BodyMeasurementValues extends Table {
  TextColumn get id => text()();
  TextColumn get measurementId =>
      text().references(BodyMeasurements, #id, onDelete: KeyAction.cascade)();
  TextColumn get label => text().withLength(min: 1, max: 40)();
  RealColumn get value => real()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (value > 0 AND value <= 1000)',
    'UNIQUE (measurement_id, label)',
  ];
}

// ---------------------------------------------------------------------
// Check-in, obiettivo e impedenze (v7).
//
// Le prime due tabelle raccolgono due file JSON che vivevano fuori dal
// database: fuori dal backup, fuori dalla sincronizzazione e invisibili al
// coach, che invece li vuole — il semaforo del sovrallenamento (M8.3) legge
// sonno ed energia, e il motore adattivo (M7) legge l'obiettivo.
// ---------------------------------------------------------------------

/// Il check-in del mattino: sonno ed energia di un giorno.
///
/// **Una tabella sola.** Sonno ed energia sono lo stesso gesto sullo stesso
/// giorno: due tabelle avrebbero due righe da tenere allineate e nessuna
/// domanda che le voglia separate. Entrambi i campi restano facoltativi —
/// un check-in con il solo sonno è un check-in valido, e il coach deve
/// funzionare con dati mancanti.
///
/// [day] è l'ETICHETTA del giorno civile romano, non un istante: `DateTime`
/// UTC a mezzanotte, stessa convenzione di `AppProfiles.birthDate` e di
/// `WeeklyPlans.startDate`. Alle 00:30 di Roma un timestamp finirebbe nel
/// giorno prima.
///
/// Il peso NON sta qui: vive in `body_measurements`, dove è sempre vissuto.
/// Due tabelle con lo stesso numero diventano due numeri diversi il giorno in
/// cui una delle due sbaglia.
///
/// [id] è deterministico (uuid v5 di profilo + giorno, vedi
/// `DriftCheckInStore`): due dispositivi che compilano lo stesso giorno
/// offline producono la STESSA riga e la sincronizzazione la fonde invece di
/// duplicarla. È per questo che l'unicità qui è totale e non parziale sulle
/// righe vive: un giorno cancellato e ricompilato riusa la sua riga.
@DataClassName('LocalDailyCheckIn')
@TableIndex(
  name: 'idx_daily_check_ins_profile_day',
  columns: {#profileId, #day},
)
class DailyCheckIns extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get day => dateTime()();
  RealColumn get sleepHours => real().nullable()();
  IntColumn get energyScore => integer().nullable()();

  /// Il movimento non strutturato della giornata. Serve ad accorgersene, non a
  /// misurarlo con precisione: il plateau classico arriva quando il NEAT crolla
  /// senza che nessuno se ne accorga.
  IntColumn get steps => integer().nullable()();
  IntColumn get walkMinutes => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    // Le stesse scale del dominio: mezz'ore fino a 16, energia 1-5. Sopra le
    // 16 ore non è più una notte, è un errore di digitazione.
    'CHECK (sleep_hours IS NULL OR (sleep_hours >= 0 AND sleep_hours <= 16))',
    'CHECK (energy_score IS NULL OR (energy_score >= 1 AND energy_score <= 5))',
    // Una riga viva senza nessuno dei due campi non è un check-in: farebbe
    // contare come «compilato» un giorno vuoto. Il tombstone invece è proprio
    // una riga svuotata, e resta lecito.
    'CHECK (deleted_at IS NOT NULL OR '
        'sleep_hours IS NOT NULL OR energy_score IS NOT NULL)',
    'UNIQUE (profile_id, day)',
  ];
}

/// **L'Obiettivo**, con il suo storico.
///
/// Una riga per traguardo: quello in corso è la riga con [closedAt] nullo,
/// gli altri sono il passato. Cambiare traguardo non azzera niente — si
/// archivia la riga vecchia con la sua data di chiusura e il suo [outcome], e
/// se ne apre una nuova. Tendenze, pesate e TDEE misurato non passano di qui:
/// sono proprietà del corpo di Marco, non del traguardo.
///
/// [startWeightKg] e [startFatFreeMassKg] sono lo stato di partenza di
/// *questo* traguardo e non si toccano più: servono a misurarne i progressi
/// senza ripescare com'era il corpo il giorno in cui è nato.
///
/// [paceKgPerWeek] vive qui e non in una costante di codice proprio perché si
/// cambia in corsa (M7.1c). Il limite dello 0,7 % del peso non è un CHECK: è
/// una frazione del peso corrente, che questa riga non conosce, e vive in
/// `GoalPace.assess`. Il CHECK qui rifiuta solo l'assurdo.
///
/// **Nessun indice unico sull'obiettivo aperto**, a differenza di
/// `idx_workouts_one_active`. Due dispositivi offline che fissano un traguardo
/// ciascuno produrrebbero due righe aperte, e un vincolo qui bloccherebbe la
/// sincronizzazione invece di risolvere: l'elezione dell'obiettivo corrente
/// (il più recente per [startedAt]) la fa `DriftGoalStore` in lettura, e la
/// scrittura successiva archivia gli altri.
@DataClassName('LocalGoal')
@TableIndex(
  name: 'idx_goals_profile_started',
  columns: {#profileId, #startedAt},
)
class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  RealColumn get targetWeightKg => real()();
  TextColumn get targetLevel => text().withLength(min: 1, max: 20)();
  RealColumn get paceKgPerWeek => real()();
  DateTimeColumn get startedAt => dateTime()();
  RealColumn get startWeightKg => real()();
  RealColumn get startFatFreeMassKg => real()();
  TextColumn get phase => text()
      .withLength(min: 1, max: 20)
      .withDefault(const Constant('approach'))();
  DateTimeColumn get phaseStartedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  TextColumn get outcome => text().withLength(max: 20).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (target_weight_kg >= 20 AND target_weight_kg <= 500)',
    'CHECK (start_weight_kg >= 20 AND start_weight_kg <= 500)',
    'CHECK (start_fat_free_mass_kg > 0 AND start_fat_free_mass_kg <= 500)',
    // Il limite vero è lo 0,7 % del peso e sta nel dominio: qui passa tutto
    // ciò che è un ritmo, e si ferma ciò che non lo è.
    'CHECK (pace_kg_per_week > 0 AND pace_kg_per_week <= 5)',
    "CHECK (target_level IN ('soft', 'normal', 'lean', 'athletic', "
        "'defined', 'veryDefined'))",
    "CHECK (phase IN ('approach', 'consolidation', 'maintenance'))",
    "CHECK (outcome IS NULL OR outcome IN ('reached', 'replaced', "
        "'abandoned'))",
    // Un esito senza data di chiusura è un obiettivo chiuso a metà.
    'CHECK (outcome IS NULL OR closed_at IS NOT NULL)',
    'CHECK (closed_at IS NULL OR closed_at >= started_at)',
    'CHECK (phase_started_at IS NULL OR phase_started_at >= started_at)',
  ];
}

/// Ogni valore di impedenza che la bilancia ha emesso in una pesata.
///
/// La QN-Scale di Marco ne dà uno solo, di corpo intero, e per lui questa
/// tabella resterà quasi sempre vuota. Esiste ORA perché una bilancia a otto
/// elettrodi o multifrequenza ne dà cinque o dieci, e scoprirlo dopo
/// significherebbe una v8 e uno storico spezzato in due: l'impedenza è la sola
/// cosa che il dispositivo misura davvero, tutto il resto è formula.
///
/// [frequencyHz] è NULLABLE perché la maggior parte dei protocolli non la
/// dichiara: scrivere «50 kHz» perché è il valore tipico sarebbe salvare una
/// supposizione accanto a una misura. L'unicità sulla coppia
/// (misura, segmento) per le letture senza frequenza è un indice parziale
/// (`idx_body_impedance_readings_undeclared`), perché in SQLite due NULL non
/// collidono mai.
///
/// Il valore di corpo intero compare anche in
/// `body_measurements.impedance_ohm`: là è il numero che alimenta la formula,
/// qui è il verbale completo della lettura.
///
/// Il tetto è più alto di quello del genitore (2000 Ω): alle basse frequenze e
/// sui singoli arti l'impedenza è legittimamente maggiore di quella di corpo
/// intero a 50 kHz.
@DataClassName('LocalBodyImpedanceReading')
@TableIndex(
  name: 'idx_body_impedance_readings_measurement',
  columns: {#measurementId},
)
class BodyImpedanceReadings extends Table {
  TextColumn get id => text()();
  TextColumn get measurementId =>
      text().references(BodyMeasurements, #id, onDelete: KeyAction.cascade)();
  TextColumn get segment => text().withLength(min: 1, max: 16)();
  IntColumn get frequencyHz => integer().nullable()();
  RealColumn get ohm => real()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (segment IN ('whole', 'leftArm', 'rightArm', 'leftLeg', "
        "'rightLeg', 'trunk'))",
    'CHECK (frequency_hz IS NULL OR '
        '(frequency_hz > 0 AND frequency_hz <= 10000000))',
    'CHECK (ohm > 0 AND ohm <= 5000)',
    'UNIQUE (measurement_id, segment, frequency_hz)',
  ];
}

/// Chi è Marco **come atleta**: cosa ha in casa, cosa gli fa male, quanto può
/// allenarsi.
///
/// Non è burocrazia: è il filtro che rende programmabile tutto il resto. Senza,
/// il lavoro di escludere a mano shoulder press, alzate sopra la spalla e tutto
/// ciò che carica le mani va rifatto identico a ogni scheda — è già successo il
/// 7 agosto 2026, ed è il costo che questa tabella cancella.
///
/// **Sincronizzata**, a differenza di `local_settings`: l'attrezzatura e le
/// limitazioni sono dati di Marco, non dell'apparecchio, e devono viaggiare fra
/// telefono e tablet.
class TrainingProfiles extends Table {
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();

  /// L'attrezzatura disponibile, separata da virgole.
  ///
  /// La distinzione fra elastici ad anello e ancorabili non è un dettaglio: è
  /// la ragione per cui il push-down tricipiti resta fuori da ogni scheda con
  /// i soli elastici. Senza un punto di ancoraggio quell'esercizio non esiste.
  TextColumn get equipment =>
      text().withLength(max: 400).withDefault(const Constant(''))();

  /// Quante sessioni a settimana e quanto lunghe: servono all'aderenza — che
  /// oggi guarda solo il cibo — e a un generatore che deve sapere se ha trenta
  /// minuti o sessanta.
  IntColumn get sessionsPerWeek => integer().nullable()();
  IntColumn get minutesPerSession => integer().nullable()();

  /// I giorni preferiti, separati da virgole (`lun,mer,ven`).
  TextColumn get preferredDays =>
      text().withLength(max: 60).withDefault(const Constant(''))();

  /// Cosa fare quando il semaforo del sovrallenamento chiede uno scarico.
  ///
  /// Il valore di partenza è `suggerito` e non `automatico`, coerente col
  /// principio di tutta l'app: propone, non decide.
  TextColumn get deloadPreference =>
      text().withLength(max: 16).withDefault(const Constant('suggerito'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {profileId};

  @override
  List<String> get customConstraints => [
    "CHECK (deload_preference IN ('automatico', 'suggerito'))",
    'CHECK (sessions_per_week IS NULL OR '
        '(sessions_per_week >= 1 AND sessions_per_week <= 14))',
    'CHECK (minutes_per_session IS NULL OR '
        '(minutes_per_session >= 10 AND minutes_per_session <= 300))',
  ];
}

/// Una parte del corpo che al momento limita cosa si può fare.
///
/// **Nessuna scadenza automatica.** Un'app che «guarisce» una spalla dopo due
/// settimane per conto suo è un'app che prescrive male: la limitazione si
/// chiude quando Marco dice che è chiusa, non quando è passato abbastanza
/// tempo.
class TrainingLimitations extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();

  /// L'articolazione o la zona: `spalla_dx`, `lombari`, `ginocchio_sx`…
  TextColumn get bodyPart => text().withLength(min: 1, max: 24)();

  /// `fastidio` segnala e propone un'alternativa, `dolore` esclude
  /// dall'articolazione primaria, `stop` esclude e basta.
  TextColumn get severity => text().withLength(min: 1, max: 12)();

  TextColumn get note => text().withLength(max: 300).nullable()();
  DateTimeColumn get startedAt => dateTime()();

  /// Valorizzata solo quando Marco la chiude a mano.
  DateTimeColumn get resolvedAt => dateTime().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (severity IN ('fastidio', 'dolore', 'stop'))",
    "CHECK (body_part IN ('spalla_dx', 'spalla_sx', 'gomito_dx', "
        "'gomito_sx', 'polso_dx', 'polso_sx', 'collo', 'costole', "
        "'lombari', 'anca_dx', 'anca_sx', 'ginocchio_dx', 'ginocchio_sx', "
        "'caviglia_dx', 'caviglia_sx'))",
  ];
}

/// Le impostazioni che valgono su **questo telefono** e non si sincronizzano.
///
/// Esiste separata da `app_profiles` per una ragione precisa: l'indirizzo
/// Bluetooth della bilancia è il MAC visto da questo dispositivo, e su un
/// altro telefono non significherebbe niente — sincronizzarlo vorrebbe dire
/// spedire al tablet l'istruzione di collegarsi a un indirizzo che lì non
/// esiste. Tutto ciò che dipende dall'apparecchio, e non da Marco, sta qui.
class LocalSettings extends Table {
  TextColumn get key => text().withLength(min: 1, max: 60)();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    AppProfiles,
    Meals,
    MealItems,
    SyncOutbox,
    NutritionTargets,
    WaterLogs,
    BodyMeasurements,
    Foods,
    FoodPreferences,
    FitRecipes,
    RecipeIngredients,
    MealTemplates,
    MealTemplateItems,
    WeeklyPlans,
    WeeklyPlanSlots,
    // v6 — allenamenti (M5.2)
    Exercises,
    Routines,
    RoutineExercises,
    RoutineIntervalSegments,
    RoutineWeeklyPlan,
    Workouts,
    WorkoutExercises,
    WorkoutSets,
    WorkoutPainPoints,
    WorkoutIntervalSegments,
    WorkoutProfileStats,
    WorkoutAchievements,
    BodyMeasurementValues,
    // v7 — check-in, obiettivo e impedenze multiple
    DailyCheckIns,
    Goals,
    BodyImpedanceReadings,
    // v8 — impostazioni legate all'apparecchio, fuori dalla sincronizzazione
    LocalSettings,
    // v9 — chi è Marco come atleta
    TrainingProfiles,
    TrainingLimitations,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  AppDatabase.defaults()
    : super(
        driftDatabase(
          name: 'kal_tracker',
          native: DriftNativeOptions(
            databaseDirectory: getApplicationSupportDirectory,
          ),
        ),
      );

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _seedEssentialFoods();
      await _createPartialIndexes();
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.createTable(nutritionTargets);
        await migrator.createTable(waterLogs);
        await migrator.createTable(bodyMeasurements);
        await migrator.createTable(foods);
        await migrator.createTable(foodPreferences);
        await migrator.createTable(fitRecipes);
        await migrator.createTable(recipeIngredients);
        await _seedEssentialFoods();
      }
      if (from < 3) {
        await migrator.createTable(mealTemplates);
        await migrator.createTable(mealTemplateItems);
        if (from >= 2) {
          await migrator.addColumn(fitRecipes, fitRecipes.tags);
        }
      }
      // I rami sono cumulativi: nessuno dei precedenti crea le tabelle del
      // piano, quindi qui non serve nessuna guardia come quella dei tag.
      if (from < 4) {
        await migrator.createTable(weeklyPlans);
        await migrator.createTable(weeklyPlanSlots);
      }
      if (from < 5) {
        // `app_profiles` è referenziata da dieci tabelle: si estende soltanto
        // con addColumn, mai ricreandola. Per questo le tre colonne nuove sono
        // nullable e senza CHECK — i limiti li impone il dominio.
        await migrator.addColumn(appProfiles, appProfiles.heightCm);
        await migrator.addColumn(appProfiles, appProfiles.birthDate);
        await migrator.addColumn(appProfiles, appProfiles.sex);
        // `body_measurements` invece non è referenziata da nessuno, quindi si
        // può ricreare: serve per applicare i nuovi CHECK e l'UNIQUE anche ai
        // database già installati, che con un semplice addColumn resterebbero
        // senza vincoli e divergerebbero da un'installazione nuova.
        // Le foreign key qui sono ancora spente: `beforeOpen` le accende solo
        // dopo la migrazione, e dentro una transazione il PRAGMA sarebbe
        // comunque senza effetto.
        await migrator.alterTable(
          TableMigration(
            bodyMeasurements,
            newColumns: [
              bodyMeasurements.hasImpedance,
              bodyMeasurements.impedanceOhm,
              bodyMeasurements.bodyFatPct,
              bodyMeasurements.musclePct,
              bodyMeasurements.skeletalMusclePct,
              bodyMeasurements.bonePct,
              bodyMeasurements.proteinPct,
              bodyMeasurements.waterPct,
              bodyMeasurements.subcutaneousFatPct,
              bodyMeasurements.visceralFatIndex,
              bodyMeasurements.bmrKcal,
              bodyMeasurements.formulaVersion,
              bodyMeasurements.source,
              bodyMeasurements.externalId,
              // Le due della v7 vanno elencate QUI anche se sono di un'altra
              // versione: `TableMigration` ricrea la tabella dalla definizione
              // Dart di OGGI e copia con un INSERT ... SELECT che nomina ogni
              // colonna non dichiarata nuova. Senza queste due righe la
              // migrazione da v1-v4 leggerebbe `device_model` da una tabella
              // che non ce l'ha. La guardia gemella sta nel ramo `from < 7`.
              bodyMeasurements.deviceModel,
              bodyMeasurements.rawPayload,
            ],
          ),
        );
      }
      // La v6 è creazione pura: tredici tabelle nuove che nascono già con i
      // loro CHECK e le loro UNIQUE. Nessun `addColumn` su `app_profiles` (XP
      // e streak vivono in `workout_profile_stats`) e nessun `alterTable` su
      // `body_measurements`, che ha la sorgente 'gym_tracker' e la UNIQUE di
      // deduplica fin dalla v5.
      if (from < 6) {
        await migrator.createTable(exercises);
        await migrator.createTable(routines);
        await migrator.createTable(routineExercises);
        await migrator.createTable(routineIntervalSegments);
        await migrator.createTable(routineWeeklyPlan);
        await migrator.createTable(workouts);
        await migrator.createTable(workoutExercises);
        await migrator.createTable(workoutSets);
        await migrator.createTable(workoutPainPoints);
        await migrator.createTable(workoutIntervalSegments);
        await migrator.createTable(workoutProfileStats);
        await migrator.createTable(workoutAchievements);
        await migrator.createTable(bodyMeasurementValues);
      }
      if (from < 7) {
        // `body_measurements` da qui in poi si estende SOLO con addColumn: la
        // referenziano `body_measurement_values` (v6) e `body_impedance_
        // readings` (questa versione), quindi il TableMigration della v5 non è
        // più applicabile.
        //
        // La guardia `from >= 5` è la gemella della nota nel ramo della v5:
        // chi arriva da v1-v4 ha appena ricevuto le due colonne dalla
        // ricostruzione della tabella, e un addColumn qui esploderebbe con
        // «duplicate column name» — è lo stesso inciampo dei tag della v3.
        if (from >= 5) {
          await migrator.addColumn(
            bodyMeasurements,
            bodyMeasurements.deviceModel,
          );
          await migrator.addColumn(
            bodyMeasurements,
            bodyMeasurements.rawPayload,
          );
        }
        await migrator.createTable(dailyCheckIns);
        await migrator.createTable(goals);
        await migrator.createTable(bodyImpedanceReadings);
      }
      // La v8 è una tabella sola e nessuno la referenzia: nessuna guardia
      // serve, e chi arriva da qualsiasi versione precedente la riceve uguale.
      if (from < 8) {
        await migrator.createTable(localSettings);
      }
      if (from < 9) {
        await migrator.createTable(trainingProfiles);
        await migrator.createTable(trainingLimitations);
        // L'intervallo di ripetizioni serve alla doppia progressione: la
        // prescrizione dice `8-12` e non `10`, e quando si arriva in cima a
        // tutte le serie l'app propone il gradino di carico. Nullable perché
        // le schede esistenti hanno solo `presc_reps`, che resta il valore di
        // partenza.
        //
        // La guardia è la stessa dei tag della v3 e delle colonne della v7:
        // `routine_exercises` la crea il ramo `from < 6` **dalla definizione
        // Dart di oggi**, che queste due colonne ce le ha già. Chi arriva da
        // prima della v6 le ha quindi ricevute in regalo, e un addColumn qui
        // esploderebbe con «duplicate column name».
        if (from >= 6) {
          await migrator.addColumn(
            routineExercises,
            routineExercises.prescRepsMin,
          );
          await migrator.addColumn(
            routineExercises,
            routineExercises.prescRepsMax,
          );
        }
        // I passi del giorno: il NEAT è dove il plateau nasce davvero, e senza
        // un campo il TDEE misurato vede il consumo calare senza poterlo
        // spiegare — dicendo «togli 150 kcal» quando la risposta era «hai
        // camminato metà». Stessa guardia, un ramo più avanti:
        // `daily_check_ins` nasce nel `from < 7`.
        if (from >= 7) {
          await migrator.addColumn(dailyCheckIns, dailyCheckIns.steps);
          await migrator.addColumn(dailyCheckIns, dailyCheckIns.walkMinutes);
        }
      }
      // Fuori dalla guardia di proposito: ripara anche gli indici delle
      // versioni 2-5, che nessun database migrato ha mai avuto.
      await _createMissingIndexes(migrator);
      await _createPartialIndexes();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Crea gli indici dichiarati con `@TableIndex` che il database non ha.
  ///
  /// `Migrator.createTable` emette il solo `CREATE TABLE`: gli indici li crea
  /// `createAll`, che gira solo su installazione pulita. Ogni database arrivato
  /// qui per migrazione ne è quindi privo — è un difetto che esiste dalla v2,
  /// non introdotto dalla v6. Il confronto con `sqlite_master` serve perché il
  /// `CREATE INDEX` generato non ha `IF NOT EXISTS`: senza filtro, un database
  /// installato da zero fallirebbe sui propri indici già presenti.
  Future<void> _createMissingIndexes(Migrator migrator) async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name IS NOT NULL",
    ).get();
    final existing = {for (final row in rows) row.read<String>('name')};
    for (final index in allSchemaEntities.whereType<Index>()) {
      if (existing.contains(index.entityName)) continue;
      await migrator.createIndex(index);
    }
  }

  /// Indici che il generatore non sa produrre, perché `@TableIndex` non
  /// supporta la clausola WHERE. `IF NOT EXISTS` rende il passo ripetibile.
  ///
  /// «Una sola sessione aperta per profilo» in Firestore richiedeva un
  /// documento puntatore `state/activeWorkout` e una risoluzione lato client
  /// quando ne restavano due aperte. Qui è un vincolo del database.
  Future<void> _createPartialIndexes() async {
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_workouts_one_active '
      'ON workouts (profile_id) '
      'WHERE ended_at IS NULL AND deleted_at IS NULL',
    );
    // Due letture di corpo intero senza frequenza dichiarata sono la stessa
    // lettura scritta due volte: la UNIQUE della tabella non le vede, perché
    // in SQLite due NULL non collidono mai.
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS '
      'idx_body_impedance_readings_undeclared '
      'ON body_impedance_readings (measurement_id, segment) '
      'WHERE frequency_hz IS NULL',
    );
  }

  Future<void> _seedEssentialFoods() async {
    const seed =
        <
          ({
            String id,
            String name,
            double calories,
            double protein,
            double carbs,
            double fat,
            double serving,
          })
        >[
          (
            id: 'seed-oats',
            name: 'Fiocchi d’avena',
            calories: 389,
            protein: 16.9,
            carbs: 66.3,
            fat: 6.9,
            serving: 50,
          ),
          (
            id: 'seed-greek-yogurt',
            name: 'Yogurt greco 0%',
            calories: 59,
            protein: 10.3,
            carbs: 3.6,
            fat: 0.4,
            serving: 170,
          ),
          (
            id: 'seed-banana',
            name: 'Banana',
            calories: 89,
            protein: 1.1,
            carbs: 22.8,
            fat: 0.3,
            serving: 120,
          ),
          (
            id: 'seed-apple',
            name: 'Mela',
            calories: 52,
            protein: 0.3,
            carbs: 13.8,
            fat: 0.2,
            serving: 150,
          ),
          (
            id: 'seed-egg',
            name: 'Uovo intero',
            calories: 143,
            protein: 12.6,
            carbs: 0.7,
            fat: 9.5,
            serving: 60,
          ),
          (
            id: 'seed-chicken-breast',
            name: 'Petto di pollo',
            calories: 165,
            protein: 31,
            carbs: 0,
            fat: 3.6,
            serving: 150,
          ),
          (
            id: 'seed-basmati-rice',
            name: 'Riso basmati cotto',
            calories: 130,
            protein: 2.7,
            carbs: 28.2,
            fat: 0.3,
            serving: 150,
          ),
          (
            id: 'seed-salmon',
            name: 'Salmone',
            calories: 208,
            protein: 20.4,
            carbs: 0,
            fat: 13.4,
            serving: 150,
          ),
          (
            id: 'seed-broccoli',
            name: 'Broccoli',
            calories: 34,
            protein: 2.8,
            carbs: 6.6,
            fat: 0.4,
            serving: 200,
          ),
          (
            id: 'seed-wholemeal-bread',
            name: 'Pane integrale',
            calories: 247,
            protein: 13,
            carbs: 41,
            fat: 3.4,
            serving: 60,
          ),
          (
            id: 'seed-almonds',
            name: 'Mandorle',
            calories: 579,
            protein: 21.2,
            carbs: 21.6,
            fat: 49.9,
            serving: 30,
          ),
          (
            id: 'seed-olive-oil',
            name: 'Olio extravergine di oliva',
            calories: 884,
            protein: 0,
            carbs: 0,
            fat: 100,
            serving: 10,
          ),
        ];
    final now = DateTime.now().toUtc();

    await batch((batch) {
      batch.insertAll(
        foods,
        seed
            .map(
              (food) => FoodsCompanion.insert(
                id: food.id,
                name: food.name,
                caloriesPer100g: food.calories,
                proteinPer100g: food.protein,
                carbsPer100g: food.carbs,
                fatPer100g: food.fat,
                defaultServingGrams: Value(food.serving),
                source: const Value('seed'),
                createdAt: now,
                updatedAt: now,
              ),
            )
            .toList(growable: false),
        mode: InsertMode.insertOrIgnore,
      );
    });
  }
}
