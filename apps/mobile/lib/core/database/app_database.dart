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
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _seedEssentialFoods();
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
            ],
          ),
        );
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

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
