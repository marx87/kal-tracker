import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';

/// Le due facce dello stesso movimento: quello che l'orologio conta e quello
/// che Marco ricorda.
///
/// Non si sommano e non si convertono l'una nell'altra — una conversione
/// passi/minuti sarebbe un numero inventato — e infatti la settimana si
/// confronta con se stessa, misura per misura.
enum NeatMeasure {
  steps(label: 'Passi', steadyGap: 500),
  walkMinutes(label: 'A piedi', steadyGap: 5);

  const NeatMeasure({required this.label, required this.steadyGap});

  final String label;

  /// Sotto questa differenza fra le due medie non è successo niente, per
  /// quanto grande sia la percentuale. Serve al caso di chi cammina pochissimo:
  /// da 6 a 4 minuti al giorno è un −33 % che non è una notizia, è un
  /// semaforo rosso in più sulla strada di casa.
  final double steadyGap;

  int? valueOf(DailyCheckIn entry) => switch (this) {
    NeatMeasure.steps => entry.steps,
    NeatMeasure.walkMinutes => entry.walkMinutes,
  };

  /// La media, come si legge in una frase.
  ///
  /// I passi si arrotondano al centinaio: dire «8.437 passi al giorno» su una
  /// media di cinque giorni è precisione finta, e questa riga serve ad
  /// accorgersi, non a misurare.
  String format(double value) => switch (this) {
    NeatMeasure.steps => '${_thousands((value / 100).round() * 100)} passi',
    NeatMeasure.walkMinutes => '${value.round()} min',
  };
}

/// Da che parte è andato il movimento. [unknown] non è [steady]: senza
/// confronto non si sa, ed è diverso dal dire che è tutto uguale.
enum NeatDirection { up, steady, down, unknown }

/// **Quanto ci si è mossi questa settimana rispetto a quella prima.**
///
/// Una misura, non un verdetto sul peso: il confronto è fra due settimane e
/// mai fra due giorni, perché il NEAT di un martedì non vuol dire niente.
@immutable
class NeatTrend {
  const NeatTrend({
    required this.measure,
    required this.current,
    required this.previous,
    required this.currentDays,
    required this.previousDays,
  });

  /// Nessun giorno segnato: non c'è niente da dire, nemmeno che manca.
  const NeatTrend.absent(this.measure)
    : current = null,
      previous = null,
      currentDays = 0,
      previousDays = 0;

  final NeatMeasure measure;

  /// Media al giorno della settimana del rapporto. Nulla quando i giorni
  /// segnati sono meno di [CheckInNeat.minimumDays]: [currentDays] resta
  /// comunque valorizzato, perché quanti giorni mancano è la notizia.
  final double? current;

  /// Media al giorno dei sette giorni prima.
  final double? previous;

  /// Giorni con il dato, dichiarati. **La media si fa su questi, non su
  /// sette**: dividere per sette trasformerebbe «non l'ho segnato» in «non mi
  /// sono mosso», cioè esattamente il falso allarme che questo campo esiste
  /// per evitare.
  final int currentDays;
  final int previousDays;

  bool get isKnown => current != null;

  bool get hasComparison => current != null && previous != null;

  /// Variazione in frazione: −0,3 vuol dire un terzo di movimento in meno.
  /// Nulla anche quando la settimana prima era ferma davvero — dividere per
  /// zero non dà una percentuale, dà un infinito.
  double? get change {
    final before = previous;
    final now = current;
    if (before == null || now == null || before <= 0) {
      return null;
    }
    return now / before - 1;
  }

  NeatDirection get direction {
    final before = previous;
    final now = current;
    if (before == null || now == null) {
      return NeatDirection.unknown;
    }
    final gap = now - before;
    if (gap.abs() < measure.steadyGap) {
      return NeatDirection.steady;
    }
    if (before <= 0) {
      return gap > 0 ? NeatDirection.up : NeatDirection.steady;
    }
    final ratio = gap / before;
    if (ratio.abs() < CheckInNeat.noticeableChange) {
      return NeatDirection.steady;
    }
    return ratio > 0 ? NeatDirection.up : NeatDirection.down;
  }

  /// **La riga del rapporto settimanale.** Nulla quando non c'è niente da
  /// dire, cioè solo quando Marco non ha segnato nemmeno un giorno.
  String? get line {
    if (currentDays == 0) {
      return null;
    }
    final now = current;
    if (now == null) {
      // Pochi giorni sono una media finta. Si dice quanti sono e si dice
      // perché lo zero va segnato: è l'unica cosa che rende leggibile la
      // settimana in cui il movimento è davvero crollato.
      return '${measure.label}: ${_daysLabel(currentDays)} su 7 con il dato, '
          'troppo pochi per una media. Segna anche gli zeri — un giorno fermo '
          'e un giorno non segnato non si distinguono.';
    }
    final before = previous;
    if (before == null) {
      return '${measure.label}: ${measure.format(now)} al giorno su '
          '${_daysLabel(currentDays)}. La settimana prima non l\'hai segnato, '
          'quindi non c\'è confronto.';
    }
    return '${measure.label}: ${measure.format(now)} al giorno contro '
        '${measure.format(before)} della settimana prima '
        '(${_daysLabel(currentDays)} contro ${_daysLabel(previousDays)}). '
        '$_verdict';
  }

