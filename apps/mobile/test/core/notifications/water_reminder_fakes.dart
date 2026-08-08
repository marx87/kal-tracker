import 'package:kal_tracker/core/notifications/water_reminders.dart';
import 'package:kal_tracker/features/wellbeing/data/water_settings_store.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';

/// Gateway finto per i test: registra pianificazioni e cancellazioni,
/// nessun platform channel (pattern photo_meal_fakes).
class FakeWaterReminderGateway implements WaterReminderGateway {
  bool permissionGranted = true;
  int initializeCount = 0;
  int permissionRequests = 0;
  int cancelSlotsCount = 0;
  final List<int> cancelledIds = [];
  final List<WaterReminderSlot> scheduled = [];

  @override
  Future<void> initialize() async {
    initializeCount += 1;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    return permissionGranted;
  }

  @override
  Future<void> scheduleDailySlot(WaterReminderSlot slot) async {
    scheduled.add(slot);
  }

  @override
  Future<void> cancelSlots(Iterable<int> ids) async {
    cancelSlotsCount += 1;
    cancelledIds.addAll(ids);
    scheduled.clear();
  }
}

/// Store impostazioni acqua in memoria: niente filesystem nei widget test.
class InMemoryWaterSettingsStore implements WaterSettingsStore {
  InMemoryWaterSettingsStore([this.settings = const WaterSettings()]);

  WaterSettings settings;
  int writes = 0;

  @override
  Future<WaterSettings> read() async => settings;

  @override
  Future<void> write(WaterSettings newSettings) async {
    settings = newSettings;
    writes += 1;
  }
}
