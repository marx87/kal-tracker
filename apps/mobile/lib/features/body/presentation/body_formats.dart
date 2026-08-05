import 'package:intl/intl.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';

/// Come si scrivono i numeri e le date della schermata Corpo.
///
/// Sta in un posto solo perché il segno meno, la virgola decimale e il numero
/// di cifre devono essere identici nel riepilogo, nel grafico e nell'elenco:
/// tre formattazioni diverse dello stesso peso sembrano tre pesi diversi.
///
/// I chilogrammi si scrivono con UN decimale e le percentuali con uno: la
/// bilancia ne dichiara di più, ma quelle cifre sono rumore (vedi
/// `BiaSpread`) e stamparle le farebbe sembrare precisione.
abstract final class BodyFormats {
  static final _kg = NumberFormat('#,##0.0', 'it');
  static final _cm = NumberFormat('#,##0.0', 'it');
  static final _shortDay = DateFormat('d MMM', 'it');
  static final _longDay = DateFormat('d MMMM', 'it');
  static final _fullDay = DateFormat('d MMMM y', 'it');
  static final _dayAndTime = DateFormat('d MMM, HH:mm', 'it');

  static String kg(double value) => _kg.format(value);

  static String cm(double value) => _cm.format(value);

  static String percent(double value) => _kg.format(value);

  /// Vero quando, con un decimale, il valore si scrive «0,0»: sotto quella
  /// soglia non c'è variazione da mostrare, e stampare «-0,0» sarebbe peggio
  /// che non stampare niente.
  static bool isFlat(double value) => (value.abs() * 10).round() == 0;

  /// Variazione col segno: il «+» va scritto, altrimenti un aumento e un calo
  /// si distinguono solo dal contesto.
  static String signedKg(double value) =>
      isFlat(value) ? '0,0' : '${value < 0 ? '-' : '+'}${kg(value.abs())}';

  static String signedCm(double value) =>
      isFlat(value) ? '0,0' : '${value < 0 ? '-' : '+'}${cm(value.abs())}';

  /// Per il lettore di schermo: «meno» e «più» a parole, perché il segno
  /// grafico viene letto in modi diversi da ogni sintesi vocale.
  static String spokenChange(double value, {String unit = 'chilogrammi'}) {
    if (isFlat(value)) {
      return 'invariato';
    }
    final direction = value < 0 ? 'in calo di' : 'in aumento di';
    return '$direction ${kg(value.abs())} $unit';
  }

  static String spokenKg(double value) => '${kg(value)} chilogrammi';

  static String spokenNumber(double value) => kg(value);

  /// «5 ago», per gli assi dei grafici.
  static String shortDay(DateTime day) => _shortDay.format(day);

  /// «5 agosto», per le descrizioni parlate.
  static String longDay(DateTime day) => _longDay.format(day);

  /// Data e ora romane di una pesata.
  static String stamp(DateTime instant) =>
      _dayAndTime.format(AppTime.inRome(instant));

  static String fullDay(DateTime instant) =>
      _fullDay.format(AppTime.inRome(instant));

  /// Formatta i campi così come sono, senza conversioni di fuso: serve a chi
  /// tiene in mano un orario da calendario (il giorno scelto in un foglio),
  /// non un istante. Passarlo da `inRome` lo sposterebbe di due ore.
  static String wallDay(DateTime wallClock) => _fullDay.format(wallClock);

  /// «oggi», «ieri», «3 giorni fa»: la distanza conta più della data quando
  /// si guarda se il dato è ancora fresco.
  static String daysAgo(int days) => switch (days) {
    <= 0 => 'oggi',
    1 => 'ieri',
    _ => '$days giorni fa',
  };

  /// Nome leggibile della sorgente. 'manual' non si mostra come «manual».
  static String source(String value) => switch (value) {
    'manual' => 'inserita a mano',
    'renpho_ble' => 'bilancia Renpho',
    'renpho_csv' => 'export Renpho',
    'gym_tracker' => 'da Gym Tracker',
    'health_connect' => 'Health Connect',
    _ => value,
  };

  /// Etichetta della finestra temporale, per i chip di scelta.
  static String range(BodyRange range) => range.label;
}
