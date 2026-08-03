import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

void main() {
  test('la mezzanotte non riporta a oggi il giorno scelto', () {
    AppTime.initialize();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final today = container.read(todayProvider);
    final yesterday = DiaryDay.shift(today, -1);
    container.read(selectedDayProvider.notifier).state = yesterday;

    container.invalidate(todayProvider);

    expect(
      DiaryDay.isSameDay(container.read(selectedDayProvider), yesterday),
      isTrue,
    );
  });

  test('il giorno scelto parte da oggi', () {
    AppTime.initialize();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      DiaryDay.isSameDay(
        container.read(selectedDayProvider),
        AppTime.nowInRome(),
      ),
      isTrue,
    );
  });
}
