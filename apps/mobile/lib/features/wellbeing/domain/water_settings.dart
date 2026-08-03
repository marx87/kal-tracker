/// Obiettivo acqua e promemoria: preferenze locali di Marco.
///
/// Vivono su file JSON (pattern backup_storage), niente schema DB:
/// sono impostazioni del dispositivo, non dati da sincronizzare.
class WaterSettings {
  const WaterSettings({
    this.goalMilliliters = defaultGoalMilliliters,
    this.remindersEnabled = false,
    this.reminderIntervalHours = defaultIntervalHours,
    this.reminderStartHour = defaultStartHour,
    this.reminderEndHour = defaultEndHour,
  });

  /// Ricostruisce le impostazioni da JSON sanificando ogni campo:
  /// un file corrotto o valori assurdi tornano ai valori di default.
  factory WaterSettings.fromJson(Map<String, Object?> json) {
    final goal = json['goal_milliliters'];
    final enabled = json['reminders_enabled'];
    final interval = json['reminder_interval_hours'];
    final start = json['reminder_start_hour'];
    final end = json['reminder_end_hour'];

    var startHour = start is int && start >= 0 && start <= 23
        ? start
        : defaultStartHour;
    var endHour = end is int && end >= 0 && end <= 23 ? end : defaultEndHour;
    if (startHour >= endHour) {
      startHour = defaultStartHour;
      endHour = defaultEndHour;
    }

    return WaterSettings(
      goalMilliliters:
          goal is int &&
              goal >= minimumGoalMilliliters &&
              goal <= maximumGoalMilliliters
          ? goal
          : defaultGoalMilliliters,
      remindersEnabled: enabled is bool && enabled,
      reminderIntervalHours:
          interval is int && allowedIntervals.contains(interval)
          ? interval
          : defaultIntervalHours,
      reminderStartHour: startHour,
      reminderEndHour: endHour,
    );
  }

  static const defaultGoalMilliliters = 2000;
  static const defaultIntervalHours = 2;
  static const defaultStartHour = 9;
  static const defaultEndHour = 21;
  static const minimumGoalMilliliters = 500;
  static const maximumGoalMilliliters = 6000;
  static const allowedIntervals = [1, 2, 3];

  final int goalMilliliters;
  final bool remindersEnabled;
  final int reminderIntervalHours;
  final int reminderStartHour;
  final int reminderEndHour;

  Map<String, Object?> toJson() => {
    'goal_milliliters': goalMilliliters,
    'reminders_enabled': remindersEnabled,
    'reminder_interval_hours': reminderIntervalHours,
    'reminder_start_hour': reminderStartHour,
    'reminder_end_hour': reminderEndHour,
  };

  WaterSettings copyWith({
    int? goalMilliliters,
    bool? remindersEnabled,
    int? reminderIntervalHours,
    int? reminderStartHour,
    int? reminderEndHour,
  }) => WaterSettings(
    goalMilliliters: goalMilliliters ?? this.goalMilliliters,
    remindersEnabled: remindersEnabled ?? this.remindersEnabled,
    reminderIntervalHours: reminderIntervalHours ?? this.reminderIntervalHours,
    reminderStartHour: reminderStartHour ?? this.reminderStartHour,
    reminderEndHour: reminderEndHour ?? this.reminderEndHour,
  );

  @override
  bool operator ==(Object other) =>
      other is WaterSettings &&
      other.goalMilliliters == goalMilliliters &&
      other.remindersEnabled == remindersEnabled &&
      other.reminderIntervalHours == reminderIntervalHours &&
      other.reminderStartHour == reminderStartHour &&
      other.reminderEndHour == reminderEndHour;

  @override
  int get hashCode => Object.hash(
    goalMilliliters,
    remindersEnabled,
    reminderIntervalHours,
    reminderStartHour,
    reminderEndHour,
  );
}
