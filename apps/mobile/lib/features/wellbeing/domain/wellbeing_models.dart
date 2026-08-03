class WaterIntakeEntry {
  const WaterIntakeEntry({
    required this.id,
    required this.milliliters,
    required this.loggedAt,
  });

  final String id;
  final int milliliters;
  final DateTime loggedAt;
}

class DailyWaterIntake {
  const DailyWaterIntake({
    required this.entries,
    required this.totalMilliliters,
  });

  factory DailyWaterIntake.fromEntries(List<WaterIntakeEntry> entries) =>
      DailyWaterIntake(
        entries: List.unmodifiable(entries),
        totalMilliliters: entries.fold(
          0,
          (total, entry) => total + entry.milliliters,
        ),
      );

  const DailyWaterIntake.empty() : entries = const [], totalMilliliters = 0;

  final List<WaterIntakeEntry> entries;
  final int totalMilliliters;
}

class WeightMeasurement {
  const WeightMeasurement({
    required this.id,
    required this.weightKg,
    required this.measuredAt,
    this.note,
  });

  final String id;
  final double weightKg;
  final DateTime measuredAt;
  final String? note;
}
