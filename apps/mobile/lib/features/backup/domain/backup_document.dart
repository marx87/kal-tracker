import 'dart:convert';

import 'package:crypto/crypto.dart';

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => 'BackupFormatException: $message';
}

/// Il file è integro ma non copre una parte del database che invece è piena:
/// rimetterlo «sostituendo tutto» cancellerebbe dati che il backup non è in
/// grado di riscrivere. Sottoclasse perché la schermata mostra il messaggio di
/// [BackupFormatException] e questo caso vuole la stessa strada, non un
/// «non riesco a ripristinare» generico.
class BackupWouldLoseDataException extends BackupFormatException {
  const BackupWouldLoseDataException(super.message);

  @override
  String toString() => 'BackupWouldLoseDataException: $message';
}

class BackupDocument {
  const BackupDocument({
    required this.formatVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.profile,
    required this.meals,
    required this.mealItems,
    required this.nutritionTargets,
    required this.waterLogs,
    required this.bodyMeasurements,
    required this.foods,
    required this.foodPreferences,
    required this.fitRecipes,
    required this.recipeIngredients,
    required this.mealTemplates,
    required this.mealTemplateItems,
    this.bodyMeasurementValues = const [],
    this.exercises = const [],
    this.routines = const [],
    this.routineExercises = const [],
    this.routineIntervalSegments = const [],
    this.routineWeeklyPlan = const [],
    this.workouts = const [],
    this.workoutExercises = const [],
    this.workoutSets = const [],
    this.workoutPainPoints = const [],
    this.workoutIntervalSegments = const [],
    this.workoutProfileStats = const [],
    this.workoutAchievements = const [],
  });

  factory BackupDocument.decode(String raw) {
    final root = _asMap(_decodeJson(raw), 'backup');
    final formatVersion = _integer(root, 'format_version', minimum: 1);
    if (formatVersion > currentFormatVersion) {
      throw BackupFormatException(
        'Questo backup usa il formato $formatVersion: aggiorna Kal Tracker '
        'per poterlo ripristinare.',
      );
    }
    final data = _asMap(root['data'], 'data');
    final document = BackupDocument(
      formatVersion: formatVersion,
      appVersion: _text(root, 'app_version', max: 80),
      exportedAt: _instant(root, 'exported_at'),
      profile: BackupProfile.fromJson(_asMap(data['profile'], 'profile')),
      meals: [
        for (final row in _asRows(data, 'meals')) BackupMeal.fromJson(row),
      ],
      mealItems: [
        for (final row in _asRows(data, 'meal_items'))
          BackupMealItem.fromJson(row),
      ],
      nutritionTargets: [
        for (final row in _asRows(data, 'nutrition_targets'))
          BackupNutritionTarget.fromJson(row),
      ],
      waterLogs: [
        for (final row in _asRows(data, 'water_logs'))
          BackupWaterLog.fromJson(row),
      ],
      bodyMeasurements: [
        for (final row in _asRows(data, 'body_measurements'))
          BackupBodyMeasurement.fromJson(row),
      ],
      foods: [
        for (final row in _asRows(data, 'foods')) BackupFood.fromJson(row),
      ],
      foodPreferences: [
        for (final row in _asRows(data, 'food_preferences'))
          BackupFoodPreference.fromJson(row),
      ],
      fitRecipes: [
        for (final row in _asRows(data, 'fit_recipes'))
          BackupRecipe.fromJson(row),
      ],
      recipeIngredients: [
        for (final row in _asRows(data, 'recipe_ingredients'))
          BackupRecipeIngredient.fromJson(row),
      ],
      mealTemplates: [
        for (final row in _asRows(data, 'meal_templates'))
          BackupMealTemplate.fromJson(row),
      ],
      mealTemplateItems: [
        for (final row in _asRows(data, 'meal_template_items'))
          BackupMealTemplateItem.fromJson(row),
      ],
      bodyMeasurementValues: [
        for (final row in _asRows(data, 'body_measurement_values'))
          BackupBodyMeasurementValue.fromJson(row),
      ],
      exercises: [
        for (final row in _asRows(data, 'exercises'))
          BackupExercise.fromJson(row),
      ],
      routines: [
        for (final row in _asRows(data, 'routines'))
          BackupRoutine.fromJson(row),
      ],
      routineExercises: [
        for (final row in _asRows(data, 'routine_exercises'))
          BackupRoutineExercise.fromJson(row),
      ],
      routineIntervalSegments: [
        for (final row in _asRows(data, 'routine_interval_segments'))
          BackupRoutineIntervalSegment.fromJson(row),
      ],
      routineWeeklyPlan: [
        for (final row in _asRows(data, 'routine_weekly_plan'))
          BackupRoutineWeeklyPlanDay.fromJson(row),
      ],
      workouts: [
        for (final row in _asRows(data, 'workouts'))
          BackupWorkout.fromJson(row),
      ],
      workoutExercises: [
        for (final row in _asRows(data, 'workout_exercises'))
          BackupWorkoutExercise.fromJson(row),
      ],
      workoutSets: [
        for (final row in _asRows(data, 'workout_sets'))
          BackupWorkoutSet.fromJson(row),
      ],
      workoutPainPoints: [
        for (final row in _asRows(data, 'workout_pain_points'))
          BackupWorkoutPainPoint.fromJson(row),
      ],
      workoutIntervalSegments: [
        for (final row in _asRows(data, 'workout_interval_segments'))
          BackupWorkoutIntervalSegment.fromJson(row),
      ],
      workoutProfileStats: [
        for (final row in _asRows(data, 'workout_profile_stats'))
          BackupWorkoutProfileStats.fromJson(row),
      ],
      workoutAchievements: [
        for (final row in _asRows(data, 'workout_achievements'))
          BackupWorkoutAchievement.fromJson(row),
      ],
    );
    if (_text(root, 'checksum', max: 128) != document.checksum) {
      throw const BackupFormatException(
        'Il file di backup è danneggiato: il codice di controllo non '
        'corrisponde al contenuto.',
      );
    }
    return document;
  }

  /// Storia del formato:
  /// * **1** — il diario: pasti, obiettivi, acqua, peso, alimenti, ricette e
  ///   modelli.
  /// * **2** — aggiunge gli allenamenti (le tredici sezioni della v6 dello
  ///   schema) e la composizione corporea delle pesate.
  ///
  /// Un file della versione 1 si legge ancora e si ripristina: le sezioni
  /// nuove restano vuote. Un file della versione 2 su una app vecchia viene
  /// rifiutato dal controllo qui sotto, che non è cambiato.
  static const int currentFormatVersion = 2;

  /// Prima versione che contiene gli allenamenti. Serve a distinguere «il file
  /// non ha allenamenti perché non ne aveva» da «il file è di prima che
  /// esistessero»: solo il secondo caso non può essere usato per sostituire
  /// tutto senza perdere lo storico.
  static const int workoutsFormatVersion = 2;

  static const String unknownAppVersion = 'sconosciuta';

