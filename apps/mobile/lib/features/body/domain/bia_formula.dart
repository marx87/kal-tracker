import 'package:flutter/foundation.dart';

/// Il sesso anagrafico come lo pretende l'equazione BIA: è un coefficiente,
/// non un'identità. A parità di impedenza, peso e altezza, un corpo maschile
/// ha in media più massa magra, e l'equazione lo mette a sistema con un
/// termine additivo.
enum BiaSex {
  male('M'),
  female('F');

  const BiaSex(this.code);

  /// La lettera salvata in `app_profiles.sex`.
  final String code;

  /// Il valore della variabile *sex* dell'equazione: 1 per l'uomo, 0 per la
  /// donna. È così che è stata pubblicata.
  double get coefficient => this == BiaSex.male ? 1 : 0;

  static BiaSex? fromCode(String? code) => switch (code?.trim().toUpperCase()) {
    'M' => BiaSex.male,
    'F' => BiaSex.female,
    _ => null,
  };
}

/// Quello che serve a una formula BIA per dire qualcosa: la misura (ohm), i
/// due dati del corpo che la bilancia non conosce (peso lo conosce, altezza no)
/// e i due anagrafici del profilo.
@immutable
class BiaInput {
  const BiaInput({
    required this.impedanceOhm,
    required this.weightKg,
    required this.heightCm,
    required this.ageYears,
    required this.sex,
  });

  /// L'impedenza di corpo intero, l'unica cosa che il dispositivo misura.
  final double impedanceOhm;

  final double weightKg;
  final double heightCm;

  /// Anni compiuti **il giorno della pesata**, non oggi: ricalcolare lo
  /// storico con l'età di adesso riscriverebbe il passato con un dato che
  /// allora non era vero.
  final int ageYears;

  final BiaSex sex;

  /// L'indice di impedenza, il cuore di ogni equazione BIA: altezza al
  /// quadrato diviso resistenza. Ha le dimensioni di un volume conduttore, ed
  /// è per questo che predice l'acqua corporea e con lei la massa magra.
  double get impedanceIndex => heightCm * heightCm / impedanceOhm;

  /// Fuori da questi limiti non si estrapola: si dichiara che non si sa.
  ///
  /// Non sono soglie estetiche. Un'impedenza sotto i 150 Ω o sopra i 1200 su
  /// una bilancia piede-piede significa quasi sempre contatto sbagliato o
  /// trama malinterpretata, e un'equazione applicata lì restituisce numeri
  /// che *sembrano* misure.
  bool get isPlausible =>
      impedanceOhm.isFinite &&
      impedanceOhm >= 150 &&
      impedanceOhm <= 1200 &&
      weightKg.isFinite &&
      weightKg >= 20 &&
      weightKg <= 500 &&
      heightCm.isFinite &&
      heightCm >= 100 &&
      heightCm <= 250 &&
      ageYears >= 10 &&
      ageYears <= 120;
}

/// Il risultato di una formula: masse e percentuali, con scritto sopra quale
/// versione le ha prodotte.
///
/// [formulaVersion] non è un dettaglio di servizio: è ciò che permette di
/// rifare lo storico quando la formula migliora, invece di lasciare due
/// tratti di serie calcolati in modo diverso e incomparabili fra loro.
@immutable
class BodyCompositionEstimate {
  const BodyCompositionEstimate({
    required this.formulaVersion,
    required this.fatFreeMassKg,
    required this.fatMassKg,
    required this.bodyFatPct,
    required this.totalBodyWaterL,
    required this.waterPct,
    required this.bmrKcal,
  });

  final String formulaVersion;

  /// La metrica guida di tutto il prodotto: un traguardo di peso raggiunto
  /// perdendo massa magra è un fallimento travestito da successo.
  final double fatFreeMassKg;

  final double fatMassKg;
  final double bodyFatPct;
  final double totalBodyWaterL;
  final double waterPct;

  /// Metabolismo basale con Katch-McArdle, che dipende dalla massa magra e
  /// quindi migliora insieme ai dati.
  final int bmrKcal;
}

