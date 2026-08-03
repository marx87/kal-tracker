import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';

enum MealType {
  breakfast('breakfast'),
  lunch('lunch'),
  dinner('dinner'),
  snack('snack');

  const MealType(this.storageValue);

  final String storageValue;

  static MealType fromStorage(String value) => MealType.values.firstWhere(
    (type) => type.storageValue == value,
    orElse: () => MealType.snack,
  );
}

class ManualFoodInput {
  const ManualFoodInput({
    required this.foodName,
    required this.grams,
    required this.per100g,
    required this.mealType,
    required this.eatenAt,
  });

  final String foodName;
  final double grams;
  final Nutrients per100g;
  final MealType mealType;
  final DateTime eatenAt;

  void validate() {
    if (foodName.trim().isEmpty) {
      throw const FormatException('Inserisci il nome dell’alimento.');
    }
    NutritionCalculator.scale(per100g: per100g, grams: grams);
  }
}

class DiaryEntry {
  const DiaryEntry({
    required this.id,
    required this.mealId,
    required this.foodName,
    required this.grams,
    required this.mealType,
    required this.eatenAt,
    required this.per100g,
    required this.nutrients,
  });

  final String id;
  final String mealId;
  final String foodName;
  final double grams;
  final MealType mealType;
  final DateTime eatenAt;
  final Nutrients per100g;
  final Nutrients nutrients;
}

abstract final class DiaryDay {
  static DateTime instantFor(DateTime day) =>
      AppTime.startOfDayUtc(day).add(const Duration(hours: 12));

  static bool isSameDay(DateTime first, DateTime second) =>
      AppTime.startOfDayUtc(first) == AppTime.startOfDayUtc(second);

  static DateTime shift(DateTime day, int days) => AppTime.inRome(
    AppTime.startOfDayUtc(day).add(Duration(days: days, hours: 12)),
  );
}

class DailyDiary {
  const DailyDiary({required this.entries, required this.totals});

  factory DailyDiary.fromEntries(List<DiaryEntry> entries) {
    final totals = entries.fold<Nutrients>(
      const Nutrients.zero(),
      (sum, entry) => sum + entry.nutrients,
    );
    return DailyDiary(entries: List.unmodifiable(entries), totals: totals);
  }

  const DailyDiary.empty()
    : entries = const [],
      totals = const Nutrients.zero();

  final List<DiaryEntry> entries;
  final Nutrients totals;

  List<DiaryEntry> entriesFor(MealType type) =>
      entries.where((entry) => entry.mealType == type).toList(growable: false);
}
