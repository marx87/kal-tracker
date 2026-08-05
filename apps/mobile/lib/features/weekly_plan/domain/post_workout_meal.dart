/// Dove cade il pasto proteico quando ci si allena.
///
/// Il pianificatore deve sapere non solo IN QUALI GIORNI Marco si allena, ma
/// anche A CHE ORA: «dopo l'allenamento» senza un orario non è una posizione.
/// L'ora non è cablata e non la inventa il modello — si misura sullo storico
/// vero delle sessioni ([typicalTrainingHour]) e si traduce in un pasto con
/// una funzione pura ([postWorkoutMeal]). Il modello riceve il risultato già
/// deciso: sceglie solo la ricetta.
///
/// Tutto qui dentro è puro e testabile senza database, senza rete e senza
/// Flutter.
library;

import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

/// L'ora civile in cui un pasto di solito si fa.
///
/// Serve a ordinare i pasti nel tempo, cosa che [PlanMeal.values] non fa: lì
/// lo spuntino sta in fondo perché è l'ultimo del contratto, ma nella
/// giornata cade fra pranzo e cena.
extension PlanMealHour on PlanMeal {
  int get usualHour => switch (this) {
    PlanMeal.colazione => 8,
    PlanMeal.pranzo => 13,
    PlanMeal.spuntino => 17,
    PlanMeal.cena => 20,
  };
}

/// L'ora in cui Marco si allena di solito, letta dallo storico reale.
///
/// Mediana e non media: una sessione dimenticata aperta o un allenamento
/// insolito all'alba sposterebbero la media di ore, la mediana no.
/// Gli istanti arrivano da drift in UTC e vanno riletti a Roma, altrimenti
/// d'estate ogni sessione risulta due ore prima.
///
/// Torna null quando non c'è storico: senza dati non si tira a indovinare, e
/// il piano semplicemente non riceve il suggerimento.
int? typicalTrainingHour(Iterable<DateTime> startedAt) {
  final hours = [for (final instant in startedAt) AppTime.inRome(instant).hour]
    ..sort();
  if (hours.isEmpty) {
    return null;
  }
  return hours[hours.length ~/ 2];
}

/// Il primo pasto richiesto che cade DOPO l'allenamento.
///
/// Il confronto è stretto: un pasto alla stessa ora della sessione non è
/// «dopo». Se nessun pasto richiesto viene dopo (ci si allena la sera tardi e
/// si pianifica solo la colazione) torna null, e il pianificatore non riceve
/// nessuna indicazione invece di riceverne una falsa.
PlanMeal? postWorkoutMeal({
  required Iterable<PlanMeal> meals,
  required int? trainingHour,
}) {
  if (trainingHour == null) {
    return null;
  }
  PlanMeal? best;
  for (final meal in meals) {
    if (meal.usualHour <= trainingHour) {
      continue;
    }
    if (best == null || meal.usualHour < best.usualHour) {
      best = meal;
    }
  }
  return best;
}
