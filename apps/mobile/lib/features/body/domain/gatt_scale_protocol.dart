import 'package:flutter/foundation.dart';

/// Il profilo **standard** del Bluetooth per le bilance.
///
/// A differenza del protocollo QN — che è stato ricavato per tentativi da chi
/// ha decodificato le trame — questo è pubblicato dal Bluetooth SIG: *Weight
/// Scale Service* (`0x181D`) e *Body Composition Service* (`0x181B`). Chi lo
/// implementa lo implementa uguale, quindi qui non c'è niente da indovinare.
///
/// **Perché esiste questo file.** La bilancia di Marco si chiama `R-MSC02`:
/// ci si collega, ma non espone né `ffe0` né `fff0`. Molte bilance recenti
/// hanno smesso di usare il dialogo proprietario di Qingniu e si sono messe in
/// regola con lo standard, che dà anche di più — l'impedenza c'è, e in chiaro.
///
/// **Cosa NON fa questo file.** Le percentuali che la bilancia manda si
/// leggono ma non si usano per la composizione: quella la calcola
/// `bia_formula.dart` dall'impedenza, con una formula nostra e versionata, così
/// lo storico resta ricalcolabile. Il grasso dichiarato dalla bilancia si
/// conserva solo come riscontro.
abstract final class GattScale {
  /// *Body Composition Service*: peso **e** impedenza. È quello che si vuole.
  static const bodyCompositionService = '0000181b-0000-1000-8000-00805f9b34fb';
  static const bodyCompositionMeasurement =
      '00002a9c-0000-1000-8000-00805f9b34fb';

  /// *Weight Scale Service*: solo il peso. Ripiego quando l'altro non c'è —
  /// una pesata di solo peso è un esito legittimo, già previsto.
  static const weightScaleService = '0000181d-0000-1000-8000-00805f9b34fb';
  static const weightMeasurement = '00002a9d-0000-1000-8000-00805f9b34fb';

  /// `0xFFFF` sul **grasso** in `0x2A9C` e sul **peso** in `0x2A9D` significa
  /// «pesata non riuscita» (BCS 1.0.1 §3.2.1.2, WSS 1.0.1 §3.2.1.2). Non
  /// significa «campo assente»: un campo che non c'è si dichiara spegnendo il
  /// suo bit nei flag, non mandando un valore riservato.
  ///
  /// Sugli altri campi la specifica **non definisce nessun valore speciale**,
  /// e qui lo trattiamo lo stesso come «non disponibile». È una difesa nostra,
  /// dichiarata: 0xFFFF varrebbe 6553,5 Ω o 327,675 kg, numeri che un corpo
  /// umano non produce, e registrarli sarebbe peggio che tacere.
  static const measurementUnsuccessful = 0xFFFF;

  /// Un'unità di massa in SI vale cinque grammi; in imperiale, un centesimo
  /// di libbra.
  static const massResolutionSiKg = 0.005;
  static const massResolutionImperialLb = 0.01;

  /// Una libbra in chilogrammi. Serve perché la bilancia lasciata in libbre
  /// dall'app del costruttore continuerebbe a mandarle, e nessuno se ne
  /// accorgerebbe finché il peso non fosse assurdo.
  static const poundInKilograms = 0.45359237;
}

/// Quale delle due caratteristiche standard stiamo ascoltando.
enum GattScaleCharacteristic {
  /// `0x2A9C` — peso, impedenza e percentuali.
  bodyComposition,

  /// `0x2A9D` — il solo peso.
  weight,
}

/// Una misura letta dal profilo standard.
@immutable
class GattScaleMeasurement {
  const GattScaleMeasurement({
    required this.hex,
    this.weightKg,
    this.impedanceOhm,
    this.bodyFatPct,
    this.waterPct,
    this.musclePct,
    this.basalMetabolismKcal,
    this.splitMeasurement = false,
    this.failed = false,
  });

  /// La trama grezza, che si conserva sempre: la decodifica di oggi potrebbe
  /// non essere quella definitiva.
  final String hex;

