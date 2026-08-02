import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';

void main() {
  setUpAll(AppTime.initialize);

  test('il giorno del cambio all ora legale dura 23 ore', () {
    final day = DateTime(2026, 3, 29);
    final duration = AppTime.endOfDayUtc(
      day,
    ).difference(AppTime.startOfDayUtc(day));

    expect(duration, const Duration(hours: 23));
  });

  test('il giorno del ritorno all ora solare dura 25 ore', () {
    final day = DateTime(2026, 10, 25);
    final duration = AppTime.endOfDayUtc(
      day,
    ).difference(AppTime.startOfDayUtc(day));

    expect(duration, const Duration(hours: 25));
  });
}