  final int formatVersion;
  final String appVersion;
  final DateTime exportedAt;
  final BackupProfile profile;
  final List<BackupMeal> meals;
  final List<BackupMealItem> mealItems;
  final List<BackupNutritionTarget> nutritionTargets;
  final List<BackupWaterLog> waterLogs;
  final List<BackupBodyMeasurement> bodyMeasurements;
  final List<BackupFood> foods;
  final List<BackupFoodPreference> foodPreferences;
  final List<BackupRecipe> fitRecipes;
  final List<BackupRecipeIngredient> recipeIngredients;
  final List<BackupMealTemplate> mealTemplates;
  final List<BackupMealTemplateItem> mealTemplateItems;
  final List<BackupBodyMeasurementValue> bodyMeasurementValues;
  final List<BackupExercise> exercises;
  final List<BackupRoutine> routines;
  final List<BackupRoutineExercise> routineExercises;
  final List<BackupRoutineIntervalSegment> routineIntervalSegments;
  final List<BackupRoutineWeeklyPlanDay> routineWeeklyPlan;
  final List<BackupWorkout> workouts;
  final List<BackupWorkoutExercise> workoutExercises;
  final List<BackupWorkoutSet> workoutSets;
  final List<BackupWorkoutPainPoint> workoutPainPoints;
  final List<BackupWorkoutIntervalSegment> workoutIntervalSegments;
  final List<BackupWorkoutProfileStats> workoutProfileStats;
  final List<BackupWorkoutAchievement> workoutAchievements;

  /// Vero quando il file è stato scritto quando gli allenamenti nel backup non
  /// esistevano ancora: le sezioni non sono vuote, sono assenti.
  bool get coversWorkouts => formatVersion >= workoutsFormatVersion;

  int get rowCount =>
      1 +
      meals.length +
      mealItems.length +
      nutritionTargets.length +
      waterLogs.length +
      bodyMeasurements.length +
      foods.length +
      foodPreferences.length +
      fitRecipes.length +
      recipeIngredients.length +
      mealTemplates.length +
      mealTemplateItems.length +
      bodyMeasurementValues.length +
      exercises.length +
      routines.length +
      routineExercises.length +
      routineIntervalSegments.length +
      routineWeeklyPlan.length +
      workouts.length +
      workoutExercises.length +
      workoutSets.length +
      workoutPainPoints.length +
      workoutIntervalSegments.length +
      workoutProfileStats.length +
      workoutAchievements.length;

  String get checksum =>
      sha256.convert(utf8.encode(jsonEncode(_body()))).toString();

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {..._body(), 'checksum': checksum};

  /// Il corpo su cui si calcola il checksum, nella forma della versione
  /// DICHIARATA dal documento.
  ///
  /// Le sezioni della versione 2 si scrivono solo se il documento è di quella
  /// versione: un file vecchio riletto qui dentro deve produrre gli stessi byte
  /// con cui è stato firmato, altrimenti aggiungere una sezione (anche vuota)
  /// farebbe risultare «danneggiato» ogni backup fatto prima.
  Map<String, Object?> _body() {
    final data = <String, Object?>{
      'profile': profile.toJson(),
      'meals': [for (final row in meals) row.toJson()],
      'meal_items': [for (final row in mealItems) row.toJson()],
      'nutrition_targets': [for (final row in nutritionTargets) row.toJson()],
      'water_logs': [for (final row in waterLogs) row.toJson()],
      'body_measurements': [
        for (final row in bodyMeasurements)
          row.toJson(withBodyComposition: coversWorkouts),
      ],
      'foods': [for (final row in foods) row.toJson()],
      'food_preferences': [for (final row in foodPreferences) row.toJson()],
      'fit_recipes': [for (final row in fitRecipes) row.toJson()],
      'recipe_ingredients': [for (final row in recipeIngredients) row.toJson()],
      'meal_templates': [for (final row in mealTemplates) row.toJson()],
      'meal_template_items': [
        for (final row in mealTemplateItems) row.toJson(),
      ],
    };
    if (coversWorkouts) {
      data.addAll({
        'body_measurement_values': [
          for (final row in bodyMeasurementValues) row.toJson(),
        ],
        'exercises': [for (final row in exercises) row.toJson()],
        'routines': [for (final row in routines) row.toJson()],
        'routine_exercises': [for (final row in routineExercises) row.toJson()],
        'routine_interval_segments': [
          for (final row in routineIntervalSegments) row.toJson(),
        ],
        'routine_weekly_plan': [
          for (final row in routineWeeklyPlan) row.toJson(),
        ],
        'workouts': [for (final row in workouts) row.toJson()],
        'workout_exercises': [for (final row in workoutExercises) row.toJson()],
        'workout_sets': [for (final row in workoutSets) row.toJson()],
        'workout_pain_points': [
          for (final row in workoutPainPoints) row.toJson(),
        ],
        'workout_interval_segments': [
          for (final row in workoutIntervalSegments) row.toJson(),
        ],
        'workout_profile_stats': [
          for (final row in workoutProfileStats) row.toJson(),
        ],
        'workout_achievements': [
          for (final row in workoutAchievements) row.toJson(),
        ],
      });
    }
    return {
      'format_version': formatVersion,
      'app_version': appVersion,
      'exported_at': _iso(exportedAt),
      'data': data,
    };
  }
}

