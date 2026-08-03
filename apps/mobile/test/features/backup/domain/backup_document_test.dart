import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';

void main() {
  group('BackupDocument', () {
    test('conserva i dati in un giro completo di encode e decode', () {
      final document = _document();

      final restored = BackupDocument.decode(document.encode());

      expect(restored.formatVersion, BackupDocument.currentFormatVersion);
      expect(restored.appVersion, '0.2.0+2');
      expect(restored.exportedAt, DateTime.utc(2026, 8, 3, 9, 30));
      expect(restored.profile.displayName, 'Marco');
      expect(restored.mealItems, hasLength(1));
      expect(restored.mealItems.single.foodName, 'Riso basmati cotto');
      expect(restored.mealItems.single.grams, 150);
      expect(restored.mealItems.single.totalCalories, 195);
      expect(restored.meals.single.mealType, 'lunch');
      expect(restored.rowCount, 3);
      expect(restored.checksum, document.checksum);
    });

    test('rifiuta un file con il checksum manomesso', () {
      final document = _document();
      final tampered = jsonDecode(document.encode()) as Map<String, Object?>;
      final data = tampered['data']! as Map<String, Object?>;
      final items = data['meal_items']! as List<Object?>;
      (items.single! as Map<String, Object?>)['grams'] = 300.0;

      expect(
        () => BackupDocument.decode(jsonEncode(tampered)),
        throwsA(
          isA<BackupFormatException>().having(
            (error) => error.message,
            'message',
            contains('danneggiato'),
          ),
        ),
      );
    });

    test('rifiuta un formato di backup più recente', () {
      final document = _document();
      final future = jsonDecode(document.encode()) as Map<String, Object?>;
      future['format_version'] = BackupDocument.currentFormatVersion + 1;

      expect(
        () => BackupDocument.decode(jsonEncode(future)),
        throwsA(
          isA<BackupFormatException>().having(
            (error) => error.message,
            'message',
            contains('aggiorna Kal Tracker'),
          ),
        ),
      );
    });

    test('rifiuta grammi non positivi e nutrienti negativi', () {
      expect(
        () => BackupMealItem.fromJson(_mealItemJson(grams: 0)),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupMealItem.fromJson(_mealItemJson(calories: -1)),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupMealItem.fromJson(_mealItemJson(name: '  ')),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rifiuta un file che non è JSON', () {
      expect(
        () => BackupDocument.decode('questo non è un backup'),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });
}

Map<String, Object?> _mealItemJson({
  double grams = 150,
  double calories = 130,
  String name = 'Riso basmati cotto',
}) => {
  'id': 'item-1',
  'meal_id': 'meal-1',
  'food_name': name,
  'grams': grams,
  'calories_per_100g': calories,
  'protein_per_100g': 2.7,
  'carbs_per_100g': 28.2,
  'fat_per_100g': 0.3,
  'total_calories': 195.0,
  'total_protein': 4.05,
  'total_carbs': 42.3,
  'total_fat': 0.45,
  'source': 'manual',
  'created_at': '2026-08-03T09:00:00.000Z',
  'updated_at': '2026-08-03T09:00:00.000Z',
  'deleted_at': null,
};

BackupDocument _document() {
  final moment = DateTime.utc(2026, 8, 3, 9);
  return BackupDocument(
    formatVersion: BackupDocument.currentFormatVersion,
    appVersion: '0.2.0+2',
    exportedAt: DateTime.utc(2026, 8, 3, 9, 30),
    profile: BackupProfile(
      id: 'profile-1',
      displayName: 'Marco',
      createdAt: moment,
      updatedAt: moment,
    ),
    meals: [
      BackupMeal(
        id: 'meal-1',
        profileId: 'profile-1',
        mealType: 'lunch',
        eatenAt: moment,
        createdAt: moment,
        updatedAt: moment,
      ),
    ],
    mealItems: [BackupMealItem.fromJson(_mealItemJson())],
    nutritionTargets: const [],
    waterLogs: const [],
    bodyMeasurements: const [],
    foods: const [],
    foodPreferences: const [],
    fitRecipes: const [],
    recipeIngredients: const [],
    mealTemplates: const [],
    mealTemplateItems: const [],
  );
}