  String get _verdict => switch (direction) {
    // Il calo è l'unico caso in cui la riga serve a qualcosa di più che
    // sapere: è la spiegazione che il TDEE misurato non può dare da solo, e
    // senza di lei il consiglio diventa «togli calorie» quando la risposta
    // era «rimetti la camminata».
    NeatDirection.down =>
      'Ti stai muovendo di meno: prima di togliere calorie, guarda qui.',
    NeatDirection.up => 'Ti stai muovendo di più.',
    NeatDirection.steady ||
    NeatDirection.unknown => 'Il movimento è lo stesso.',
  };
}

/// **Il NEAT della settimana, per accorgersene.**
///
/// Il grasso viscerale si muove più con i passi quotidiani che con l'ora di
/// palestra, e il plateau classico arriva quando il movimento crolla senza che
/// nessuno se ne accorga. Il consumo misurato registra il calo ma non sa
/// spiegarlo: questo confronto è la spiegazione.
///
/// Prende un giorno di riferimento e non una `CoachWeek` di proposito: così il
/// check-in non dipende dal coach: è il coach che, quando lo aggancerà, gli
/// passa la domenica del suo rapporto.
abstract final class CheckInNeat {
  /// Giorni segnati che servono perché la media conti. Sotto i tre «la media
  /// della settimana» è una camminata sola travestita da abitudine.
  static const int minimumDays = 3;

  /// Quanto deve cambiare la media perché valga la pena dirlo. Il 15 % è
  /// tarato sull'unica cosa che serve — accorgersi — e non sulla precisione:
  /// più in basso la riga griderebbe ogni settimana, e a quel punto Marco
  /// smetterebbe di leggerla.
  static const double noticeableChange = 0.15;

  /// I sette giorni che finiscono in [weekEnd] contro i sette prima.
  static NeatTrend measure({
    required CheckInLog log,
    required DateTime weekEnd,
    required NeatMeasure measure,
  }) {
    final end = checkInDayOf(weekEnd);
    final start = end.subtract(const Duration(days: 6));
    final previousEnd = start.subtract(const Duration(days: 1));
    final previousStart = previousEnd.subtract(const Duration(days: 6));

    final current = <double>[];
    final before = <double>[];
    for (final entry in log.entries.values) {
      final value = measure.valueOf(entry);
      if (value == null) {
        continue;
      }
      final day = entry.day;
      if (!day.isBefore(start) && !day.isAfter(end)) {
        current.add(value.toDouble());
      } else if (!day.isBefore(previousStart) && !day.isAfter(previousEnd)) {
        before.add(value.toDouble());
      }
    }

    if (current.isEmpty) {
      return NeatTrend.absent(measure);
    }
    return NeatTrend(
      measure: measure,
      current: _mean(current),
      // Il termine di paragone sparisce da solo quando è troppo magro: una
      // media su un giorno non è la settimana scorsa, è quel giorno lì.
      previous: _mean(before),
      currentDays: current.length,
      previousDays: before.length,
    );
  }

  /// **La riga da mettere nel rapporto settimanale.** Nulla quando il
  /// movimento non è mai stato segnato: un rapporto non deve rimproverare un
  /// campo che Marco ha scelto di non usare.
  ///
  /// Una misura sola, non due: passi e minuti raccontano la stessa camminata,
  /// e stamparle entrambe darebbe due righe che dicono la stessa cosa con due
  /// numeri diversi. Vince quella con più giorni segnati, e a pari giorni i
  /// passi — sono la misura di cui parla la letteratura, e sono quelli che
  /// l'orologio dà già fatti.
  static String? weeklyLine({
    required CheckInLog log,
    required DateTime weekEnd,
  }) => strongest(log: log, weekEnd: weekEnd)?.line;

  /// La misura meglio compilata della settimana, per chi vuole i numeri e non
  /// la frase.
  static NeatTrend? strongest({
    required CheckInLog log,
    required DateTime weekEnd,
  }) {
    final steps = measure(
      log: log,
      weekEnd: weekEnd,
      measure: NeatMeasure.steps,
    );
    final walk = measure(
      log: log,
      weekEnd: weekEnd,
      measure: NeatMeasure.walkMinutes,
    );
    if (steps.currentDays == 0 && walk.currentDays == 0) {
      return null;
    }
    return walk.currentDays > steps.currentDays ? walk : steps;
  }

  /// Nulla sotto [minimumDays]: pochi giorni non fanno una media, e una media
  /// finta qui è peggio di nessuna media — porta a togliere calorie per un
  /// crollo che non è mai avvenuto.
  static double? _mean(List<double> values) {
    if (values.length < minimumDays) {
      return null;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }
}

String _daysLabel(int days) => days == 1 ? '1 giorno' : '$days giorni';

/// «8.400»: il punto delle migliaia come si scrive in italiano.
///
/// A mano e non con `intl`, per la stessa ragione di `coach_dates`: queste
/// frasi sono dominio e devono restare testabili senza inizializzare un
/// locale né montare un widget.
String _thousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '−' : '');
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) {
      buffer.write('.');
    }
    buffer.write(digits[index]);
  }
  return buffer.toString();
}