/// Una formula BIA: pura, dichiarata, versionata.
///
/// L'interfaccia esiste perché il ricalcolo dello storico (M6.3) ha bisogno
/// di due cose insieme — la formula corrente e quella con cui una riga era
/// stata calcolata — e perché un domani la taratura in doppia lettura
/// produrrà una `bia-v2` senza toccare niente attorno.
@immutable
abstract class BiaFormula {
  const BiaFormula();

  /// Quello che finisce in `body_measurements.formula_version`.
  String get version;

  /// Come si chiama davanti a Marco.
  String get label;

  /// Perché questa e non un'altra. Lo mostra la schermata: una formula di
  /// composizione corporea senza la sua provenienza è esattamente il «giudizio
  /// altrui» che questo progetto rifiuta.
  String get rationale;

  /// Nullo quando i dati non permettono di dire niente: meglio una casella
  /// vuota di un numero inventato.
  BodyCompositionEstimate? estimate(BiaInput input);
}

/// **Deurenberg 1991** — l'equazione scelta per la `bia-v1`.
///
/// > Deurenberg P., van der Kooy K., Leenen R., Weststrate J.A., Seidell J.C.
/// > *Sex and age specific prediction formulas for estimating body composition
/// > from bioelectrical impedance: a cross-validation study.*
/// > Int J Obes 1991;15:17-25.
///
/// FFM = 0,34 · (H²/R) + 15,34 · h + 0,273 · P − 0,127 · E + 4,56 · S − 12,44
///
/// con H in **centimetri** dentro l'indice di impedenza, h in **metri** nel
/// termine lineare, P peso in kg, E età in anni, S sesso (uomo 1, donna 0).
///
/// **Perché questa.** È l'unica equazione classica che usa esattamente i dati
/// che il profilo possiede — altezza, peso, età, sesso — e la sola grandezza
/// che la bilancia misura, la resistenza. Le equazioni più recenti e più
/// accurate (Kyle 2001, la «Geneva») pretendono anche la **reattanza**, che la
/// QN-Scale non trasmette: applicarle inventando una reattanza sarebbe
/// peggio che usarne una più vecchia ma completa. Sun 2003 (NHANES III)
/// userebbe la sola resistenza ma ignora l'età, e l'età è il termine che
/// impedisce alla stessa impedenza di significare la stessa cosa a 20 e a 60
/// anni.
///
/// **Quello che questa formula NON può sapere.** È stata ricavata su misure
/// mano-piede; la bilancia di Marco misura piede-piede, cioè un percorso
/// diverso e più lungo, che legge resistenze sistematicamente più alte. La
/// conseguenza attesa è una percentuale di grasso più alta di quella che
/// mostra l'app Renpho, e non è un errore da correggere di nascosto: è il
/// motivo per cui si salva l'impedenza grezza e per cui le settimane di
/// doppia lettura serviranno a tarare una `bia-v2`. **Il valore assoluto è
/// indicativo, il trend è affidabile.**
class Deurenberg1991Formula extends BiaFormula {
  const Deurenberg1991Formula();

  @override
  String get version => 'bia-v1';

  @override
  String get label => 'Deurenberg 1991';

  @override
  String get rationale =>
      'Usa altezza, peso, età, sesso e la sola resistenza: esattamente ciò '
      'che il profilo sa e ciò che la bilancia misura. È tarata su misure '
      'mano-piede, mentre questa bilancia misura piede-piede: il numero '
      'assoluto è indicativo, il suo andamento no.';

  /// Quanta parte della massa magra è acqua, per massa: 73,2 %.
  ///
  /// Pace & Rathbun, 1945. È una costante di composizione, non una stima
  /// nostra, e vale la pena dichiararla perché è l'unico passaggio fra la
  /// massa magra e la percentuale d'acqua che si legge in schermata.
  static const hydrationOfFatFreeMass = 0.732;

