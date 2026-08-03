import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/notifications/water_reminder_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/wellbeing/data/water_settings_store.dart';
import 'package:kal_tracker/features/wellbeing/data/wellbeing_repository.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';
import 'package:kal_tracker/features/wellbeing/domain/wellbeing_models.dart';

final wellbeingRepositoryProvider = Provider<WellbeingRepository>(
  (ref) => WellbeingRepository(ref.watch(databaseProvider)),
);

final todayWaterProvider = StreamProvider<DailyWaterIntake>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  final day = ref.watch(todayProvider);
  yield* ref
      .watch(wellbeingRepositoryProvider)
      .watchWaterDay(profileId: profile.id, day: day);
});

/// L'acqua del giorno scelto nel diario: come il resto del diario,
/// segue selectedDayProvider (non per forza oggi).
final selectedDayWaterProvider = StreamProvider<DailyWaterIntake>((ref) async* {
  // Tutte le watch sincrone PRIMA del primo await: nel gap asincrono
  // il provider non deve perdere le dipendenze.
  final repository = ref.watch(wellbeingRepositoryProvider);
  final day = ref.watch(selectedDayProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* repository.watchWaterDay(profileId: profile.id, day: day);
});

final recentWeightsProvider = StreamProvider<List<WeightMeasurement>>((
  ref,
) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(wellbeingRepositoryProvider).watchRecentWeights(profile.id);
});

/// Store su file JSON delle impostazioni acqua: nei test si overrida
/// con un fake in memoria.
final waterSettingsStoreProvider = Provider<WaterSettingsStore>(
  (ref) => FileWaterSettingsStore(),
);

final waterSettingsProvider =
    AsyncNotifierProvider<WaterSettingsController, WaterSettings>(
      WaterSettingsController.new,
    );

/// Obiettivo acqua e promemoria: lo stato vive qui, la persistenza nel
/// file JSON e le (ri)pianificazioni nel WaterRemindersService.
class WaterSettingsController extends AsyncNotifier<WaterSettings> {
  @override
  Future<WaterSettings> build() => ref.watch(waterSettingsStoreProvider).read();

  WaterSettings get _current => state.valueOrNull ?? const WaterSettings();

  Future<void> setGoal(int milliliters) async {
    if (milliliters < WaterSettings.minimumGoalMilliliters ||
        milliliters > WaterSettings.maximumGoalMilliliters) {
      throw const FormatException('L’obiettivo acqua non è valido.');
    }
    final updated = _current.copyWith(goalMilliliters: milliliters);
    state = AsyncData(updated);
    await ref.read(waterSettingsStoreProvider).write(updated);
  }

  /// Attiva i promemoria: il permesso notifiche si chiede ADESSO,
  /// non prima. Se viene negato lo stato resta spento e ritorna false.
  Future<bool> enableReminders() async {
    final updated = _current.copyWith(remindersEnabled: true);
    final granted = await ref
        .read(waterRemindersServiceProvider)
        .enable(updated);
    if (!granted) {
      return false;
    }
    state = AsyncData(updated);
    await ref.read(waterSettingsStoreProvider).write(updated);
    return true;
  }

  Future<void> disableReminders() async {
    final updated = _current.copyWith(remindersEnabled: false);
    state = AsyncData(updated);
    await ref.read(waterRemindersServiceProvider).disable();
    await ref.read(waterSettingsStoreProvider).write(updated);
  }

  /// Nuovo intervallo o fascia oraria: salva e, se i promemoria sono
  /// attivi, ripianifica subito (senza richiedere il permesso).
  Future<void> updateReminderPlan({
    int? intervalHours,
    int? startHour,
    int? endHour,
  }) async {
    final updated = _current.copyWith(
      reminderIntervalHours: intervalHours,
      reminderStartHour: startHour,
      reminderEndHour: endHour,
    );
    if (updated.reminderStartHour >= updated.reminderEndHour) {
      throw const FormatException('La fascia oraria non è valida.');
    }
    state = AsyncData(updated);
    if (updated.remindersEnabled) {
      await ref.read(waterRemindersServiceProvider).applySettings(updated);
    }
    await ref.read(waterSettingsStoreProvider).write(updated);
  }
}