class BackupProfile {
  const BackupProfile({
    required this.id,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BackupProfile.fromJson(Map<String, Object?> json) => BackupProfile(
    id: _text(json, 'id', max: 64),
    displayName: _text(json, 'display_name', max: 80),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
  );

  final String id;
  final String displayName;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'display_name': displayName,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
  };
}

class BackupMeal {
  const BackupMeal({
    required this.id,
    required this.profileId,
    required this.mealType,
    required this.eatenAt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory BackupMeal.fromJson(Map<String, Object?> json) => BackupMeal(
    id: _text(json, 'id', max: 64),
    profileId: _text(json, 'profile_id', max: 64),
    mealType: _text(json, 'meal_type', max: 16),
    eatenAt: _instant(json, 'eaten_at'),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String profileId;
  final String mealType;
  final DateTime eatenAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'meal_type': mealType,
    'eaten_at': _iso(eatenAt),
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupMealItem {
  const BackupMealItem({
    required this.id,
    required this.mealId,
    required this.foodName,
    required this.grams,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.carbsPer100g,
    required this.fatPer100g,
    required this.totalCalories,
    required this.totalProtein,
    required this.totalCarbs,
    required this.totalFat,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory BackupMealItem.fromJson(Map<String, Object?> json) => BackupMealItem(
    id: _text(json, 'id', max: 64),
    mealId: _text(json, 'meal_id', max: 64),
    foodName: _text(json, 'food_name', max: 160),
    grams: _decimal(json, 'grams', strictMinimum: true),
    caloriesPer100g: _decimal(json, 'calories_per_100g'),
    proteinPer100g: _decimal(json, 'protein_per_100g'),
    carbsPer100g: _decimal(json, 'carbs_per_100g'),
    fatPer100g: _decimal(json, 'fat_per_100g'),
    totalCalories: _decimal(json, 'total_calories'),
    totalProtein: _decimal(json, 'total_protein'),
    totalCarbs: _decimal(json, 'total_carbs'),
    totalFat: _decimal(json, 'total_fat'),
    source: _text(json, 'source', max: 32),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String mealId;
  final String foodName;
  final double grams;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double carbsPer100g;
  final double fatPer100g;
  final double totalCalories;
  final double totalProtein;
  final double totalCarbs;
  final double totalFat;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'meal_id': mealId,
    'food_name': foodName,
    'grams': grams,
    'calories_per_100g': caloriesPer100g,
    'protein_per_100g': proteinPer100g,
    'carbs_per_100g': carbsPer100g,
    'fat_per_100g': fatPer100g,
    'total_calories': totalCalories,
    'total_protein': totalProtein,
    'total_carbs': totalCarbs,
    'total_fat': totalFat,
    'source': source,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupNutritionTarget {
  const BackupNutritionTarget({
    required this.profileId,
    required this.dailyCalories,
    required this.dailyProtein,
    required this.dailyCarbs,
    required this.dailyFat,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory BackupNutritionTarget.fromJson(Map<String, Object?> json) =>
      BackupNutritionTarget(
        profileId: _text(json, 'profile_id', max: 64),
        dailyCalories: _decimal(json, 'daily_calories', strictMinimum: true),
        dailyProtein: _decimal(json, 'daily_protein'),
        dailyCarbs: _decimal(json, 'daily_carbs'),
        dailyFat: _decimal(json, 'daily_fat'),
        createdAt: _instant(json, 'created_at'),
        updatedAt: _instant(json, 'updated_at'),
        deletedAt: _optionalInstant(json, 'deleted_at'),
      );

  final String profileId;
  final double dailyCalories;
  final double dailyProtein;
  final double dailyCarbs;
  final double dailyFat;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'daily_calories': dailyCalories,
    'daily_protein': dailyProtein,
    'daily_carbs': dailyCarbs,
    'daily_fat': dailyFat,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupWaterLog {
  const BackupWaterLog({
    required this.id,
    required this.profileId,
    required this.milliliters,
    required this.loggedAt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory BackupWaterLog.fromJson(Map<String, Object?> json) => BackupWaterLog(
    id: _text(json, 'id', max: 64),
    profileId: _text(json, 'profile_id', max: 64),
    milliliters: _integer(json, 'milliliters', minimum: 1, maximum: 10000),
    loggedAt: _instant(json, 'logged_at'),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String profileId;
  final int milliliters;
  final DateTime loggedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'milliliters': milliliters,
    'logged_at': _iso(loggedAt),
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

/// Una pesata. Dalla versione 2 il file porta anche la composizione corporea:
/// l'impedenza è l'unica misura vera della bilancia e le percentuali sono
/// quelle prodotte da [formulaVersion], quindi vanno rimesse com'erano invece
/// di essere ricalcolate con la formula di oggi.
///
/// [source] e [externalId] sono la chiave con cui le importazioni si
/// deduplicano (`UNIQUE (profile_id, source, external_id)`): perderli farebbe
/// rientrare due volte la stessa pesata di Renpho al primo import dopo un
/// ripristino.
class BackupBodyMeasurement {
  const BackupBodyMeasurement({
    required this.id,
    required this.profileId,
    required this.weightKg,
    required this.measuredAt,
    required this.createdAt,
    required this.updatedAt,
    this.hasImpedance = false,
    this.impedanceOhm,
    this.bodyFatPct,
    this.musclePct,
    this.skeletalMusclePct,
    this.bonePct,
    this.proteinPct,
    this.waterPct,
    this.subcutaneousFatPct,
    this.visceralFatIndex,
    this.bmrKcal,
    this.formulaVersion,
    this.source = 'manual',
    this.externalId,
    this.note,
    this.deletedAt,
  });

  /// I campi della composizione mancano nei file della versione 1: assenti
  /// valgono «pesata senza impedenza, inserita a mano», che è esattamente ciò
  /// che quei backup contenevano.
  factory BackupBodyMeasurement.fromJson(Map<String, Object?> json) =>
      BackupBodyMeasurement(
        id: _text(json, 'id', max: 64),
        profileId: _text(json, 'profile_id', max: 64),
        weightKg: _decimal(json, 'weight_kg', minimum: 20, maximum: 500),
        measuredAt: _instant(json, 'measured_at'),
        hasImpedance: _flagOr(json, 'has_impedance', fallback: false),
        impedanceOhm: _optionalDecimal(
          json,
          'impedance_ohm',
          strictMinimum: true,
          maximum: 2000,
        ),
        bodyFatPct: _optionalDecimal(json, 'body_fat_pct', maximum: 100),
        musclePct: _optionalDecimal(json, 'muscle_pct', maximum: 100),
        skeletalMusclePct: _optionalDecimal(
          json,
          'skeletal_muscle_pct',
          maximum: 100,
        ),
        bonePct: _optionalDecimal(json, 'bone_pct', maximum: 100),
        proteinPct: _optionalDecimal(json, 'protein_pct', maximum: 100),
        waterPct: _optionalDecimal(json, 'water_pct', maximum: 100),
        subcutaneousFatPct: _optionalDecimal(
          json,
          'subcutaneous_fat_pct',
          maximum: 100,
        ),
        visceralFatIndex: _optionalInteger(
          json,
          'visceral_fat_index',
          minimum: 1,
          maximum: 60,
        ),
        bmrKcal: _optionalInteger(json, 'bmr_kcal', minimum: 1, maximum: 9999),
        formulaVersion: _optionalText(json, 'formula_version', max: 40),
        source: _textOr(json, 'source', fallback: 'manual', max: 30),
        externalId: _optionalText(json, 'external_id', max: 120),
        note: _optionalText(json, 'note', max: 240),
        createdAt: _instant(json, 'created_at'),
        updatedAt: _instant(json, 'updated_at'),
        deletedAt: _optionalInstant(json, 'deleted_at'),
      );

  final String id;
  final String profileId;
  final double weightKg;
  final DateTime measuredAt;
  final bool hasImpedance;
  final double? impedanceOhm;
  final double? bodyFatPct;
  final double? musclePct;
  final double? skeletalMusclePct;
  final double? bonePct;
  final double? proteinPct;
  final double? waterPct;
  final double? subcutaneousFatPct;
  final int? visceralFatIndex;
  final int? bmrKcal;
  final String? formulaVersion;
  final String source;
  final String? externalId;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson({bool withBodyComposition = true}) => {
    'id': id,
    'profile_id': profileId,
    'weight_kg': weightKg,
    'measured_at': _iso(measuredAt),
    if (withBodyComposition) ...{
      'has_impedance': hasImpedance,
      'impedance_ohm': impedanceOhm,
      'body_fat_pct': bodyFatPct,
      'muscle_pct': musclePct,
      'skeletal_muscle_pct': skeletalMusclePct,
      'bone_pct': bonePct,
      'protein_pct': proteinPct,
      'water_pct': waterPct,
      'subcutaneous_fat_pct': subcutaneousFatPct,
      'visceral_fat_index': visceralFatIndex,
      'bmr_kcal': bmrKcal,
      'formula_version': formulaVersion,
      'source': source,
      'external_id': externalId,
    },
    'note': note,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupFood {
  const BackupFood({
    required this.id,
    required this.name,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.carbsPer100g,
    required this.fatPer100g,
    required this.defaultServingGrams,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.ownerProfileId,
    this.brand,
    this.barcode,
    this.deletedAt,
  });

  factory BackupFood.fromJson(Map<String, Object?> json) => BackupFood(
    id: _text(json, 'id', max: 64),
    ownerProfileId: _optionalText(json, 'owner_profile_id', max: 64),
    name: _text(json, 'name', max: 160),
    brand: _optionalText(json, 'brand', max: 120),
    barcode: _optionalText(json, 'barcode', max: 32),
    caloriesPer100g: _decimal(json, 'calories_per_100g'),
    proteinPer100g: _decimal(json, 'protein_per_100g'),
    carbsPer100g: _decimal(json, 'carbs_per_100g'),
    fatPer100g: _decimal(json, 'fat_per_100g'),
    defaultServingGrams: _decimal(
      json,
      'default_serving_grams',
      strictMinimum: true,
    ),
    source: _text(json, 'source', max: 32),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String? ownerProfileId;
  final String name;
  final String? brand;
  final String? barcode;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double carbsPer100g;
  final double fatPer100g;
  final double defaultServingGrams;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'owner_profile_id': ownerProfileId,
    'name': name,
    'brand': brand,
    'barcode': barcode,
    'calories_per_100g': caloriesPer100g,
    'protein_per_100g': proteinPer100g,
    'carbs_per_100g': carbsPer100g,
    'fat_per_100g': fatPer100g,
    'default_serving_grams': defaultServingGrams,
    'source': source,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupFoodPreference {
  const BackupFoodPreference({
    required this.profileId,
    required this.foodId,
    required this.isFavorite,
    required this.useCount,
    required this.updatedAt,
    this.lastUsedAt,
  });

  factory BackupFoodPreference.fromJson(Map<String, Object?> json) =>
      BackupFoodPreference(
        profileId: _text(json, 'profile_id', max: 64),
        foodId: _text(json, 'food_id', max: 64),
        isFavorite: _flag(json, 'is_favorite'),
        useCount: _integer(json, 'use_count'),
        lastUsedAt: _optionalInstant(json, 'last_used_at'),
        updatedAt: _instant(json, 'updated_at'),
      );

  final String profileId;
  final String foodId;
  final bool isFavorite;
  final int useCount;
  final DateTime? lastUsedAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'food_id': foodId,
    'is_favorite': isFavorite,
    'use_count': useCount,
    'last_used_at': _isoOrNull(lastUsedAt),
    'updated_at': _iso(updatedAt),
  };
}

class BackupRecipe {
  const BackupRecipe({
    required this.id,
    required this.profileId,
    required this.name,
    required this.servings,
    required this.prepMinutes,
    required this.totalCalories,
    required this.totalProtein,
    required this.totalCarbs,
    required this.totalFat,
    required this.isFavorite,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.instructions,
    this.tags,
    this.deletedAt,
  });

  factory BackupRecipe.fromJson(Map<String, Object?> json) => BackupRecipe(
    id: _text(json, 'id', max: 64),
    profileId: _text(json, 'profile_id', max: 64),
    name: _text(json, 'name', max: 160),
    description: _optionalText(json, 'description', max: 600),
    instructions: _optionalText(json, 'instructions', max: 4000),
    tags: _optionalText(json, 'tags', max: 240),
    servings: _integer(json, 'servings', minimum: 1, maximum: 100),
    prepMinutes: _integer(json, 'prep_minutes', maximum: 10080),
    totalCalories: _decimal(json, 'total_calories'),
    totalProtein: _decimal(json, 'total_protein'),
    totalCarbs: _decimal(json, 'total_carbs'),
    totalFat: _decimal(json, 'total_fat'),
    isFavorite: _flag(json, 'is_favorite'),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String profileId;
  final String name;
  final String? description;
  final String? instructions;
  final String? tags;
  final int servings;
  final int prepMinutes;
  final double totalCalories;
  final double totalProtein;
  final double totalCarbs;
  final double totalFat;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'name': name,
    'description': description,
    'instructions': instructions,
    'tags': tags,
    'servings': servings,
    'prep_minutes': prepMinutes,
    'total_calories': totalCalories,
    'total_protein': totalProtein,
    'total_carbs': totalCarbs,
    'total_fat': totalFat,
    'is_favorite': isFavorite,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupRecipeIngredient {
  const BackupRecipeIngredient({
    required this.id,
    required this.recipeId,
    required this.position,
    required this.name,
    required this.grams,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.carbsPer100g,
    required this.fatPer100g,
    this.foodId,
  });

  factory BackupRecipeIngredient.fromJson(Map<String, Object?> json) =>
      BackupRecipeIngredient(
        id: _text(json, 'id', max: 64),
        recipeId: _text(json, 'recipe_id', max: 64),
        foodId: _optionalText(json, 'food_id', max: 64),
        position: _integer(json, 'position'),
        name: _text(json, 'name', max: 160),
        grams: _decimal(json, 'grams', strictMinimum: true),
        caloriesPer100g: _decimal(json, 'calories_per_100g'),
        proteinPer100g: _decimal(json, 'protein_per_100g'),
        carbsPer100g: _decimal(json, 'carbs_per_100g'),
        fatPer100g: _decimal(json, 'fat_per_100g'),
      );

  final String id;
  final String recipeId;
  final String? foodId;
  final int position;
  final String name;
  final double grams;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double carbsPer100g;
  final double fatPer100g;

  Map<String, Object?> toJson() => {
    'id': id,
    'recipe_id': recipeId,
    'food_id': foodId,
    'position': position,
    'name': name,
    'grams': grams,
    'calories_per_100g': caloriesPer100g,
    'protein_per_100g': proteinPer100g,
    'carbs_per_100g': carbsPer100g,
    'fat_per_100g': fatPer100g,
  };
}

class BackupMealTemplate {
  const BackupMealTemplate({
    required this.id,
    required this.profileId,
    required this.name,
    required this.mealType,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory BackupMealTemplate.fromJson(Map<String, Object?> json) =>
      BackupMealTemplate(
        id: _text(json, 'id', max: 64),
        profileId: _text(json, 'profile_id', max: 64),
        name: _text(json, 'name', max: 80),
        mealType: _text(json, 'meal_type', max: 16),
        createdAt: _instant(json, 'created_at'),
        updatedAt: _instant(json, 'updated_at'),
        deletedAt: _optionalInstant(json, 'deleted_at'),
      );

  final String id;
  final String profileId;
  final String name;
  final String mealType;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'name': name,
    'meal_type': mealType,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

class BackupMealTemplateItem {
  const BackupMealTemplateItem({
    required this.id,
    required this.templateId,
    required this.position,
    required this.foodName,
    required this.grams,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.carbsPer100g,
    required this.fatPer100g,
  });

  factory BackupMealTemplateItem.fromJson(Map<String, Object?> json) =>
      BackupMealTemplateItem(
        id: _text(json, 'id', max: 64),
        templateId: _text(json, 'template_id', max: 64),
        position: _integer(json, 'position'),
        foodName: _text(json, 'food_name', max: 160),
        grams: _decimal(json, 'grams', strictMinimum: true),
        caloriesPer100g: _decimal(json, 'calories_per_100g'),
        proteinPer100g: _decimal(json, 'protein_per_100g'),
        carbsPer100g: _decimal(json, 'carbs_per_100g'),
        fatPer100g: _decimal(json, 'fat_per_100g'),
      );

  final String id;
  final String templateId;
  final int position;
  final String foodName;
  final double grams;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double carbsPer100g;
  final double fatPer100g;

  Map<String, Object?> toJson() => {
    'id': id,
    'template_id': templateId,
    'position': position,
    'food_name': foodName,
    'grams': grams,
    'calories_per_100g': caloriesPer100g,
    'protein_per_100g': proteinPer100g,
    'carbs_per_100g': carbsPer100g,
    'fat_per_100g': fatPer100g,
  };
}

/// Una circonferenza libera di una pesata ('Vita', 'Braccio', …).
class BackupBodyMeasurementValue {
  const BackupBodyMeasurementValue({
    required this.id,
    required this.measurementId,
    required this.label,
    required this.value,
  });

  factory BackupBodyMeasurementValue.fromJson(Map<String, Object?> json) =>
      BackupBodyMeasurementValue(
        id: _text(json, 'id', max: 64),
        measurementId: _text(json, 'measurement_id', max: 64),
        label: _text(json, 'label', max: 40),
        value: _decimal(json, 'value', strictMinimum: true, maximum: 1000),
      );

  final String id;
  final String measurementId;
  final String label;
  final double value;

  Map<String, Object?> toJson() => {
    'id': id,
    'measurement_id': measurementId,
    'label': label,
    'value': value,
  };
}

/// Un esercizio del catalogo. [isSynthetic] marca le righe di defaticamento
/// generate dall'app: si salvano lo stesso perché lo storico le cita per id.
class BackupExercise {
  const BackupExercise({
    required this.id,
    required this.profileId,
    required this.name,
    required this.muscleGroup,
    required this.trackingMode,
    required this.isPreset,
    required this.isSynthetic,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.imageUrl,
    this.defaultRestSec,
    this.externalId,
    this.deletedAt,
  });

  factory BackupExercise.fromJson(Map<String, Object?> json) => BackupExercise(
    id: _text(json, 'id', max: 64),
    profileId: _text(json, 'profile_id', max: 64),
    name: _text(json, 'name', max: 160),
    muscleGroup: _text(json, 'muscle_group', max: 16),
    trackingMode: _text(json, 'tracking_mode', max: 16),
    notes: _optionalText(json, 'notes', max: 600),
    imageUrl: _optionalText(json, 'image_url', max: 500),
    defaultRestSec: _optionalInteger(json, 'default_rest_sec', maximum: 3600),
    isPreset: _flag(json, 'is_preset'),
    isSynthetic: _flag(json, 'is_synthetic'),
    source: _text(json, 'source', max: 30),
    externalId: _optionalText(json, 'external_id', max: 120),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String profileId;
  final String name;
  final String muscleGroup;
  final String trackingMode;
  final String? notes;
  final String? imageUrl;
  final int? defaultRestSec;
  final bool isPreset;
  final bool isSynthetic;
  final String source;
  final String? externalId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'name': name,
    'muscle_group': muscleGroup,
    'tracking_mode': trackingMode,
    'notes': notes,
    'image_url': imageUrl,
    'default_rest_sec': defaultRestSec,
    'is_preset': isPreset,
    'is_synthetic': isSynthetic,
    'source': source,
    'external_id': externalId,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

/// Una scheda. I sei parametri a tempo servono ai circuiti ma esistono sempre:
/// sono la configurazione proposta, non un dato opzionale.
class BackupRoutine {
  const BackupRoutine({
    required this.id,
    required this.profileId,
    required this.name,
    required this.isCircuit,
    required this.workSec,
    required this.shortRestSec,
    required this.longRestSec,
    required this.rounds,
    required this.warmupWorkSec,
    required this.warmupRestSec,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.externalId,
    this.deletedAt,
  });

  factory BackupRoutine.fromJson(Map<String, Object?> json) => BackupRoutine(
    id: _text(json, 'id', max: 64),
    profileId: _text(json, 'profile_id', max: 64),
    name: _text(json, 'name', max: 160),
    notes: _optionalText(json, 'notes', max: 1000),
    isCircuit: _flag(json, 'is_circuit'),
    workSec: _integer(json, 'work_sec', minimum: 1, maximum: 3600),
    shortRestSec: _integer(json, 'short_rest_sec', maximum: 3600),
    longRestSec: _integer(json, 'long_rest_sec', maximum: 3600),
    rounds: _integer(json, 'rounds', minimum: 1, maximum: 50),
    warmupWorkSec: _integer(json, 'warmup_work_sec', minimum: 1, maximum: 3600),
    warmupRestSec: _integer(json, 'warmup_rest_sec', maximum: 3600),
    source: _text(json, 'source', max: 30),
    externalId: _optionalText(json, 'external_id', max: 120),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String profileId;
  final String name;
  final String? notes;
  final bool isCircuit;
  final int workSec;
  final int shortRestSec;
  final int longRestSec;
  final int rounds;
  final int warmupWorkSec;
  final int warmupRestSec;
  final String source;
  final String? externalId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'name': name,
    'notes': notes,
    'is_circuit': isCircuit,
    'work_sec': workSec,
    'short_rest_sec': shortRestSec,
    'long_rest_sec': longRestSec,
    'rounds': rounds,
    'warmup_work_sec': warmupWorkSec,
    'warmup_rest_sec': warmupRestSec,
    'source': source,
    'external_id': externalId,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

/// Una riga di scheda: riscaldamento, blocco principale o finisher.
/// [exerciseId] è la sola FK e può essere nulla; [exerciseRefId] non lo è mai
/// ed è la chiave con cui il dominio raggruppa.
class BackupRoutineExercise {
  const BackupRoutineExercise({
    required this.id,
    required this.routineId,
    required this.block,
    required this.position,
    required this.exerciseRefId,
    required this.exerciseNameSnapshot,
    required this.inSupersetWithPrevious,
    this.exerciseId,
    this.warmupDurationSec,
    this.prescSets,
    this.prescReps,
    this.prescDurationSec,
    this.prescRestSec,
  });

  factory BackupRoutineExercise.fromJson(
    Map<String, Object?> json,
  ) => BackupRoutineExercise(
    id: _text(json, 'id', max: 64),
    routineId: _text(json, 'routine_id', max: 64),
    block: _text(json, 'block', max: 10),
    position: _integer(json, 'position'),
    exerciseRefId: _text(json, 'exercise_ref_id', max: 64),
    exerciseId: _optionalText(json, 'exercise_id', max: 64),
    exerciseNameSnapshot: _text(json, 'exercise_name_snapshot', max: 160),
    inSupersetWithPrevious: _flag(json, 'in_superset_with_previous'),
    warmupDurationSec: _optionalInteger(
      json,
      'warmup_duration_sec',
      minimum: 1,
      maximum: 3600,
    ),
    prescSets: _optionalInteger(json, 'presc_sets', minimum: 1, maximum: 50),
    prescReps: _optionalInteger(json, 'presc_reps', minimum: 1, maximum: 500),
    prescDurationSec: _optionalInteger(
      json,
      'presc_duration_sec',
      minimum: 1,
      maximum: 7200,
    ),
    prescRestSec: _optionalInteger(json, 'presc_rest_sec', maximum: 3600),
  );

  final String id;
  final String routineId;
  final String block;
  final int position;
  final String exerciseRefId;
  final String? exerciseId;
  final String exerciseNameSnapshot;
  final bool inSupersetWithPrevious;
  final int? warmupDurationSec;
  final int? prescSets;
  final int? prescReps;
  final int? prescDurationSec;
  final int? prescRestSec;

  Map<String, Object?> toJson() => {
    'id': id,
    'routine_id': routineId,
    'block': block,
    'position': position,
    'exercise_ref_id': exerciseRefId,
    'exercise_id': exerciseId,
    'exercise_name_snapshot': exerciseNameSnapshot,
    'in_superset_with_previous': inSupersetWithPrevious,
    'warmup_duration_sec': warmupDurationSec,
    'presc_sets': prescSets,
    'presc_reps': prescReps,
    'presc_duration_sec': prescDurationSec,
    'presc_rest_sec': prescRestSec,
  };
}

/// Un blocco a tempo della scheda: finestra [startIdx, endIdx) sulle posizioni
/// del blocco principale.
class BackupRoutineIntervalSegment {
  const BackupRoutineIntervalSegment({
    required this.id,
    required this.routineId,
    required this.segmentIndex,
    required this.startIdx,
    required this.endIdx,
    required this.workSec,
    required this.restSec,
    required this.longRestSec,
    required this.rounds,
  });

  factory BackupRoutineIntervalSegment.fromJson(Map<String, Object?> json) =>
      BackupRoutineIntervalSegment(
        id: _text(json, 'id', max: 64),
        routineId: _text(json, 'routine_id', max: 64),
        segmentIndex: _integer(json, 'segment_index'),
        startIdx: _integer(json, 'start_idx'),
        endIdx: _integer(json, 'end_idx', minimum: 1),
        workSec: _integer(json, 'work_sec', minimum: 1, maximum: 3600),
        restSec: _integer(json, 'rest_sec', maximum: 3600),
        longRestSec: _integer(json, 'long_rest_sec', maximum: 3600),
        rounds: _integer(json, 'rounds', minimum: 1, maximum: 50),
      );

  final String id;
  final String routineId;
  final int segmentIndex;
  final int startIdx;
  final int endIdx;
  final int workSec;
  final int restSec;
  final int longRestSec;
  final int rounds;

  Map<String, Object?> toJson() => {
    'id': id,
    'routine_id': routineId,
    'segment_index': segmentIndex,
    'start_idx': startIdx,
    'end_idx': endIdx,
    'work_sec': workSec,
    'rest_sec': restSec,
    'long_rest_sec': longRestSec,
    'rounds': rounds,
  };
}

/// Un giorno del piano settimanale. I giorni di riposo non sono righe: la
/// riga mancante È l'informazione.
class BackupRoutineWeeklyPlanDay {
  const BackupRoutineWeeklyPlanDay({
    required this.id,
    required this.profileId,
    required this.weekday,
    required this.updatedAt,
    this.routineId,
    this.routineExternalId,
    this.routineNameSnapshot,
  });

  factory BackupRoutineWeeklyPlanDay.fromJson(Map<String, Object?> json) =>
      BackupRoutineWeeklyPlanDay(
        id: _text(json, 'id', max: 64),
        profileId: _text(json, 'profile_id', max: 64),
        weekday: _integer(json, 'weekday', minimum: 1, maximum: 7),
        routineId: _optionalText(json, 'routine_id', max: 64),
        routineExternalId: _optionalText(json, 'routine_external_id', max: 120),
        routineNameSnapshot: _optionalText(
          json,
          'routine_name_snapshot',
          max: 160,
        ),
        updatedAt: _instant(json, 'updated_at'),
      );

  final String id;
  final String profileId;
  final int weekday;
  final String? routineId;
  final String? routineExternalId;
  final String? routineNameSnapshot;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'weekday': weekday,
    'routine_id': routineId,
    'routine_external_id': routineExternalId,
    'routine_name_snapshot': routineNameSnapshot,
    'updated_at': _iso(updatedAt),
  };
}

/// Una sessione. Le due durate NON hanno tetto: il clamp a 24 ore è una regola
/// di lettura, e rifiutarle qui renderebbe irripristinabile la sessione
/// rimasta aperta 536 ore.
class BackupWorkout {
  const BackupWorkout({
    required this.id,
    required this.profileId,
    required this.startedAt,
    required this.accumulatedPauseSeconds,
    required this.durationSuspect,
    required this.syncedToHealthConnect,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    this.endedAt,
    this.pausedAt,
    this.finalDurationSeconds,
    this.routineId,
    this.routineExternalId,
    this.routineNameSnapshot,
    this.notes,
    this.totalKcal,
    this.mood,
    this.rpe,
    this.satisfaction,
    this.feedbackNotes,
    this.xpEarned,
    this.resumePath,
    this.circuitCheckpointJson,
    this.healthSyncState,
    this.healthSyncClaimId,
    this.healthSyncAttemptedAt,
    this.healthSyncCompletedAt,
    this.externalId,
    this.deletedAt,
  });

  factory BackupWorkout.fromJson(Map<String, Object?> json) => BackupWorkout(
    id: _text(json, 'id', max: 64),
    profileId: _text(json, 'profile_id', max: 64),
    startedAt: _instant(json, 'started_at'),
    endedAt: _optionalInstant(json, 'ended_at'),
    pausedAt: _optionalInstant(json, 'paused_at'),
    accumulatedPauseSeconds: _integer(json, 'accumulated_pause_seconds'),
    finalDurationSeconds: _optionalInteger(json, 'final_duration_seconds'),
    durationSuspect: _flag(json, 'duration_suspect'),
    routineId: _optionalText(json, 'routine_id', max: 64),
    routineExternalId: _optionalText(json, 'routine_external_id', max: 120),
    routineNameSnapshot: _optionalText(json, 'routine_name_snapshot', max: 160),
    notes: _optionalText(json, 'notes', max: 1000),
    totalKcal: _optionalDecimal(json, 'total_kcal'),
    mood: _optionalInteger(json, 'mood', minimum: 1, maximum: 5),
    rpe: _optionalInteger(json, 'rpe', minimum: 1, maximum: 10),
    satisfaction: _optionalInteger(
      json,
      'satisfaction',
      minimum: 1,
      maximum: 5,
    ),
    feedbackNotes: _optionalText(json, 'feedback_notes', max: 1000),
    xpEarned: _optionalInteger(json, 'xp_earned'),
    resumePath: _optionalText(json, 'resume_path', max: 200),
    circuitCheckpointJson: _optionalText(
      json,
      'circuit_checkpoint_json',
      max: 20000,
    ),
    syncedToHealthConnect: _flag(json, 'synced_to_health_connect'),
    healthSyncState: _optionalText(json, 'health_sync_state', max: 12),
    healthSyncClaimId: _optionalText(json, 'health_sync_claim_id', max: 64),
    healthSyncAttemptedAt: _optionalInstant(json, 'health_sync_attempted_at'),
    healthSyncCompletedAt: _optionalInstant(json, 'health_sync_completed_at'),
    source: _text(json, 'source', max: 30),
    externalId: _optionalText(json, 'external_id', max: 120),
    createdAt: _instant(json, 'created_at'),
    updatedAt: _instant(json, 'updated_at'),
    deletedAt: _optionalInstant(json, 'deleted_at'),
  );

  final String id;
  final String profileId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime? pausedAt;
  final int accumulatedPauseSeconds;
  final int? finalDurationSeconds;
  final bool durationSuspect;
  final String? routineId;
  final String? routineExternalId;
  final String? routineNameSnapshot;
  final String? notes;
  final double? totalKcal;
  final int? mood;
  final int? rpe;
  final int? satisfaction;
  final String? feedbackNotes;
  final int? xpEarned;
  final String? resumePath;
  final String? circuitCheckpointJson;
  final bool syncedToHealthConnect;
  final String? healthSyncState;
  final String? healthSyncClaimId;
  final DateTime? healthSyncAttemptedAt;
  final DateTime? healthSyncCompletedAt;
  final String source;
  final String? externalId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'started_at': _iso(startedAt),
    'ended_at': _isoOrNull(endedAt),
    'paused_at': _isoOrNull(pausedAt),
    'accumulated_pause_seconds': accumulatedPauseSeconds,
    'final_duration_seconds': finalDurationSeconds,
    'duration_suspect': durationSuspect,
    'routine_id': routineId,
    'routine_external_id': routineExternalId,
    'routine_name_snapshot': routineNameSnapshot,
    'notes': notes,
    'total_kcal': totalKcal,
    'mood': mood,
    'rpe': rpe,
    'satisfaction': satisfaction,
    'feedback_notes': feedbackNotes,
    'xp_earned': xpEarned,
    'resume_path': resumePath,
    'circuit_checkpoint_json': circuitCheckpointJson,
    'synced_to_health_connect': syncedToHealthConnect,
    'health_sync_state': healthSyncState,
    'health_sync_claim_id': healthSyncClaimId,
    'health_sync_attempted_at': _isoOrNull(healthSyncAttemptedAt),
    'health_sync_completed_at': _isoOrNull(healthSyncCompletedAt),
    'source': source,
    'external_id': externalId,
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

/// Una riga della sessione. Nome, modalità e gruppo muscolare sono congelati:
/// sono ciò che valeva QUEL giorno, non ciò che dice il catalogo oggi.
class BackupWorkoutExercise {
  const BackupWorkoutExercise({
    required this.id,
    required this.workoutId,
    required this.position,
    required this.exerciseRefId,
    required this.exerciseNameSnapshot,
    required this.trackingMode,
    required this.isWarmup,
    required this.isCooldown,
    required this.isFinisher,
    required this.isInSupersetWithPrevious,
    this.exerciseId,
    this.muscleGroupSnapshot,
    this.restSeconds,
    this.intervalSegmentIndex,
  });

  factory BackupWorkoutExercise.fromJson(Map<String, Object?> json) =>
      BackupWorkoutExercise(
        id: _text(json, 'id', max: 64),
        workoutId: _text(json, 'workout_id', max: 64),
        position: _integer(json, 'position'),
        exerciseRefId: _text(json, 'exercise_ref_id', max: 64),
        exerciseId: _optionalText(json, 'exercise_id', max: 64),
        exerciseNameSnapshot: _text(json, 'exercise_name_snapshot', max: 160),
        trackingMode: _text(json, 'tracking_mode', max: 16),
        muscleGroupSnapshot: _optionalText(
          json,
          'muscle_group_snapshot',
          max: 16,
        ),
        restSeconds: _optionalInteger(json, 'rest_seconds', maximum: 3600),
        isWarmup: _flag(json, 'is_warmup'),
        isCooldown: _flag(json, 'is_cooldown'),
        isFinisher: _flag(json, 'is_finisher'),
        isInSupersetWithPrevious: _flag(json, 'is_in_superset_with_previous'),
        intervalSegmentIndex: _optionalInteger(json, 'interval_segment_index'),
      );

  final String id;
  final String workoutId;
  final int position;
  final String exerciseRefId;
  final String? exerciseId;
  final String exerciseNameSnapshot;
  final String trackingMode;
  final String? muscleGroupSnapshot;
  final int? restSeconds;
  final bool isWarmup;
  final bool isCooldown;
  final bool isFinisher;
  final bool isInSupersetWithPrevious;
  final int? intervalSegmentIndex;

  Map<String, Object?> toJson() => {
    'id': id,
    'workout_id': workoutId,
    'position': position,
    'exercise_ref_id': exerciseRefId,
    'exercise_id': exerciseId,
    'exercise_name_snapshot': exerciseNameSnapshot,
    'tracking_mode': trackingMode,
    'muscle_group_snapshot': muscleGroupSnapshot,
    'rest_seconds': restSeconds,
    'is_warmup': isWarmup,
    'is_cooldown': isCooldown,
    'is_finisher': isFinisher,
    'is_in_superset_with_previous': isInSupersetWithPrevious,
    'interval_segment_index': intervalSegmentIndex,
  };
}

/// Una serie. Le cinque metriche restano nulle quando non sono state inserite:
/// «non inserito» e «zero» sono due cose diverse.
class BackupWorkoutSet {
  const BackupWorkoutSet({
    required this.id,
    required this.workoutExerciseId,
    required this.position,
    required this.isWarmup,
    required this.completed,
    this.weightKg,
    this.reps,
    this.durationSec,
    this.distanceM,
    this.rpe,
  });

  factory BackupWorkoutSet.fromJson(Map<String, Object?> json) =>
      BackupWorkoutSet(
        id: _text(json, 'id', max: 64),
        workoutExerciseId: _text(json, 'workout_exercise_id', max: 64),
        position: _integer(json, 'position'),
        weightKg: _optionalDecimal(json, 'weight_kg', maximum: 1000),
        reps: _optionalInteger(json, 'reps', maximum: 1000),
        durationSec: _optionalInteger(json, 'duration_sec', maximum: 86400),
        distanceM: _optionalDecimal(json, 'distance_m', maximum: 200000),
        rpe: _optionalInteger(json, 'rpe', minimum: 1, maximum: 10),
        isWarmup: _flag(json, 'is_warmup'),
        completed: _flag(json, 'completed'),
      );

  final String id;
  final String workoutExerciseId;
  final int position;
  final double? weightKg;
  final int? reps;
  final int? durationSec;
  final double? distanceM;
  final int? rpe;
  final bool isWarmup;
  final bool completed;

  Map<String, Object?> toJson() => {
    'id': id,
    'workout_exercise_id': workoutExerciseId,
    'position': position,
    'weight_kg': weightKg,
    'reps': reps,
    'duration_sec': durationSec,
    'distance_m': distanceM,
    'rpe': rpe,
    'is_warmup': isWarmup,
    'completed': completed,
  };
}

/// Un punto dolente segnalato a fine sessione.
class BackupWorkoutPainPoint {
  const BackupWorkoutPainPoint({
    required this.id,
    required this.workoutId,
    required this.label,
  });

  factory BackupWorkoutPainPoint.fromJson(Map<String, Object?> json) =>
      BackupWorkoutPainPoint(
        id: _text(json, 'id', max: 64),
        workoutId: _text(json, 'workout_id', max: 64),
        label: _text(json, 'label', max: 40),
      );

  final String id;
  final String workoutId;
  final String label;

  Map<String, Object?> toJson() => {
    'id': id,
    'workout_id': workoutId,
    'label': label,
  };
}

/// Marcatore di un blocco a tempo dentro una sessione. I due marcatori NON
/// sono alternativi: lo stesso segmento può essere completato e ripreso
/// parzialmente, e la ripresa del circuito dipende da entrambi.
class BackupWorkoutIntervalSegment {
  const BackupWorkoutIntervalSegment({
    required this.id,
    required this.workoutId,
    required this.segmentIndex,
    required this.completedMarker,
    required this.partialMarker,
    this.completionSignature,
  });

  factory BackupWorkoutIntervalSegment.fromJson(Map<String, Object?> json) =>
      BackupWorkoutIntervalSegment(
        id: _text(json, 'id', max: 64),
        workoutId: _text(json, 'workout_id', max: 64),
        segmentIndex: _integer(json, 'segment_index'),
        completedMarker: _flag(json, 'completed_marker'),
        partialMarker: _flag(json, 'partial_marker'),
        completionSignature: _optionalText(
          json,
          'completion_signature',
          max: 20000,
        ),
      );

  final String id;
  final String workoutId;
  final int segmentIndex;
  final bool completedMarker;
  final bool partialMarker;
  final String? completionSignature;

  Map<String, Object?> toJson() => {
    'id': id,
    'workout_id': workoutId,
    'segment_index': segmentIndex,
    'completed_marker': completedMarker,
    'partial_marker': partialMarker,
    'completion_signature': completionSignature,
  };
}

/// XP, streak e preferenze di allenamento del profilo.
///
/// [totalXp] è un valore copiato e non ricalcolabile: se il backup non lo
/// riporta, il livello di Marco torna indietro di migliaia di punti.
class BackupWorkoutProfileStats {
  const BackupWorkoutProfileStats({
    required this.id,
    required this.profileId,
    required this.totalXp,
    required this.currentStreak,
    required this.longestStreak,
    required this.weeklyWorkoutGoal,
    required this.weeklyKcalGoal,
    required this.reminderEnabled,
    required this.reminderHour,
    required this.reminderMinute,
    required this.healthConnectEnabled,
    required this.voiceEnabled,
    required this.createdAt,
    required this.updatedAt,
    this.lastWorkoutDay,
    this.gymBodyWeightKg,
    this.gymExportedAt,
    this.deletedAt,
  });

  factory BackupWorkoutProfileStats.fromJson(Map<String, Object?> json) =>
      BackupWorkoutProfileStats(
        id: _text(json, 'id', max: 64),
        profileId: _text(json, 'profile_id', max: 64),
        totalXp: _integer(json, 'total_xp'),
        currentStreak: _integer(json, 'current_streak'),
        longestStreak: _integer(json, 'longest_streak'),
        lastWorkoutDay: _optionalInstant(json, 'last_workout_day'),
        weeklyWorkoutGoal: _integer(
          json,
          'weekly_workout_goal',
          minimum: 1,
          maximum: 14,
        ),
        weeklyKcalGoal: _integer(json, 'weekly_kcal_goal', maximum: 100000),
        reminderEnabled: _flag(json, 'reminder_enabled'),
        reminderHour: _integer(json, 'reminder_hour', maximum: 23),
        reminderMinute: _integer(json, 'reminder_minute', maximum: 59),
        healthConnectEnabled: _flag(json, 'health_connect_enabled'),
        voiceEnabled: _flag(json, 'voice_enabled'),
        gymBodyWeightKg: _optionalDecimal(
          json,
          'gym_body_weight_kg',
          minimum: 20,
          maximum: 500,
        ),
        gymExportedAt: _optionalInstant(json, 'gym_exported_at'),
        createdAt: _instant(json, 'created_at'),
        updatedAt: _instant(json, 'updated_at'),
        deletedAt: _optionalInstant(json, 'deleted_at'),
      );

  final String id;
  final String profileId;
  final int totalXp;
  final int currentStreak;
  final int longestStreak;
  final DateTime? lastWorkoutDay;
  final int weeklyWorkoutGoal;
  final int weeklyKcalGoal;
  final bool reminderEnabled;
  final int reminderHour;
  final int reminderMinute;
  final bool healthConnectEnabled;
  final bool voiceEnabled;
  final double? gymBodyWeightKg;
  final DateTime? gymExportedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'total_xp': totalXp,
    'current_streak': currentStreak,
    'longest_streak': longestStreak,
    'last_workout_day': _isoOrNull(lastWorkoutDay),
    'weekly_workout_goal': weeklyWorkoutGoal,
    'weekly_kcal_goal': weeklyKcalGoal,
    'reminder_enabled': reminderEnabled,
    'reminder_hour': reminderHour,
    'reminder_minute': reminderMinute,
    'health_connect_enabled': healthConnectEnabled,
    'voice_enabled': voiceEnabled,
    'gym_body_weight_kg': gymBodyWeightKg,
    'gym_exported_at': _isoOrNull(gymExportedAt),
    'created_at': _iso(createdAt),
    'updated_at': _iso(updatedAt),
    'deleted_at': _isoOrNull(deletedAt),
  };
}

/// Un trofeo sbloccato. Di persistito c'è lo slug: il catalogo è codice, e uno
/// slug perso significa un traguardo che si rivince col suo bonus XP.
class BackupWorkoutAchievement {
  const BackupWorkoutAchievement({
    required this.id,
    required this.profileId,
    required this.slug,
    this.unlockedAt,
  });

  factory BackupWorkoutAchievement.fromJson(Map<String, Object?> json) =>
      BackupWorkoutAchievement(
        id: _text(json, 'id', max: 64),
        profileId: _text(json, 'profile_id', max: 64),
        slug: _text(json, 'slug', max: 60),
        unlockedAt: _optionalInstant(json, 'unlocked_at'),
      );

  final String id;
  final String profileId;
  final String slug;
  final DateTime? unlockedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'slug': slug,
    'unlocked_at': _isoOrNull(unlockedAt),
  };
}

Object? _decodeJson(String raw) {
  try {
    return jsonDecode(raw);
  } on FormatException {
    throw const BackupFormatException(
      'Il file di backup non è un JSON valido.',
    );
  }
}

Map<String, Object?> _asMap(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw BackupFormatException('La sezione «$label» del backup non è valida.');
  }
  return value;
}

List<Map<String, Object?>> _asRows(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw BackupFormatException('L’elenco «$key» del backup non è valido.');
  }
  return [for (final row in value) _asMap(row, key)];
}

String _text(Map<String, Object?> json, String key, {required int max}) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw BackupFormatException(
      'Il campo «$key» del backup è mancante o vuoto.',
    );
  }
  if (value.length > max) {
    throw BackupFormatException('Il campo «$key» del backup è troppo lungo.');
  }
  return value;
}

String? _optionalText(
  Map<String, Object?> json,
  String key, {
  required int max,
}) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw BackupFormatException('Il campo «$key» del backup non è valido.');
  }
  if (value.length > max) {
    throw BackupFormatException('Il campo «$key» del backup è troppo lungo.');
  }
  return value;
}

double _decimal(
  Map<String, Object?> json,
  String key, {
  double minimum = 0,
  double? maximum,
  bool strictMinimum = false,
}) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw BackupFormatException(
      'Il valore «$key» del backup non è un numero valido.',
    );
  }
  final result = value.toDouble();
  final tooSmall = strictMinimum ? result <= minimum : result < minimum;
  if (tooSmall || (maximum != null && result > maximum)) {
    throw BackupFormatException(
      'Il valore «$key» del backup non è consentito ($result).',
    );
  }
  return result;
}

int _integer(
  Map<String, Object?> json,
  String key, {
  int minimum = 0,
  int? maximum,
}) {
  final value = json[key];
  if (value is! int) {
    throw BackupFormatException(
      'Il valore «$key» del backup non è un numero intero.',
    );
  }
  if (value < minimum || (maximum != null && value > maximum)) {
    throw BackupFormatException(
      'Il valore «$key» del backup non è consentito ($value).',
    );
  }
  return value;
}

double? _optionalDecimal(
  Map<String, Object?> json,
  String key, {
  double minimum = 0,
  double? maximum,
  bool strictMinimum = false,
}) {
  if (json[key] == null) {
    return null;
  }
  return _decimal(
    json,
    key,
    minimum: minimum,
    maximum: maximum,
    strictMinimum: strictMinimum,
  );
}

int? _optionalInteger(
  Map<String, Object?> json,
  String key, {
  int minimum = 0,
  int? maximum,
}) {
  if (json[key] == null) {
    return null;
  }
  return _integer(json, key, minimum: minimum, maximum: maximum);
}

bool _flag(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw BackupFormatException('Il campo «$key» del backup non è valido.');
  }
  return value;
}

/// Come [_flag], ma la chiave assente vale [fallback] invece di essere un
/// errore: serve alle colonne aggiunte dopo, che i backup più vecchi non hanno.
bool _flagOr(Map<String, Object?> json, String key, {required bool fallback}) =>
    json.containsKey(key) ? _flag(json, key) : fallback;

/// Come [_text], ma la chiave assente vale [fallback]: stessa ragione di
/// [_flagOr].
String _textOr(
  Map<String, Object?> json,
  String key, {
  required String fallback,
  required int max,
}) => json[key] == null ? fallback : _text(json, key, max: max);

DateTime _instant(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw BackupFormatException('La data «$key» del backup è mancante.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw BackupFormatException('La data «$key» del backup non è valida.');
  }
  return parsed.toUtc();
}

DateTime? _optionalInstant(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  return _instant(json, key);
}

String _iso(DateTime value) => value.toUtc().toIso8601String();

String? _isoOrNull(DateTime? value) => value == null ? null : _iso(value);
