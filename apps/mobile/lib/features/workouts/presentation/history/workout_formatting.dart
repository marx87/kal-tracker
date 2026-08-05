import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';

/// Le parole e i numeri dello storico, in un posto solo.
///
/// Le etichette stanno qui e non sui modelli perché i modelli sono dati: la
/// copia italiana è una scelta di schermata, e due schermate diverse devono
/// poter chiamare la stessa cosa allo stesso modo senza copiarsela.

/// Come si legge un tipo di sessione. L'icona non è mai da sola: accanto c'è
/// sempre [WorkoutKindPresentation.label].
extension WorkoutKindPresentation on WorkoutKind {
  String get label => switch (this) {
    WorkoutKind.strength => 'Forza',
    WorkoutKind.hiit => 'Circuito',
    WorkoutKind.cardio => 'Cardio',
    WorkoutKind.mobility => 'Mobilità',
    WorkoutKind.manual => 'Registrata a mano',
    WorkoutKind.mixed => 'Mista',
  };

  IconData get icon => switch (this) {
    WorkoutKind.strength => Icons.fitness_center_rounded,
    WorkoutKind.hiit => Icons.bolt_rounded,
    WorkoutKind.cardio => Icons.directions_run_rounded,
    WorkoutKind.mobility => Icons.self_improvement_rounded,
    WorkoutKind.manual => Icons.edit_calendar_rounded,
    WorkoutKind.mixed => Icons.grid_view_rounded,
  };
}

extension WorkoutBlockPresentation on WorkoutBlock {
  String get label => switch (this) {
    WorkoutBlock.warmup => 'Riscaldamento',
    WorkoutBlock.main => 'Allenamento',
    WorkoutBlock.finisher => 'Finisher',
    WorkoutBlock.cooldown => 'Defaticamento',
  };

  IconData get icon => switch (this) {
    WorkoutBlock.warmup => Icons.local_fire_department_rounded,
    WorkoutBlock.main => Icons.fitness_center_rounded,
    WorkoutBlock.finisher => Icons.bolt_rounded,
    WorkoutBlock.cooldown => Icons.spa_rounded,
  };
}

extension WorkoutTrackingModePresentation on WorkoutTrackingMode {
  String get label => switch (this) {
    WorkoutTrackingMode.weightReps => 'Peso × ripetizioni',
    WorkoutTrackingMode.bodyweightReps => 'Corpo libero',
    WorkoutTrackingMode.timeOnly => 'A tempo',
    WorkoutTrackingMode.timed => 'A tempo, con peso',
    WorkoutTrackingMode.distanceTime => 'Distanza e tempo',
  };
}

/// Numeri interi con il separatore delle migliaia italiano: 1.240.
final NumberFormat _integer = NumberFormat('#,##0', 'it');

/// Un decimale, ma solo se serve: 62,5 kg resta 62,5, 60 kg resta 60.
final NumberFormat _decimal = NumberFormat('#,##0.#', 'it');

String formatWholeNumber(num value) => _integer.format(value);

String formatDecimal(num value) => _decimal.format(value);

/// Volume in chilogrammi. Sotto la tonnellata resta in kg perché è il numero
/// che Marco ha in testa mentre allena; sopra diventa illeggibile.
String formatVolume(double kilograms) => _integer.format(kilograms.round());

String formatKcal(double kcal) => _integer.format(kcal.round());

/// «1h 12min», «45min», «—» quando non c'è.
String formatDuration(Duration? duration) {
  if (duration == null) {
    return '—';
  }
  final minutes = duration.inMinutes;
  if (minutes < 60) {
    return '${minutes}min';
  }
  final hours = duration.inHours;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}min';
}

/// Le ore per esteso, per raccontare un'anomalia: «536 ore».
String formatHours(Duration duration) {
  final hours = duration.inMinutes / 60;
  return hours >= 10
      ? '${_integer.format(hours.round())} ore'
      : '${_decimal.format(hours)} ore';
}

