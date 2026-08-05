/// Come caricare il bilanciere. Il calcolo è portato invariato da
/// `core/plate_calculator.dart` di Gym Tracker; qui resta SOLO il calcolo,
/// il vestito sta in `presentation/widgets/plate_calculator_sheet.dart`.
library;

/// I dischi in kg che una palestra commerciale ha di sicuro. Le coppie si
/// aggiungono avidamente dal più pesante.
const kPlatesKg = <double>[25, 20, 15, 10, 5, 2.5, 1.25];

/// I bilancieri più comuni, per i pulsanti rapidi.
const kBarPresetsKg = <double>[20, 15, 10, 7.5];

/// Calcola i dischi da mettere su UN lato del bilanciere (l'altro lo
/// specchia), più il residuo che nessuna coppia riesce a coprire.
///
/// Il residuo è diverso da zero quando il peso obiettivo non è la somma di
/// coppie disponibili: 47,5 kg con bilanciere da 20 lascia 1,25 kg per lato
/// che non si possono caricare.
({List<double> perSide, double residual}) computePlateBreakdown({
  required double targetKg,
  required double barKg,
}) {
  if (targetKg <= barKg) return (perSide: const [], residual: 0);
  final perSideTotal = (targetKg - barKg) / 2;
  final plates = <double>[];
  double remaining = perSideTotal;
  for (final plate in kPlatesKg) {
    // Il margine di 1e-6 è quello del sorgente: senza, 2.5 + 1.25 in virgola
    // mobile a volte non arriva a coprire 3.75 e il disco sparisce.
    while (remaining + 1e-6 >= plate) {
      plates.add(plate);
      remaining -= plate;
    }
  }
  return (perSide: plates, residual: remaining);
}

/// Il peso che si carica DAVVERO con quei dischi. È quello che l'utente
/// solleva, e va detto quando non coincide con l'obiettivo.
double achievablePlateTotal({
  required List<double> perSide,
  required double barKg,
}) => barKg + perSide.fold<double>(0, (total, plate) => total + plate) * 2;

/// Formattazione dei kg: intero quando è intero, altrimenti due decimali
/// (1.25 è un disco vero e «1,3» sarebbe sbagliato).
String formatPlateKg(double value) =>
    value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