  @override
  BodyCompositionEstimate? estimate(BiaInput input) {
    if (!input.isPlausible) {
      return null;
    }

    final fatFreeMassKg =
        0.34 * input.impedanceIndex +
        15.34 * (input.heightCm / 100) +
        0.273 * input.weightKg -
        0.127 * input.ageYears +
        4.56 * input.sex.coefficient -
        12.44;

    // Una massa magra maggiore del peso, o un grasso oltre i limiti della
    // fisiologia, vuol dire che l'equazione è stata usata fuori dal suo
    // dominio: si tace, non si tronca. Un numero troncato al limite avrebbe
    // l'aria di una misura.
    if (!fatFreeMassKg.isFinite || fatFreeMassKg <= 0) {
      return null;
    }
    final fatMassKg = input.weightKg - fatFreeMassKg;
    final bodyFatPct = fatMassKg / input.weightKg * 100;
    if (bodyFatPct < 2 || bodyFatPct > 70) {
      return null;
    }

    final totalBodyWaterL = fatFreeMassKg * hydrationOfFatFreeMass;

    return BodyCompositionEstimate(
      formulaVersion: version,
      fatFreeMassKg: fatFreeMassKg,
      fatMassKg: fatMassKg,
      bodyFatPct: bodyFatPct,
      totalBodyWaterL: totalBodyWaterL,
      waterPct: totalBodyWaterL / input.weightKg * 100,
      bmrKcal: katchMcArdleBmr(fatFreeMassKg),
    );
  }
}

/// **Katch-McArdle**: `370 + 21,6 × massa magra`.
///
/// È la formula che usa la bilancia stessa — sui dati reali di Marco
/// (71,66 kg di massa magra) restituisce 1917,9 kcal contro le 1918
/// dichiarate — ed è l'unica del gruppo che dipende dalla massa magra invece
/// che dal peso: migliora insieme ai dati, mentre Mifflin-St Jeor resterebbe
/// ferma a guardare un numero sulla bilancia.
int katchMcArdleBmr(double fatFreeMassKg) =>
    (370 + 21.6 * fatFreeMassKg).round();

/// Il registro delle formule: una sola per volta è quella corrente, ma le
/// vecchie devono restare leggibili finché esistono righe calcolate con loro.
abstract final class BiaFormulas {
  /// Tutte quelle mai entrate in produzione, corrente compresa.
  static const all = <BiaFormula>[Deurenberg1991Formula()];

  static const BiaFormula current = Deurenberg1991Formula();

  static String get currentVersion => current.version;

  /// Vero per le versioni prodotte da noi. Serve al ricalcolo: le righe con
  /// `formula_version` nullo portano percentuali **dichiarate da altri**
  /// (digitate a mano dal display Renpho, o importate dal loro CSV) e non si
  /// riscrivono mai — non sono nostre da rifare.
  static bool isOurs(String? version) =>
      version != null && version.startsWith('bia-');

  static BiaFormula? byVersion(String? version) {
    for (final formula in all) {
      if (formula.version == version) {
        return formula;
      }
    }
    return null;
  }
}

/// Mette insieme i dati del profilo e quelli della pesata, o dichiara che non
/// si può.
///
/// È l'unico posto in cui si decide che «il profilo non basta»: senza altezza,
/// data di nascita o sesso nessuna equazione BIA ha qualcosa da dire, e la
/// schermata deve chiederli invece di stimarli. Restituire `null` da qui è
/// molto meglio che avere tre controlli sparsi che un domani divergono.
BiaInput? biaInputFrom({
  required double? heightCm,
  required DateTime? birthDate,
  required String? sexCode,
  required double weightKg,
  required double? impedanceOhm,
  required DateTime measuredAt,
}) {
  final sex = BiaSex.fromCode(sexCode);
  if (heightCm == null || birthDate == null || sex == null) {
    return null;
  }
  if (impedanceOhm == null || impedanceOhm <= 0) {
    return null;
  }
  return BiaInput(
    impedanceOhm: impedanceOhm,
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: ageYearsAt(birthDate, measuredAt),
    sex: sex,
  );
}

/// Anni compiuti a una certa data.
///
/// Sta qui e non in un'utilità generica perché è un ingrediente
/// dell'equazione: il compleanno non ancora arrivato quel giorno vale un anno
/// in meno, e sbagliarlo sposta la massa magra di 127 grammi.
int ageYearsAt(DateTime birthDate, DateTime moment) {
  final birth = birthDate.toUtc();
  final at = moment.toUtc();
  var years = at.year - birth.year;
  final hadBirthday =
      at.month > birth.month ||
      (at.month == birth.month && at.day >= birth.day);
  if (!hadBirthday) {
    years -= 1;
  }
  return years;
}
