import 'dart:convert';

import 'package:crypto/crypto.dart';

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => 'BackupFormatException: $message';
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
    );
    if (_text(root, 'checksum', max: 128) != document.checksum) {
      throw const BackupFormatException(
        'Il file di backup è danneggiato: il codice di controllo non '
        'corrisponde al contenuto.',
      );
    }
    return document;
  }

  static const int currentFormatVersion = 1;
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
      mealTemplateItems.length;

  String get checksum =>
      sha256.convert(utf8.encode(jsonEncode(_body()))).toString();

  String encode() => jsonEncode(toJson());

  Map<String, Object?> toJson() => {..._body(), 'checksum': checksum};

  Map<String, Object?> _body() => {
    'format_version': formatVersion,
    'app_version': appVersion,
    'exported_at': _iso(exportedAt),
    'data': {
      'profile': profile.toJson(),
      'meals': [for (final row in meals) row.toJson()],
      'meal_items': [for (final row in mealItems) row.toJson()],
      'nutrition_targets': [for (final row in nutritionTargets) row.toJson()],
      'water_logs': [for (final row in waterLogs) row.toJson()],
      'body_measurements': [for (final row in bodyMeasurements) row.toJson()],
      'foods': [for (final row in foods) row.toJson()],
      'food_preferences': [for (final row in foodPreferences) row.toJson()],
      'fit_recipes': [for (final row in fitRecipes) row.toJson()],
      'recipe_ingredients': [for (final row in recipeIngredients) row.toJson()],
      'meal_templates': [for (final row in mealTemplates) row.toJson()],
      'meal_template_items': [
        for (final row in mealTemplateItems) row.toJson(),
      ],
    },
  };
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

class BackupBodyMeasurement {
  const BackupBodyMeasurement({
    required this.id,
    required this.profileId,
    required this.weightKg,
    required this.measuredAt,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.deletedAt,
  });

  factory BackupBodyMeasurement.fromJson(Map<String, Object?> json) =>
      BackupBodyMeasurement(
        id: _text(json, 'id', max: 64),
        profileId: _text(json, 'profile_id', max: 64),
        weightKg: _decimal(json, 'weight_kg', minimum: 20, maximum: 500),
        measuredAt: _instant(json, 'measured_at'),
        note: _optionalText(json, 'note', max: 240),
        createdAt: _instant(json, 'created_at'),
        updatedAt: _instant(json, 'updated_at'),
        deletedAt: _optionalInstant(json, 'deleted_at'),
      );

  final String id;
  final String profileId;
  final double weightKg;
  final DateTime measuredAt;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'weight_kg': weightKg,
    'measured_at': _iso(measuredAt),
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

bool _flag(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw BackupFormatException('Il campo «$key» del backup non è valido.');
  }
  return value;
}

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
