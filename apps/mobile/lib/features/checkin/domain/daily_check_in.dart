import 'package:flutter/foundation.dart';
import 'package:kal_tracker/core/time/app_time.dart';

/// Il giorno civile romano di un istante, come etichetta.
///
/// Torna un `DateTime.utc` a mezzanotte: non è un istante ma il nome del
/// giorno. Stessa regola di `bodyDayOf` e di `DiaryDay`, perché il check-in
/// del mattino deve cadere nello stesso giorno della pesata e del diario —
/// altrimenti alle 00:30 di Roma finirebbe nel giorno prima.
DateTime checkInDayOf(DateTime instant) {
  final local = AppTime.inRome(instant);
  return DateTime.utc(local.year, local.month, local.day);
}

/// L'energia percepita, da 1 a 5.
///
/// È una scala soggettiva e resta tale: nessuna formula la usa per produrre
/// numeri. Serve al coach per leggere una settimana — carichi in salita più
/// energia in discesa è il primo segnale di sovrallenamento (M8.3).
enum EnergyLevel {
  drained(1, 'Scarico'),
  low(2, 'Fiacco'),
  steady(3, 'Nella media'),
  good(4, 'In forma'),
  charged(5, 'Carico');

  const EnergyLevel(this.score, this.label);

  /// 1-5. È il valore che finisce nello storico: le etichette possono
  /// cambiare parola, il punteggio no.
  final int score;

  final String label;

  static EnergyLevel? fromScore(int? score) {
    if (score == null) {
      return null;
    }
    for (final level in EnergyLevel.values) {
      if (level.score == score) {
        return level;
      }
    }
    return null;
  }
}

/// Il check-in di un giorno: due campi soli, più niente.
///
/// Il peso NON sta qui: vive dov'è sempre vissuto, in `body_measurements`.
/// Duplicarlo darebbe due verità sullo stesso numero, e le medie a 7 giorni
/// della composizione corporea leggono quella tabella.
///
/// Entrambi i campi sono facoltativi: un check-in con il solo sonno è un
/// check-in valido. Il coach deve funzionare con dati mancanti — nello
/// storico reale l'umore è compilato in 11 sessioni su 29.
@immutable
class DailyCheckIn {
  const DailyCheckIn({
    required this.day,
    required this.updatedAt,
    this.sleepHours,
    this.energyScore,
  });

  /// Ore di sonno minime e massime accettate. Sotto zero non esiste; sopra
  /// le 16 non è più una notte ed è quasi sempre un errore di digitazione.
  static const double minSleepHours = 0;
  static const double maxSleepHours = 16;

  /// Il passo del selettore: mezz'ora. Al minuto sarebbe finta precisione
  /// su un dato che si legge a occhio dall'orologio.
  static const double sleepStepHours = 0.5;

  /// Quanto propone il selettore la prima volta, quando non c'è niente da
  /// cui partire.
  static const double defaultSleepHours = 7.5;

  /// Etichetta del giorno: `DateTime.utc` a mezzanotte (vedi [checkInDayOf]).
  final DateTime day;

  final DateTime updatedAt;

  /// Ore dormite, a mezz'ore. Nullo finché non viene inserito.
  final double? sleepHours;

  /// Energia percepita 1-5. Nullo finché non viene inserita.
  final int? energyScore;

  EnergyLevel? get energy => EnergyLevel.fromScore(energyScore);

  bool get isEmpty => sleepHours == null && energyScore == null;

  /// Vero quando tutti e due i campi ci sono: è la condizione con cui la
  /// schermata Oggi smette di invitare e si limita a riassumere.
  bool get isComplete => sleepHours != null && energyScore != null;

  DailyCheckIn copyWith({
    double? sleepHours,
    int? energyScore,
    DateTime? updatedAt,
  }) => DailyCheckIn(
    day: day,
    updatedAt: updatedAt ?? this.updatedAt,
    sleepHours: sleepHours ?? this.sleepHours,
    energyScore: energyScore ?? this.energyScore,
  );

  /// Chiave del giorno, `yyyy-MM-dd`: è anche la chiave nel file JSON e
  /// sarà la colonna `day` quando arriverà la tabella.
  String get dayKey => dayKeyOf(day);

  static String dayKeyOf(DateTime day) {
    final month = day.month.toString().padLeft(2, '0');
    final value = day.day.toString().padLeft(2, '0');
    return '${day.year.toString().padLeft(4, '0')}-$month-$value';
  }

