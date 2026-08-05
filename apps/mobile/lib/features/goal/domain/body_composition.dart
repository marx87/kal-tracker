/// Le formule di composizione corporea, tutte pure e deterministiche.
///
/// Sono la base di ogni numero che l'app mostra sull'obiettivo: nessuno di
/// questi valori viene da un modello o da una tabella di stime. Fonte:
/// `docs/ROADMAP.md`, «Decisioni tecniche fissate il 5 agosto 2026».
///
/// La grandezza guida è la **massa magra** (FFM): il peso da solo non dice
/// niente: 88 kg con 72 di massa magra e 88 kg con 64 sono due corpi diversi
/// e due metabolismi diversi.
library;

/// Peso minimo accettato: sotto non è una persona, è un dato sbagliato.
const double _minWeightKg = 20;
const double _maxWeightKg = 500;

/// Oltre il 75% di grasso il calcolo del peso a partire dalla massa magra
/// esplode verso l'infinito. Il limite non è fisiologico, è numerico.
const double _maxBodyFatPct = 75;

/// Formule di composizione corporea.
///
/// Tutti i metodi rifiutano input non finiti o fuori scala invece di
/// restituire `NaN`: un `NaN` che arriva in una `Slider` fa esplodere il
/// frame successivo, e il messaggio d'errore non direbbe da dove viene.
abstract final class BodyComposition {
  /// Metabolismo basale secondo **Katch-McArdle**: `370 + 21,6 × FFM`.
  ///
  /// Scelta al posto di Mifflin-St Jeor perché dipende dalla massa magra e
  /// non dal peso: migliora insieme ai dati della bilancia invece di restare
  /// una stima anagrafica. Verificata sui dati Renpho reali di Marco:
  /// 71,66 kg di massa magra danno 1917,9 kcal contro i 1918 dichiarati
  /// dalla bilancia.
  static double basalMetabolicRate(double fatFreeMassKg) {
    _requireFatFreeMass(fatFreeMassKg);
    return 370 + 21.6 * fatFreeMassKg;
  }

  /// Chili di grasso: `peso × grasso% / 100`. Non si salva, si ricalcola.
  static double fatMassKg({
    required double weightKg,
    required double bodyFatPct,
  }) {
    _requireWeight(weightKg);
    _requireBodyFatPct(bodyFatPct);
    return weightKg * bodyFatPct / 100;
  }

  /// Massa magra: tutto ciò che non è grasso. È la metrica guida.
  static double fatFreeMassKg({
    required double weightKg,
    required double bodyFatPct,
  }) => weightKg - fatMassKg(weightKg: weightKg, bodyFatPct: bodyFatPct);

  /// La percentuale di grasso implicita in una coppia peso + massa magra.
  ///
  /// È l'inverso di [weightAtBodyFat] ed è il calcolo che permette alla
  /// manopola di dire «questo peso, per te, è asciutto» senza mai mostrare
  /// la percentuale all'utente.
  static double bodyFatPct({
    required double weightKg,
    required double fatFreeMassKg,
  }) {
    _requireWeight(weightKg);
    _requireFatFreeMass(fatFreeMassKg);
    return (weightKg - fatFreeMassKg) / weightKg * 100;
  }

  /// Il peso che avresti a quella percentuale di grasso **senza toccare la
  /// massa magra**: `FFM / (1 − grasso%)`.
  ///
  /// È l'equazione che genera l'intera curva del selettore: fissata la massa
  /// magra, peso e definizione non sono due scelte ma una sola.
  static double weightAtBodyFat({
    required double fatFreeMassKg,
    required double bodyFatPct,
  }) {
    _requireFatFreeMass(fatFreeMassKg);
    _requireBodyFatPct(bodyFatPct);
    if (bodyFatPct > _maxBodyFatPct) {
      throw ArgumentError.value(
        bodyFatPct,
        'bodyFatPct',
        'Oltre il $_maxBodyFatPct% il peso calcolato non ha più senso.',
      );
    }
    return fatFreeMassKg / (1 - bodyFatPct / 100);
  }

  /// La massa magra che servirebbe per stare a quel peso con quella
  /// definizione. Confrontata con quella attuale dà il verdetto di
  /// fattibilità: la differenza sono chili di muscolo da costruire o da
  /// perdere, non un giudizio.
  static double fatFreeMassNeeded({
    required double weightKg,
    required double bodyFatPct,
  }) => fatFreeMassKg(weightKg: weightKg, bodyFatPct: bodyFatPct);

  /// BMI: `peso / altezza²`. Non si salva ed è volutamente marginale — a
  /// parità di BMI la composizione può essere opposta.
  static double bodyMassIndex({
    required double weightKg,
    required double heightCm,
  }) {
    _requireWeight(weightKg);
    if (!heightCm.isFinite || heightCm < 50 || heightCm > 260) {
      throw ArgumentError.value(
        heightCm,
        'heightCm',
        'Altezza fuori scala (50-260 cm).',
      );
    }
    final heightM = heightCm / 100;
    return weightKg / (heightM * heightM);
  }

  /// Proteine obiettivo: **grammi per kg di massa magra**, non di peso.
  ///
  /// È la differenza che conta durante un deficit: il grasso non ha bisogno
  /// di proteine, il muscolo sì. Con i 71,66 kg di Marco, 2 g/kg fanno
  /// 143 g al giorno.
  static double proteinGrams({
    required double fatFreeMassKg,
    required double gramsPerKg,
  }) {
    _requireFatFreeMass(fatFreeMassKg);
    if (!gramsPerKg.isFinite || gramsPerKg <= 0 || gramsPerKg > 5) {
      throw ArgumentError.value(
        gramsPerKg,
        'gramsPerKg',
        'Le proteine per kg di massa magra stanno tra 0 e 5 g.',
      );
    }
    return fatFreeMassKg * gramsPerKg;
  }

  /// Le calorie contenute in un chilo di grasso corporeo: 7700 kcal.
  ///
  /// È una costante di conversione, non una misura: serve a tradurre un
  /// ritmo in chili in un deficit in calorie e viceversa.
  static const double kcalPerKgOfFat = 7700;

  static void _requireWeight(double weightKg) {
    if (!weightKg.isFinite ||
        weightKg < _minWeightKg ||
        weightKg > _maxWeightKg) {
      throw ArgumentError.value(
        weightKg,
        'weightKg',
        'Peso fuori scala ($_minWeightKg-$_maxWeightKg kg).',
      );
    }
  }

  static void _requireFatFreeMass(double fatFreeMassKg) {
    if (!fatFreeMassKg.isFinite ||
        fatFreeMassKg < 10 ||
        fatFreeMassKg > _maxWeightKg) {
      throw ArgumentError.value(
        fatFreeMassKg,
        'fatFreeMassKg',
        'Massa magra fuori scala (10-$_maxWeightKg kg).',
      );
    }
  }

  static void _requireBodyFatPct(double bodyFatPct) {
    if (!bodyFatPct.isFinite || bodyFatPct < 0 || bodyFatPct >= 100) {
      throw ArgumentError.value(
        bodyFatPct,
        'bodyFatPct',
        'La percentuale di grasso sta tra 0 e 100.',
      );
    }
  }
}
