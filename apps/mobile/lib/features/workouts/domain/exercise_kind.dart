/// I due enum che la sessione dal vivo usa per classificare un esercizio.
///
/// NON sono dichiarati qui. Vivono in
/// `features/exercises/domain/exercise_models.dart` insieme al catalogo, e da
/// lì li riesporto.
///
/// Il motivo è concreto: avevo cominciato a dichiararli in questa cartella
/// (in Gym Tracker stavano in `features/exercises/exercise.dart`, che qui non
/// esisteva ancora). Poi il catalogo è arrivato, con gli STESSI dodici gruppi
/// nello stesso ordine — ma per Dart due enum con lo stesso nome in due file
/// diversi restano due TIPI diversi. Con entrambi vivi, il gruppo muscolare
/// letto dal catalogo non sarebbe assegnabile a `WorkoutExercise.muscleGroup`,
/// e ogni chiamante avrebbe dovuto scrivere una funzione di conversione fra
/// due enum identici. Meglio una riga di export.
///
/// I `.name` restano i valori che il database accetta
/// (`CHECK (muscle_group_snapshot IN (...))`, `CHECK (tracking_mode IN (...))`
/// in `app_database.dart`): rinominare una costante rompe la scrittura, non la
/// traduzione.
library;

import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';

export 'package:kal_tracker/features/exercises/domain/exercise_models.dart'
    show ExerciseTrackingMode, MuscleGroup;

/// Il gruppo muscolare, o `null` se il nome non è riconosciuto.
///
/// `MuscleGroup.fromStorage` è tollerante e ripiega su `altro`: giusto in
/// lettura, sbagliato QUI. Nella sessione dal vivo «gruppo assente» e «gruppo
/// altro» sono due cose diverse — la colonna `muscle_group_snapshot` è
/// nullable — e valgono lo stesso numero di MET ma non lo stesso significato:
/// il primo è un dato mancante da segnalare, il secondo è una scelta.
MuscleGroup? muscleGroupOrNull(String? storedName) {
  if (storedName == null) return null;
  for (final group in MuscleGroup.values) {
    if (group.name == storedName) return group;
  }
  return null;
}

/// La modalità di misura, o `null` se il nome non è riconosciuto.
///
/// Stessa ragione: `fromStorage` ripiegherebbe su `weightReps`, e una riga
/// «peso × ripetizioni» inventata su un esercizio a tempo si porta dietro
/// campi che nessuno ha mai compilato.
ExerciseTrackingMode? trackingModeOrNull(String? storedName) {
  if (storedName == null) return null;
  for (final mode in ExerciseTrackingMode.values) {
    if (mode.name == storedName) return mode;
  }
  return null;
}
