import 'package:flutter/foundation.dart';

/// Un intervallo di id Android/iOS posseduto da una sola funzione dell'app.
///
/// `flutter_local_notifications` espone un namespace globale di interi. Senza
/// una regola centrale, spegnere i promemoria acqua può cancellare il recupero
/// della palestra, o due notifiche possono sovrascriversi silenziosamente.
@immutable
class NotificationIdNamespace {
  const NotificationIdNamespace({
    required this.first,
    required this.length,
    required this.owner,
  }) : assert(first >= 0),
       assert(length > 0);

  final int first;
  final int length;
  final String owner;

  int get last => first + length - 1;

  bool contains(int id) => id >= first && id <= last;

  int at(int offset) {
    if (offset < 0 || offset >= length) {
      throw RangeError.range(offset, 0, length - 1, 'offset');
    }
    return first + offset;
  }

  /// Id ripetibile per una chiave di dominio.
  ///
  /// FNV-1a a 32 bit evita `String.hashCode`, che non promette stabilità fra
  /// processi. La chiave resta anche nel piccolo file dei cue, quindi una rara
  /// collisione è comunque rilevabile e correggibile dal chiamante.
  int stable(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return first + (hash & 0x7fffffff) % length;
  }

  Iterable<int> get all sync* {
    for (var offset = 0; offset < length; offset++) {
      yield first + offset;
    }
  }

  bool overlaps(NotificationIdNamespace other) =>
      first <= other.last && other.first <= last;
}

/// Registro unico degli id usati dalle notifiche locali di Coach360.
abstract final class AppNotificationIds {
  /// Massimo 24 slot orari, pur avendone oggi solo sette.
  static const waterReminders = NotificationIdNamespace(
    first: 4200,
    length: 24,
    owner: 'water_reminders',
  );

  /// Cue a scadenza: il range ampio riduce le collisioni fra sessioni.
  static const workoutCues = NotificationIdNamespace(
    first: 5200,
    length: 2048,
    owner: 'workout_cues',
  );

  static const all = <NotificationIdNamespace>[waterReminders, workoutCues];

  static bool get rangesDoNotOverlap {
    for (var index = 0; index < all.length; index++) {
      for (var other = index + 1; other < all.length; other++) {
        if (all[index].overlaps(all[other])) return false;
      }
    }
    return true;
  }
}
