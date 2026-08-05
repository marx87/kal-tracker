import 'package:kal_tracker/features/body/domain/body_models.dart';

/// La settimana del rapporto: sette giorni civili romani che finiscono di
/// domenica.
///
/// Gli estremi sono **etichette di giorno** (`DateTime.utc` a mezzanotte,
/// come le produce [bodyDayOf]) e non istanti: l'aritmetica sui giorni resta
/// esatta a cavallo del cambio d'ora, che su un confronto fra due settimane
/// altrimenti sposterebbe un giorno intero da una parte all'altra.
class CoachWeek {
  const CoachWeek({required this.end});

  /// La settimana che finisce nel giorno di [instant].
  factory CoachWeek.endingOn(DateTime instant) =>
      CoachWeek(end: bodyDayOf(instant));

  /// La settimana chiusa più recente: finisce nell'ultima domenica **non
  /// successiva** a [instant]. Di domenica il rapporto parla di oggi stesso.
  ///
  /// È la regola del «rapporto della domenica»: lunedì mattina si legge
  /// ancora la settimana appena finita, non tre quarti di quella nuova.
  factory CoachWeek.lastSunday(DateTime instant) {
    final today = bodyDayOf(instant);
    // In Dart la domenica è 7: sottraendo `weekday % 7` si torna indietro
    // fino alla domenica, e di domenica non ci si muove.
    return CoachWeek(end: today.subtract(Duration(days: today.weekday % 7)));
  }

  /// La domenica, ultimo giorno incluso.
  final DateTime end;

  DateTime get start => end.subtract(const Duration(days: 6));

  /// I sette giorni prima: è il termine di paragone di tutto il rapporto.
  CoachWeek get previous =>
      CoachWeek(end: end.subtract(const Duration(days: 7)));

  /// Vero se il giorno civile di [instant] cade dentro la settimana.
  bool contains(DateTime instant) {
    final day = bodyDayOf(instant);
    return !day.isBefore(start) && !day.isAfter(end);
  }

  /// Contiene già il giorno, senza riconvertirlo (per le serie che lavorano
  /// su etichette di giorno, come il diario).
  bool containsDay(DateTime day) => !day.isBefore(start) && !day.isAfter(end);

  /// Quante settimane indietro rispetto a [other]. Zero è la stessa.
  int weeksBefore(CoachWeek other) => other.end.difference(end).inDays ~/ 7;

  @override
  bool operator ==(Object other) => other is CoachWeek && other.end == end;

  @override
  int get hashCode => end.hashCode;

  @override
  String toString() =>
      'CoachWeek(${start.toIso8601String()} → '
      '${end.toIso8601String()})';
}
