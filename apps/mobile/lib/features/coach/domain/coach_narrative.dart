import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

/// **Il commento del modello: solo parole.**
///
/// Il motore ha già calcolato tutto. Qui arriva il perché, e arriva ripulito:
/// qualunque cifra sparisce insieme al capoverso che la conteneva. È la
/// stessa regola del piano settimanale, con la stessa ragione — un «circa
/// 600 kcal» scritto dal modello accanto ai «772 kcal» calcolati dall'app
/// darebbe a Marco due numeri diversi, e quello sbagliato sarebbe il primo.
///
/// Si scarta il capoverso e non l'intero rapporto: un commento buono non si
/// butta per una frase, ma una frase con dentro un numero inventato non si
/// mostra nemmeno.
@immutable
class CoachNarrative {
  const CoachNarrative({
    required this.week,
    required this.writtenAt,
    required this.paragraphs,
    this.headline,
    this.droppedParagraphs = 0,
  });

  /// Legge il risultato del worker.
  ///
  /// Non lancia mai: un commento illeggibile vale come commento assente, e il
  /// rapporto resta comunque leggibile con i suoi numeri.
  static CoachNarrative? fromResult(
    Object? raw, {
    required CoachWeek week,
    required DateTime writtenAt,
  }) {
    if (raw is! Map) {
      return null;
    }
    final rawParagraphs = raw['paragraphs'];
    if (rawParagraphs is! List) {
      return null;
    }

    final kept = <String>[];
    var dropped = 0;
    for (final item in rawParagraphs) {
      if (kept.length >= maxParagraphs) {
        dropped++;
        continue;
      }
      final text = _clean(item, maxParagraphLength);
      if (text == null) {
        dropped++;
        continue;
      }
      kept.add(text);
    }
    if (kept.isEmpty) {
      return null;
    }

    return CoachNarrative(
      week: week,
      writtenAt: writtenAt,
      paragraphs: List.unmodifiable(kept),
      headline: _clean(raw['headline'], maxHeadlineLength),
      droppedParagraphs: dropped,
    );
  }

  factory CoachNarrative.fromJson(Map<String, Object?> json) => CoachNarrative(
    week: CoachWeek(end: DateTime.parse(json['week_end']! as String).toUtc()),
    writtenAt: DateTime.parse(json['written_at']! as String).toUtc(),
    paragraphs: List.unmodifiable([
      for (final item in (json['paragraphs'] as List?) ?? const [])
        if (item is String) item,
    ]),
    headline: json['headline'] as String?,
    droppedParagraphs: (json['dropped'] as num?)?.toInt() ?? 0,
  );

  /// Al massimo cinque capoversi: oltre non è un commento, è un tema.
  static const int maxParagraphs = 5;
  static const int maxParagraphLength = 400;
  static const int maxHeadlineLength = 120;

  /// La settimana di cui parla. Serve a dire «questo commento è di domenica
  /// scorsa» invece di farlo sembrare fresco.
  final CoachWeek week;

  final DateTime writtenAt;
  final List<String> paragraphs;
  final String? headline;

  /// Quanti capoversi sono stati scartati (cifre, vuoti, troppo lunghi).
  /// Non è un dettaglio da nascondere: se il modello continua a mettere
  /// numeri, si deve vedere.
  final int droppedParagraphs;

  bool get isEmpty => paragraphs.isEmpty;

  Map<String, Object?> toJson() => {
    'week_end': week.end.toIso8601String(),
    'written_at': writtenAt.toIso8601String(),
    'paragraphs': paragraphs,
    'headline': headline,
    'dropped': droppedParagraphs,
  };

  /// Una cifra, in qualunque alfabeto latino-arabo, squalifica il testo.
  static final RegExp _digit = RegExp('[0-9]');

  static String? _clean(Object? value, int maxLength) {
    if (value is! String) {
      return null;
    }
    final text = value.trim();
    if (text.isEmpty || text.length > maxLength) {
      return null;
    }
    return _digit.hasMatch(text) ? null : text;
  }
}

/// Lo stato del job del coach sul Mac, per quel tanto che serve all'app.
enum CoachJobStatus {
  /// Accodato o in lavorazione: si sta aspettando.
  waiting,

  /// Il commento è arrivato.
  done,

  /// Il Mac non ce l'ha fatta (o non ha risposto in tempo).
  failed,
}

/// Un rapporto chiesto e non ancora tornato.
@immutable
class CoachPendingJob {
  const CoachPendingJob({
    required this.jobId,
    required this.week,
    required this.requestedAt,
  });

  factory CoachPendingJob.fromJson(Map<String, Object?> json) =>
      CoachPendingJob(
        jobId: json['job_id']! as String,
        week: CoachWeek(
          end: DateTime.parse(json['week_end']! as String).toUtc(),
        ),
        requestedAt: DateTime.parse(json['requested_at']! as String).toUtc(),
      );

  final String jobId;
  final CoachWeek week;
  final DateTime requestedAt;

  Map<String, Object?> toJson() => {
    'job_id': jobId,
    'week_end': week.end.toIso8601String(),
    'requested_at': requestedAt.toIso8601String(),
  };
}

/// Quel poco che il coach deve ricordare fra un'apertura e l'altra.
///
/// **I numeri non stanno qui.** Si ricalcolano dal database a ogni apertura,
/// quindi sono sempre freschi e ci sono anche senza rete. Si conserva solo
/// ciò che il telefono da solo non può rifare: il commento arrivato dal Mac,
/// la richiesta in volo e l'ultimo motivo di fallimento.
@immutable
class CoachArchive {
  const CoachArchive({this.last, this.pending, this.lastError});

  const CoachArchive.empty() : last = null, pending = null, lastError = null;

  factory CoachArchive.fromJson(Map<String, Object?> json) {
    final rawLast = json['last'];
    final rawPending = json['pending'];
    return CoachArchive(
      last: rawLast is Map<String, Object?> ? _tryNarrative(rawLast) : null,
      pending: rawPending is Map<String, Object?>
          ? _tryPending(rawPending)
          : null,
      lastError: json['last_error'] as String?,
    );
  }

  /// L'ultimo commento arrivato. Resta leggibile per sempre, anche mesi
  /// dopo: è quello che si vede col Mac spento.
  final CoachNarrative? last;

  final CoachPendingJob? pending;

  /// Il motivo dell'ultimo fallimento, già in italiano.
  final String? lastError;

  CoachArchive copyWith({
    CoachNarrative? last,
    CoachPendingJob? pending,
    bool clearPending = false,
    String? lastError,
    bool clearError = false,
  }) => CoachArchive(
    last: last ?? this.last,
    pending: clearPending ? null : (pending ?? this.pending),
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  Map<String, Object?> toJson() => {
    'last': last?.toJson(),
    'pending': pending?.toJson(),
    'last_error': lastError,
  };

  static CoachNarrative? _tryNarrative(Map<String, Object?> json) {
    try {
      return CoachNarrative.fromJson(json);
    } on Object {
      // Un archivio rovinato non deve impedire di aprire la schermata: si
      // perde il commento vecchio, non il rapporto.
      return null;
    }
  }

  static CoachPendingJob? _tryPending(Map<String, Object?> json) {
    try {
      return CoachPendingJob.fromJson(json);
    } on Object {
      return null;
    }
  }
}
