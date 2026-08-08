import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/notifications/app_notification_ids.dart';

void main() {
  test('i namespace delle notifiche non si sovrappongono', () {
    expect(AppNotificationIds.rangesDoNotOverlap, isTrue);
    expect(
      AppNotificationIds.waterReminders.overlaps(
        AppNotificationIds.workoutCues,
      ),
      isFalse,
    );
  });

  test('un id stabile resta nel namespace del proprietario', () {
    final first = AppNotificationIds.workoutCues.stable('rest:w1:2');
    final second = AppNotificationIds.workoutCues.stable('rest:w1:2');

    expect(first, second);
    expect(AppNotificationIds.workoutCues.contains(first), isTrue);
    expect(AppNotificationIds.waterReminders.contains(first), isFalse);
  });

  test('un offset fuori range viene rifiutato', () {
    expect(() => AppNotificationIds.waterReminders.at(24), throwsRangeError);
  });
}
