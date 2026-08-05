import 'package:flutter/foundation.dart';

/// Sesso biologico, nel senso in cui lo intendono le formule.
///
/// Non è un dato anagrafico e non è un'identità: è un coefficiente. Le
/// equazioni della bioimpedenza e quelle del metabolismo hanno due
/// parametrizzazioni, e chiedere quale usare è più onesto che sceglierne una
/// di nascosto. Per questo l'app lo dichiara a schermo e lo lascia vuoto se
/// Marco non risponde.
enum BiologicalSex {
  male(code: 'M', label: 'Uomo'),
  female(code: 'F', label: 'Donna');

  const BiologicalSex({required this.code, required this.label});

  /// La lettera salvata in `app_profiles.sex`, e accettata dal CHECK remoto
  /// della migrazione `0006` (`sex in ('M', 'F')`).
  final String code;

  final String label;

  static BiologicalSex? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) {
        return value;
      }
    }
    return null;
  }
}

/// Altezza, nascita e sesso: i tre dati che l'app non può dedurre da niente.
///
/// Sono tutti e tre facoltativi, e non per pigrizia: senza di loro il diario,
/// gli allenamenti e il peso funzionano identici, e solo BMI, metabolismo
/// basale e le percentuali della bilancia restano a metà. Un'app che si
/// rifiuta di partire finché non le hai risposto è un'app che ti tiene in
/// ostaggio per un grafico.
@immutable
class PersonalDetails {
  const PersonalDetails({this.heightCm, this.birthDate, this.sex});

  static const empty = PersonalDetails();

  /// In centimetri, arrotondata al decimo: la colonna remota è
  /// `numeric(5,1)` e un valore più preciso di così tornerebbe indietro
  /// diverso da come è partito.
  final double? heightCm;

  /// Mezzanotte in UTC, come `AppProfiles.birthDate` e `WeeklyPlans.startDate`.
  /// È un'etichetta di giorno civile, non un istante: chi la costruisce usa
  /// [dayFrom], chi la confronta non deve mai passare per il fuso locale.
  final DateTime? birthDate;

  final BiologicalSex? sex;

  bool get isComplete => heightCm != null && birthDate != null && sex != null;

  bool get isEmpty => heightCm == null && birthDate == null && sex == null;

  /// Quanti dei tre ci sono. Serve alla UI per dire «ne manca uno» invece di
  /// «mancano dei dati».
  int get filledCount =>
      (heightCm == null ? 0 : 1) +
      (birthDate == null ? 0 : 1) +
      (sex == null ? 0 : 1);

  /// Anni compiuti a [today]. Non è una formula: è il numero che si mostra
  /// accanto alla data scelta, perché una data di nascita sbagliata di dieci
  /// anni si riconosce solo quando la si vede tradotta in età.
  int? ageOn(DateTime today) {
    final birth = birthDate;
    if (birth == null) {
      return null;
    }
    var years = today.year - birth.year;
    final beforeBirthday =
        today.month < birth.month ||
        (today.month == birth.month && today.day < birth.day);
    if (beforeBirthday) {
      years -= 1;
    }
    return years < 0 ? null : years;
  }

  PersonalDetails copyWith({
    double? heightCm,
    DateTime? birthDate,
    BiologicalSex? sex,
  }) {
    return PersonalDetails(
      heightCm: heightCm ?? this.heightCm,
      birthDate: birthDate ?? this.birthDate,
      sex: sex ?? this.sex,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PersonalDetails &&
      other.heightCm == heightCm &&
      other.birthDate == birthDate &&
      other.sex == sex;

  @override
  int get hashCode => Object.hash(heightCm, birthDate, sex);

  @override
  String toString() =>
      'PersonalDetails(heightCm: $heightCm, birthDate: $birthDate, sex: $sex)';

  /// L'etichetta di giorno di una data scelta dal calendario.
  ///
  /// Il selettore restituisce un `DateTime` in fuso locale a mezzanotte:
  /// salvarlo così e rileggerlo altrove sposterebbe il compleanno di un
  /// giorno ogni volta che cambia l'ora legale.
  static DateTime dayFrom(DateTime picked) =>
      DateTime.utc(picked.year, picked.month, picked.day);
}

/// I limiti dei tre campi, in un posto solo.
///
/// Stanno nel dominio e non in un CHECK di tabella perché `app_profiles` è
/// referenziata da dieci tabelle e la migrazione la estende con `addColumn`,
/// che i vincoli non li può aggiungere: un database migrato e uno nuovo si
/// comporterebbero in modo diverso. Questi numeri sono gli stessi della
/// migrazione Supabase `0006`, che invece i CHECK ce li ha.
abstract final class PersonalDetailsLimits {
  static const double minHeightCm = 50;
  static const double maxHeightCm = 260;

  /// Il CHECK remoto pretende una nascita dopo il 1900.
  static final DateTime earliestBirthDate = DateTime.utc(1900, 1, 2);

  /// Nessuno può essere nato domani. Il limite superiore è oggi: un neonato
  /// che usa un contacalorie non è un caso da coprire, ma inventare un'età
  /// minima significherebbe rifiutare un dato vero senza motivo.
  static DateTime latestBirthDate(DateTime today) =>
      DateTime.utc(today.year, today.month, today.day);

  /// Legge un'altezza scritta a mano, con la virgola italiana.
  ///
  /// Ritorna `null` se la stringa non è un numero: chi chiama distingue il
  /// vuoto (lecito) dal non valido guardando prima `text.isEmpty`.
  static double? parseHeightCm(String raw) {
    final parsed = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (parsed == null || !parsed.isFinite) {
      return null;
    }
    // Al decimo: è la precisione della colonna remota, ed è anche l'unica
    // precisione che un metro da muro può davvero dare.
    return (parsed * 10).round() / 10;
  }

  /// Il messaggio d'errore per un'altezza, o `null` se va bene.
  /// Una stringa vuota è valida: significa «non lo dico».
  static String? validateHeight(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return null;
    }
    final parsed = parseHeightCm(text);
    if (parsed == null) {
      return 'Scrivi un numero, per esempio 182';
    }
    if (parsed < minHeightCm || parsed > maxHeightCm) {
      return 'Fra ${minHeightCm.round()} e ${maxHeightCm.round()} cm';
    }
    return null;
  }
}
