import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

abstract final class AppTime {
  static const zoneName = 'Europe/Rome';
  static tz.Location? _rome;

  static void initialize() {
    if (_rome != null) {
      return;
    }
    tz_data.initializeTimeZones();
    _rome = tz.getLocation(zoneName);
  }

  static tz.Location get _location {
    initialize();
    return _rome!;
  }

  static tz.TZDateTime nowInRome() => tz.TZDateTime.now(_location);

  static DateTime nowUtc() => DateTime.now().toUtc();

  static DateTime startOfDayUtc(DateTime day) =>
      tz.TZDateTime(_location, day.year, day.month, day.day).toUtc();

  static DateTime endOfDayUtc(DateTime day) =>
      tz.TZDateTime(_location, day.year, day.month, day.day + 1).toUtc();

  static tz.TZDateTime inRome(DateTime value) =>
      tz.TZDateTime.from(value.toUtc(), _location);
}
