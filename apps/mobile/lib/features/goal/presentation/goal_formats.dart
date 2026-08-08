import 'package:intl/intl.dart';
import 'package:kal_tracker/core/time/app_time.dart';

/// I formati dell'area Obiettivo, in un posto solo.
///
/// La formattazione è un fatto di dominio, non di widget: le [StatRow] del
/// design system ricevono stringhe già pronte, e se ogni card se le
/// costruisse da sé i decimali smetterebbero di somigliarsi.
abstract final class GoalFormats {
  /// Chili con un decimale e la virgola italiana: «80,5».
  static String kg(double value) =>
      value.toStringAsFixed(1).replaceAll('.', ',');

  /// Chili con due decimali: serve al ritmo settimanale, dove il decimo di
  /// chilo è tutta la differenza tra prudente e aggressivo.
  static String kgPrecise(double value) =>
      value.toStringAsFixed(2).replaceAll('.', ',');

  /// Il moltiplicatore di attività: «1,48».
  ///
  /// Non è [kgPrecise] con un altro nome: quello dice chili, e il giorno in
  /// cui i chili volessero un decimale solo il moltiplicatore non c'entrerebbe
  /// niente. Gli stessi due decimali della spiegazione del dominio, così il
  /// numero della card e quello della frase sotto sono lo stesso numero.
  static String multiplier(double value) =>
      value.toStringAsFixed(2).replaceAll('.', ',');

  /// Calorie e grammi arrotondati: «1.865».
  static String round(double value) =>
      NumberFormat.decimalPattern('it').format(value.round());

  /// Una data per esteso: «2 dicembre 2026».
  static String date(DateTime value) =>
      DateFormat('d MMMM y', 'it').format(AppTime.inRome(value));

  /// Una durata in giorni detta come la direbbe una persona.
  static String horizon(int days) {
    if (days <= 0) {
      return 'ci sei';
    }
    if (days == 1) {
      return 'domani';
    }
    if (days < 14) {
      return '$days giorni';
    }
    if (days < 70) {
      final weeks = (days / 7).round();
      return '$weeks settimane';
    }
    final months = (days / 30).round();
    return '$months mesi';
  }
}