  /// Riporta i valori dentro i limiti invece di rifiutarli.
  ///
  /// Un check-in da dieci secondi non deve mai finire in un messaggio di
  /// errore: se il numero è fuori scala si arrotonda al passo e si taglia
  /// ai limiti, e chi guarda vede subito cosa è stato salvato.
  static double? normalizeSleep(double? hours) {
    if (hours == null || !hours.isFinite) {
      return null;
    }
    final stepped = (hours / sleepStepHours).round() * sleepStepHours;
    return stepped.clamp(minSleepHours, maxSleepHours).toDouble();
  }

  static int? normalizeEnergy(int? score) {
    if (score == null) {
      return null;
    }
    return score.clamp(1, 5);
  }

  Map<String, Object?> toJson() => {
    'day': dayKey,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (sleepHours != null) 'sleep_hours': sleepHours,
    if (energyScore != null) 'energy_score': energyScore,
  };

  /// Lettura indulgente: una riga rotta vale `null` e viene saltata, non fa
  /// fallire tutto il file.
  static DailyCheckIn? fromJson(Map<String, Object?> json) {
    final rawDay = json['day'];
    if (rawDay is! String) {
      return null;
    }
    final day = DateTime.tryParse(rawDay);
    if (day == null) {
      return null;
    }
    final updatedAt = switch (json['updated_at']) {
      final String value => DateTime.tryParse(value)?.toUtc(),
      _ => null,
    };
    return DailyCheckIn(
      day: DateTime.utc(day.year, day.month, day.day),
      updatedAt: updatedAt ?? DateTime.utc(day.year, day.month, day.day),
      sleepHours: normalizeSleep(switch (json['sleep_hours']) {
        final num value => value.toDouble(),
        _ => null,
      }),
      energyScore: normalizeEnergy(switch (json['energy_score']) {
        final num value => value.toInt(),
        _ => null,
      }),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DailyCheckIn &&
          other.day == day &&
          other.updatedAt == updatedAt &&
          other.sleepHours == sleepHours &&
          other.energyScore == energyScore;

  @override
  int get hashCode => Object.hash(day, updatedAt, sleepHours, energyScore);
}

/// Lo storico dei check-in, per giorno.
///
/// Tiene una finestra e non tutto: [historyDays] giorni bastano al brief
/// settimanale e alle tendenze del mese, e un file che cresce per sempre su
/// un telefono è un problema che si scopre tardi.
@immutable
class CheckInLog {
  const CheckInLog(this.entries);

  const CheckInLog.empty() : entries = const {};

  /// Sei mesi: la stessa finestra con cui `BodyStateRepository` guarda
  /// indietro per la composizione corporea.
  static const int historyDays = 180;

  static const int formatVersion = 1;

  /// Per chiave di giorno `yyyy-MM-dd`.
  final Map<String, DailyCheckIn> entries;

  DailyCheckIn? forDay(DateTime day) => entries[DailyCheckIn.dayKeyOf(day)];

  /// I check-in dal più recente: è l'ordine in cui li leggerà il coach.
  List<DailyCheckIn> get recentFirst {
    final values = entries.values.toList()
      ..sort((a, b) => b.day.compareTo(a.day));
    return List.unmodifiable(values);
  }

  /// Scrive il check-in del giorno e pota quello che è uscito dalla finestra.
  ///
  /// [now] arriva da fuori così il taglio è prevedibile nei test: la finestra
  /// si misura da oggi, non dalla data del check-in scritto.
  CheckInLog upsert(DailyCheckIn entry, {required DateTime now}) {
    final horizon = checkInDayOf(
      now,
    ).subtract(const Duration(days: historyDays));
    final next = <String, DailyCheckIn>{
      for (final item in entries.entries)
        if (!item.value.day.isBefore(horizon)) item.key: item.value,
    };
    if (entry.isEmpty) {
      // Un check-in svuotato si cancella: tenere una riga di soli null
      // farebbe contare un giorno come «compilato» a chi conta le righe.
      next.remove(entry.dayKey);
    } else {
      next[entry.dayKey] = entry;
    }
    return CheckInLog(Map.unmodifiable(next));
  }

  Map<String, Object?> toJson() => {
    'version': formatVersion,
    'entries': [for (final entry in recentFirst) entry.toJson()],
  };

  static CheckInLog fromJson(Map<String, Object?> json) {
    final raw = json['entries'];
    if (raw is! List) {
      return const CheckInLog.empty();
    }
    final entries = <String, DailyCheckIn>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final entry = DailyCheckIn.fromJson(
        item.map((key, value) => MapEntry('$key', value)),
      );
      if (entry != null && !entry.isEmpty) {
        entries[entry.dayKey] = entry;
      }
    }
    return CheckInLog(Map.unmodifiable(entries));
  }
}
