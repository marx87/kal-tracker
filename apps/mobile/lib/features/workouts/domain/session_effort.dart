/// Com'è andata la sessione: tre bersagli, non una scala.
///
/// La scala 1..10 era facoltativa, e nei dati veri risulta compilata in 17
/// sessioni su 29. Il segnale «sforzo percepito in salita» del semaforo del
/// sovrallenamento restava quindi spento non perché andasse tutto bene, ma
/// perché non sapeva — ed è la peggiore delle due cose, perché ha la faccia
/// rassicurante.
///
/// Tre bersagli grossi si toccano col telefono appoggiato sulla panca e si
/// compilano sempre. Si perde precisione e si guadagna copertura: quel
/// segnale confronta MEDIE settimanali con una soglia di 0,75, quindi tre
/// gradini distanti tre punti la superano comunque quando la settimana si
/// sposta davvero. Per un semaforo, essere acceso vale più che essere fine.
library;

/// I tre livelli di fine sessione.
///
/// I numeri non sono decorativi: sono quello che finisce su `workouts.rpe`,
/// colonna vincolata a 1..10 dal database e già piena, nello storico
/// importato da Gym, di valori su quella stessa scala. Restare nella colonna
/// di prima significa che le sessioni vecchie e quelle nuove si mediano
/// insieme senza conversioni e senza una seconda colonna da tenere allineata.
enum SessionEffort {
  facile(rpe: 3, label: 'Facile', hint: 'Ne avevo ancora parecchio'),
  giusta(rpe: 6, label: 'Giusta', hint: 'L\'ho finita, senza svuotarmi'),
  dura(rpe: 9, label: 'Dura', hint: 'Ho tirato fuori tutto quello che avevo');

  const SessionEffort({
    required this.rpe,
    required this.label,
    required this.hint,
  });

  /// Il valore scritto su `workouts.rpe`.
  final int rpe;

  /// La parola sul bersaglio. È lei a portare il significato: il colore da
  /// solo non basta mai, e chi ascolta con lo schermo spento non lo vede.
  final String label;

  /// La frase che disambigua il bersaglio senza chiedere di interpretare un
  /// numero: «6 su 10» non dice a nessuno se è tanto o poco.
  final String hint;

  /// Il bersaglio più vicino a un RPE numerico, per rileggere lo storico.
  ///
  /// Serve perché la colonna è una sola e porta due generazioni di dati: le
  /// sessioni nuove scrivono 3, 6 o 9, quelle importate da Gym Tracker
  /// qualunque valore da 1 a 10. Mostrare «RPE 6» a chi ha toccato «Giusta»
  /// gli restituisce un numero che non ha mai scelto, e per giunta in una
  /// scala che l'app non gli ha mai mostrato.
  static SessionEffort? nearest(int? rpe) {
    if (rpe == null) {
      return null;
    }
    var best = SessionEffort.facile;
    for (final effort in SessionEffort.values) {
      if ((effort.rpe - rpe).abs() < (best.rpe - rpe).abs()) {
        best = effort;
      }
    }
    return best;
  }

  /// Come si legge ad alta voce: parola, spiegazione e niente numeri.
  String get spoken => '$label: ${hint.toLowerCase()}';
}
