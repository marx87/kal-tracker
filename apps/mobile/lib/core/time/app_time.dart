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

  /// Un istante scritto senza fuso è ora civile di Roma, non UTC.
  ///
  /// Serve alle sorgenti che salvano `DateTime.now().toIso8601String()` di un
  /// telefono italiano: l'export di Gym Tracker lo fa per ogni data. Leggerlo
  /// come UTC sposterebbe indietro di due ore l'intero storico, e la sessione
  /// del 4 agosto alle 22:34 finirebbe nel giorno dopo.
  static DateTime fromRomeLocal(DateTime naive) => tz.TZDateTime(
    _location,
    naive.year,
    naive.month,
    naive.day,
    naive.hour,
    naive.minute,
    naive.second,
    naive.millisecond,
    naive.microsecond,
  ).toUtc();

  /// Legge una stringa ISO 8601 decidendo il fuso dalla stringa stessa: con
  /// `Z` o con un offset è già un istante assoluto, senza è ora di Roma.
  ///
  /// La regola sta qui e non nei chiamanti perché è l'unico punto in cui
  /// sbagliarla costa un giorno intero di differenza.
  static DateTime parseInstant(String value) {
    final parsed = DateTime.parse(value);
    return _zoneSuffix.hasMatch(value) ? parsed.toUtc() : fromRomeLocal(parsed);
  }

  /// Il giorno di calendario romano di un istante, in forma `yyyy-MM-dd`.
  ///
  /// Le colonne remote dichiarate `date` vogliono questo, non l'istante:
  /// Postgres troncherebbe al giorno UTC e la mezzanotte di Roma diventerebbe
  /// il giorno prima, spezzando lo streak al primo pull.
  static String romeDateString(DateTime instant) {
    final local = inRome(instant);
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-$month-$day';
  }

  static final RegExp _zoneSuffix = RegExp(r'(Z|z|[+-]\d{2}:?\d{2})$');
}