/// Un minutaggio da cronometro: 0:45, 12:30.
String formatClock(int seconds) {
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// Data e ora della sessione, in ora di Roma: gli istanti in tabella sono
/// UTC e leggerli così com'erano sposterebbe indietro di due ore tutto lo
/// storico.
String formatSessionMoment(DateTime instant) {
  final local = AppTime.inRome(instant);
  return '${_capitalize(DateFormat('EEE d MMM', 'it').format(local))}'
      ' · ${DateFormat('HH:mm', 'it').format(local)}';
}

String formatSessionDay(DateTime instant) => _capitalize(
  DateFormat('EEEE d MMMM y', 'it').format(AppTime.inRome(instant)),
);

/// «Agosto 2026»: l'intestazione con cui la lista raggruppa i mesi.
String formatMonth(DateTime instant) =>
    _capitalize(DateFormat('LLLL y', 'it').format(AppTime.inRome(instant)));

/// La chiave con cui due sessioni finiscono nello stesso mese. Va calcolata
/// sul fuso di Roma, altrimenti una sessione del primo del mese alle 00:30
/// cadrebbe nel mese precedente.
String monthKey(DateTime instant) {
  final local = AppTime.inRome(instant);
  return '${local.year}-${local.month.toString().padLeft(2, '0')}';
}

/// Come Gym descriveva una serie, modalità per modalità. Portata invariata:
/// è il formato con cui Marco ha letto un anno di allenamenti.
String describeSet(WorkoutSetEntry set, WorkoutTrackingMode mode) {
  String clock() =>
      set.durationSec == null ? '—' : formatClock(set.durationSec!);

  return switch (mode) {
    WorkoutTrackingMode.weightReps =>
      '${_decimal.format(set.weightKg ?? 0)} kg × ${set.reps ?? 0}',
    WorkoutTrackingMode.bodyweightReps => '${set.reps ?? 0} ripetizioni',
    WorkoutTrackingMode.timeOnly => clock(),
    WorkoutTrackingMode.timed =>
      set.weightKg == null
          ? clock()
          : '${clock()} · ${_decimal.format(set.weightKg)} kg',
    WorkoutTrackingMode.distanceTime =>
      set.distanceM == null
          ? clock()
          : '${clock()} · ${_integer.format(set.distanceM!.round())} m',
  };
}

/// La stessa serie detta ad alta voce. Le abbreviazioni vanno sciolte: un
/// lettore di schermo scandirebbe «kg» lettera per lettera.
String spokenSet(
  WorkoutSetEntry set,
  WorkoutTrackingMode mode, {
  required int number,
}) {
  final prefix = set.isWarmup ? 'Serie di riscaldamento' : 'Serie $number';
  final body = switch (mode) {
    WorkoutTrackingMode.weightReps =>
      '${_decimal.format(set.weightKg ?? 0)} chilogrammi '
          'per ${set.reps ?? 0} ripetizioni',
    WorkoutTrackingMode.bodyweightReps => '${set.reps ?? 0} ripetizioni',
    WorkoutTrackingMode.timeOnly ||
    WorkoutTrackingMode.timed ||
    WorkoutTrackingMode.distanceTime => describeSet(set, mode),
  };
  final closing = set.completed ? 'completata' : 'non completata';
  final effort = set.rpe == null ? '' : ', sforzo percepito ${set.rpe}';
  return '$prefix: $body$effort, $closing';
}

/// Come stava Marco dopo la sessione. Le cinque parole sono quelle di Gym.
String moodLabel(int mood) => switch (mood) {
  1 => 'Distrutto',
  2 => 'Stanco',
  3 => 'Neutro',
  4 => 'Bene',
  _ => 'Carico',
};

/// La nota che accompagna una durata non attendibile.
///
/// Dice sempre la stessa cosa per prima — l'app è rimasta aperta — e poi i
/// numeri veri, entrambi. Il dato NON viene rettificato: chi legge deve
/// sapere che cosa non torna, non trovarsi un numero già aggiustato.
String? suspectDurationNote(WorkoutSummary summary) {
  if (!summary.durationSuspect) {
    return null;
  }
  final registered = summary.registeredDuration;
  final wall = summary.wallClockDuration;
  if (registered != null && wall != null) {
    return 'Durata non attendibile: l\'app è rimasta aperta. '
        'Gym aveva registrato ${formatDuration(registered)}, '
        'fra inizio e fine sono passate ${formatHours(wall)}.';
  }
  if (wall != null) {
    return 'Durata non attendibile: l\'app è rimasta aperta ${formatHours(wall)} '
        'senza che la sessione venisse chiusa.';
  }
  return 'Durata non attendibile: l\'app è rimasta aperta.';
}

String _capitalize(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
