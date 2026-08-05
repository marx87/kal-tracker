/// Date e numeri in italiano, senza `intl`.
///
/// **Perché a mano.** Queste frasi sono dominio, non presentazione: «arrivi a
/// 87,4 kg il 2 dicembre» è una funzione pura dei numeri calcolati, e va
/// testata senza montare un widget né inizializzare i dati di locale. Le
/// dodici stringhe dei mesi costano meno di quella dipendenza.
library;

const List<String> _months = [
  'gennaio',
  'febbraio',
  'marzo',
  'aprile',
  'maggio',
  'giugno',
  'luglio',
  'agosto',
  'settembre',
  'ottobre',
  'novembre',
  'dicembre',
];

const List<String> _weekdays = [
  'lunedì',
  'martedì',
  'mercoledì',
  'giovedì',
  'venerdì',
  'sabato',
  'domenica',
];

/// «2 dicembre».
String coachDayLabel(DateTime day) => '${day.day} ${_months[day.month - 1]}';

/// «domenica 2 agosto».
String coachWeekdayLabel(DateTime day) =>
    '${_weekdays[day.weekday - 1]} ${coachDayLabel(day)}';

/// «2 dicembre 2026»: solo dove l'anno può davvero cambiare le cose.
String coachFullDayLabel(DateTime day) => '${coachDayLabel(day)} ${day.year}';

/// «2 settimane», «1 settimana».
String coachWeeksLabel(int weeks) {
  final value = weeks.abs();
  return value == 1 ? '1 settimana' : '$value settimane';
}

/// «3 giorni», «1 giorno».
String coachDaysLabel(int days) {
  final value = days.abs();
  return value == 1 ? '1 giorno' : '$value giorni';
}

/// Numero con la virgola decimale, come si scrive in italiano.
String coachNumber(double value, {int decimals = 1}) =>
    value.toStringAsFixed(decimals).replaceAll('.', ',');

/// Numero con il segno sempre davanti: serve alle variazioni, dove «0,3» e
/// «−0,3» sono due notizie opposte.
///
/// Il segno meno è il vero segno meno tipografico (U+2212), non il trattino:
/// a corpo piccolo il trattino sparisce e «-0,7» si legge «0,7».
String coachSignedNumber(double value, {int decimals = 1}) {
  final rounded = double.parse(value.toStringAsFixed(decimals));
  final body = coachNumber(rounded.abs(), decimals: decimals);
  if (rounded == 0) {
    return body;
  }
  return rounded < 0 ? '−$body' : '+$body';
}
