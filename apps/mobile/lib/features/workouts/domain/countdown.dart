/// L'unica regola di conversione «scadenza assoluta → secondi da mostrare».
///
/// Sta in un file suo perché la usano sia il timer di recupero sia il
/// circuito, e perché è il pezzo che rende la sessione onesta dopo un giro in
/// secondo piano: i `Timer.periodic` di Flutter si fermano, la scadenza no.
library;

/// Secondi interi ancora visibili per la scadenza [deadline].
///
/// Arrotonda per ECCESSO: senza, si mostrerebbe zero mentre manca ancora
/// mezzo secondo. Copia verbatim da `rest_timer.dart` di Gym Tracker.
int remainingCountdownSeconds(DateTime deadline, DateTime now) {
  final milliseconds = deadline.difference(now).inMilliseconds;
  if (milliseconds <= 0) return 0;
  return (milliseconds + 999) ~/ 1000;
}
