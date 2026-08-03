import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

@DataClassName('LocalProfile')
class AppProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text().withLength(min: 1, max: 80)();
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
class BodyMeasurements extends Table {
  TextColumn get id => text()();
  TextColumn get profileId =>
      text().references(AppProfiles, #id, onDelete: KeyAction.cascade)();
  RealColumn get weightKg => real()();
  DateTimeColumn get measuredAt => dateTime()();
  TextColumn get note => text().withLength(max: 240).nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'CHECK (weight_kg >= 20 AND weight_kg <= 500)',
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
  int get schemaVersion => 3;

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
