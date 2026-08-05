/// Letture tolleranti sui valori, severe sulla struttura.
///
/// La distinzione viene dai dati veri: un numero può arrivare come `int` dove
/// ce ne aspettavamo uno con la virgola (Firestore normalizza 106.0 in 106),
/// ma una chiave che manca significa che il file non è quello che crediamo —
/// e su un travaso che si fa una volta sola è meglio fermarsi che indovinare.
library;

Map<String, Object?> asMap(Object? value, String what) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, Object?>();
  }
  throw FormatException('$what: atteso un oggetto JSON, trovato $value.');
}

List<Object?> asList(Object? value, String what) {
  if (value is List) {
    return value;
  }
  throw FormatException('$what: attesa una lista, trovato $value.');
}

/// La chiave deve esserci. Il valore può essere nullo: nell'export `notes`
/// null e `notes` assente sono due cose diverse, e solo la seconda è un file
/// rotto.
Object? require(Map<String, Object?> map, String key, String what) {
  if (!map.containsKey(key)) {
    throw FormatException('$what: manca la chiave "$key".');
  }
  return map[key];
}

String requireString(Map<String, Object?> map, String key, String what) {
  final value = require(map, key, what);
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FormatException(
    '$what: "$key" deve essere una stringa, trovato $value.',
  );
}

String? optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? optionalInt(Object? value) => value is num ? value.round() : null;

double? optionalDouble(Object? value) => value is num ? value.toDouble() : null;

bool? optionalBool(Object? value) => value is bool ? value : null;

/// I `.name` degli enum di Gym già persistiti. Un valore fuori elenco non
/// ferma l'import — Gym stesso ricadeva sul default — ma il fallback è quello
/// del sorgente, non uno nuovo.
String enumOr(Object? value, Set<String> allowed, String fallback) {
  final name = optionalString(value);
  return name != null && allowed.contains(name) ? name : fallback;
}

const Set<String> kTrackingModes = {
  'weightReps',
  'bodyweightReps',
  'timeOnly',
  'timed',
  'distanceTime',
};

const Set<String> kMuscleGroups = {
  'petto',
  'schiena',
  'spalle',
  'bicipiti',
  'tricipiti',
  'gambe',
  'polpacci',
  'addome',
  'cardio',
  'fullbody',
  'mobilita',
  'altro',
};