  /// Nullo quando la trama non porta il peso — succede davvero, perché nel
  /// profilo composizione il peso è un campo **opzionale**.
  final double? weightKg;

  final double? impedanceOhm;

  /// Il grasso dichiarato dalla bilancia. Non entra nella composizione, che
  /// resta calcolata da noi: serve solo come riscontro nel registro.
  final double? bodyFatPct;

  final double? waterPct;
  final double? musclePct;
  final double? basalMetabolismKcal;

  /// Questa misura è spezzata su **due** pacchetti (bit 12 dei flag), perché
  /// i campi non stavano nell'MTU.
  ///
  /// **Non vuol dire «ne arriva un altro dopo di me».** La specifica (BCS
  /// 1.0.1 §3.2.1) impone il bit acceso in *entrambi* i pacchetti: descrive la
  /// misura, non il pacchetto. Leggerlo come «continua» — che è l'errore che
  /// avevo fatto — significa non chiudere mai una pesata spezzata, nemmeno
  /// quando il secondo pacchetto è arrivato: si aspetta un terzo che non
  /// esiste, finché scade il tempo di salita con peso e impedenza già in mano.
  ///
  /// Per questo non decide niente: serve solo al registro. Quando chiudere lo
  /// dicono i pezzi raccolti, non i flag.
  final bool splitMeasurement;

  /// La bilancia dichiara che **la pesata non è riuscita**: `0xFFFF` nel
  /// grasso (`0x2A9C`) o nel peso (`0x2A9D`). È un esito, non un guasto del
  /// collegamento, e va detto invece di mostrare una misura vuota.
  final bool failed;

  bool get hasWeight => weightKg != null && weightKg! > 0;
  bool get hasImpedance => impedanceOhm != null && impedanceOhm! > 0;

  @override
  String toString() {
    if (failed) {
      return 'la bilancia dichiara la pesata non riuscita';
    }
    final parti = <String>[
      if (hasWeight) '${weightKg!.toStringAsFixed(2)} kg',
      if (hasImpedance) '${impedanceOhm!.toStringAsFixed(0)} Ω',
      if (bodyFatPct != null) 'grasso ${bodyFatPct!.toStringAsFixed(1)}%',
      if (splitMeasurement) 'misura spezzata in due pacchetti',
    ];
    return parti.isEmpty
        ? 'misura vuota'
        : 'misura standard: ${parti.join(', ')}';
  }
}

/// Decodifica una trama del profilo standard.
///
/// Torna `null` quando la trama è troppo corta per essere quella dichiarata:
/// meglio una riga di registro che dice «illeggibile» che un peso inventato.
GattScaleMeasurement? decodeGattFrame(
  List<int> bytes, {
  required GattScaleCharacteristic characteristic,
}) => switch (characteristic) {
  GattScaleCharacteristic.bodyComposition => _decodeBodyComposition(bytes),
  GattScaleCharacteristic.weight => _decodeWeight(bytes),
};

/// `0x2A9C` — *Body Composition Measurement*.
///
/// I campi opzionali arrivano **in un ordine fisso**, ciascuno presente solo
/// se il suo bit è acceso nei flag. Leggerli fuori ordine sposterebbe tutto il
/// resto della trama, quindi qui l'ordine è quello della specifica e non va
/// riorganizzato per comodità.
GattScaleMeasurement? _decodeBodyComposition(List<int> bytes) {
  if (bytes.length < 4) {
    return null;
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final flags = data.getUint16(0, Endian.little);
  final imperial = flags & 0x0001 != 0;
  final massUnit = imperial
      ? GattScale.massResolutionImperialLb
      : GattScale.massResolutionSiKg;

  var offset = 2;
  double? leggiUint16(double scala) {
    if (offset + 2 > bytes.length) {
      return null;
    }
    final raw = data.getUint16(offset, Endian.little);
    offset += 2;
    return raw == GattScale.measurementUnsuccessful ? null : raw * scala;
  }

  // Il grasso è l'unico campo sempre presente, subito dopo i flag — anche nel
  // secondo pacchetto di una misura spezzata: l'esenzione della specifica vale
  // solo per data e identificativo utente.
  final grassoRaw = data.getUint16(2, Endian.little);
  final fallita = grassoRaw == GattScale.measurementUnsuccessful;
  final bodyFat = leggiUint16(0.1);
  if (fallita) {
    // Pesata dichiarata non riuscita: la specifica impone che in questo caso
    // tutti i campi opzionali tranne data e utente siano assenti, quindi non
    // c'è altro da leggere e ogni valore ricavato da qui in poi sarebbe
    // inventato.
    return GattScaleMeasurement(hex: gattHex(bytes), failed: true);
  }

  if (flags & 0x0002 != 0) {
    offset += 7; // Data e ora: non serve, la nostra è più affidabile.
  }
  if (flags & 0x0004 != 0) {
    offset += 1; // Identificativo dell'utente sulla bilancia.
  }
  // Il metabolismo basale viaggia in kilojoule.
  final basalKj = flags & 0x0008 != 0 ? leggiUint16(1) : null;
  final muscle = flags & 0x0010 != 0 ? leggiUint16(0.1) : null;
  if (flags & 0x0020 != 0) {
    leggiUint16(massUnit); // Massa muscolare: la ricaviamo dall'impedenza.
  }
  if (flags & 0x0040 != 0) {
    leggiUint16(massUnit); // Massa magra, idem.
  }
  if (flags & 0x0080 != 0) {
    leggiUint16(massUnit); // Massa magra molle.
  }
  final waterMass = flags & 0x0100 != 0 ? leggiUint16(massUnit) : null;
  // L'impedenza: il solo numero che la bilancia misura davvero, e l'unico da
  // cui vale la pena ricavare qualcosa.
  // La risoluzione è un decimo di ohm. Vale la pena scriverlo: il GATT
  // Specification Supplement si contraddice — l'esponente decimale dice 0,01,
  // la prosa normativa dice «unit is 1/10 of an Ohm» — e questa è la lettura
  // che concorda con la prosa e con la vecchia definizione XML del SIG. Se un
  // giorno l'impedenza uscisse dieci volte fuori scala, questa riga è l'unico
  // posto da guardare: a valle c'è la BIA, e un fattore dieci non si nota come
  // errore ma come un altro corpo.
  final impedance = flags & 0x0200 != 0 ? leggiUint16(0.1) : null;
  final weight = flags & 0x0400 != 0 ? leggiUint16(massUnit) : null;

  final weightKg = weight == null
      ? null
      : (imperial ? weight * GattScale.poundInKilograms : weight);

  return GattScaleMeasurement(
    hex: gattHex(bytes),
    weightKg: weightKg,
    impedanceOhm: impedance,
    bodyFatPct: bodyFat,
    musclePct: muscle,
    // L'acqua arriva in massa, non in percentuale: diventa una percentuale
    // solo se sappiamo anche il peso.
    waterPct: waterMass != null && weightKg != null && weightKg > 0
        ? ((imperial ? waterMass * GattScale.poundInKilograms : waterMass) /
                  weightKg) *
              100
        : null,
    // Un kilojoule è 0,239 kcal.
    basalMetabolismKcal: basalKj == null ? null : basalKj * 0.239005736,
    splitMeasurement: flags & 0x1000 != 0,
  );
}

/// `0x2A9D` — *Weight Measurement*. Solo il peso, e i flag stanno in un byte.
GattScaleMeasurement? _decodeWeight(List<int> bytes) {
  if (bytes.length < 3) {
    return null;
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final flags = data.getUint8(0);
  final imperial = flags & 0x01 != 0;
  final raw = data.getUint16(1, Endian.little);
  if (raw == GattScale.measurementUnsuccessful) {
    return GattScaleMeasurement(hex: gattHex(bytes), failed: true);
  }
  final weight = imperial
      ? raw * GattScale.massResolutionImperialLb * GattScale.poundInKilograms
      : raw * GattScale.massResolutionSiKg;
  return GattScaleMeasurement(hex: gattHex(bytes), weightKg: weight);
}

/// La trama in esadecimale, per il registro.
String gattHex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
