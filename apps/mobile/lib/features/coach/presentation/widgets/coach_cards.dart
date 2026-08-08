import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/checkin/domain/neat_trend.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_dates.dart';
import 'package:kal_tracker/features/coach/domain/coach_false_movement.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:kal_tracker/features/coach/domain/coach_overtraining.dart';
import 'package:kal_tracker/features/coach/domain/coach_projection.dart';
import 'package:kal_tracker/features/coach/domain/coach_recomposition.dart';

/// Traduzione dei verdetti del dominio nei tre livelli del design system.
///
/// Sta qui e non nel dominio apposta: il dominio non conosce Material, e il
/// giorno in cui i livelli diventano quattro cambia solo questa mappa.
AppStatusLevel? statusOfAdherence(AdherenceGrade grade) => switch (grade) {
  AdherenceGrade.onTrack => AppStatusLevel.good,
  AdherenceGrade.drifting => AppStatusLevel.warning,
  AdherenceGrade.off => AppStatusLevel.critical,
  AdherenceGrade.unknown => null,
};

AppStatusLevel statusOfOvertraining(OvertrainingLevel level) => switch (level) {
  OvertrainingLevel.clear => AppStatusLevel.good,
  OvertrainingLevel.watch => AppStatusLevel.warning,
  OvertrainingLevel.deload => AppStatusLevel.critical,
};

AppStatusLevel? statusOfLeanTrend(LeanMassTrend trend) => switch (trend) {
  LeanMassTrend.holding || LeanMassTrend.rising => AppStatusLevel.good,
  LeanMassTrend.falling => AppStatusLevel.critical,
  LeanMassTrend.unknown => null,
};

/// Un colore solo, per il calo.
///
/// «Ti stai muovendo di più» non prende il verde e «il movimento è lo stesso»
/// non prende niente: il dominio del NEAT emette un solo verdetto che chiede
/// qualcosa a chi legge, ed è quello. Colorare anche gli altri due
/// aggiungerebbe un giudizio che nessuno ha dato — camminare di più può anche
/// essere la fame che sale, non è per forza una buona notizia.
///
/// Ed è `warning`, non `critical`: la risposta è guardare qui prima di
/// tagliare le calorie, non fermare tutto.
AppStatusLevel? statusOfNeat(NeatDirection direction) => switch (direction) {
  NeatDirection.down => AppStatusLevel.warning,
  NeatDirection.up || NeatDirection.steady || NeatDirection.unknown => null,
};

/// **Quanto ci si è mossi, contro la settimana prima.**
///
/// Nel rapporto sta sopra il consumo apposta: il consumo misurato registra il
/// crollo del NEAT ma non sa spiegarlo, e chi legge «consumi meno» per primo
/// pensa alle calorie da togliere. La causa possibile si nomina prima della
/// proposta, non dopo.
class CoachNeatCard extends StatelessWidget {
  const CoachNeatCard({required this.trend, super.key});

  final NeatTrend trend;

  @override
  Widget build(BuildContext context) {
    final line = trend.line;
    if (line == null) {
      return const SizedBox.shrink();
    }
    final fell = trend.direction == NeatDirection.down;

    return SectionCard(
      key: const Key('coach_neat_card'),
      title: 'Movimento',
      // Il sottotitolo dichiara l'esclusione: questo numero non entra in
      // nessuna formula del rapporto, e prometterlo sarebbe peggio che tacerlo.
      subtitle: 'Quello fuori dalla palestra: spiega i numeri, non li cambia',
      icon: Icons.directions_walk_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Headline(text: line, status: statusOfNeat(trend.direction)),
          // La percentuale compare solo dopo che il calo è stato dichiarato.
          // Da sei a quattro minuti al giorno è lo stesso −33 % di diecimila
          // passi che diventano seimila, e stamparlo sotto «il movimento è lo
          // stesso» farebbe litigare la card con sé stessa: la soglia in
          // valore assoluto sta nel dominio, e qui si rispetta.
          if (trend.change case final change? when fell)
            StatRow(
              label: 'Quanto in meno',
              value: coachSignedNumber(change * 100, decimals: 0),
              unit: '%',
              unitSemantics: 'per cento',
              caption: 'Sulla media al giorno, non su un giorno solo',
            ),
          // Il perché la frase del dominio non lo può dire, perché il dominio
          // del check-in non sa che esiste un consumo misurato: è il pezzo che
          // trasforma «ti muovi di meno» nella causa di quello che si legge
          // nella card dopo.
          if (fell)
            const _Note(
              key: Key('coach_neat_cause'),
              text:
                  'Il consumo misurato ha già dentro questa camminata in meno: '
                  'registra il calo, ma non sa dire che è stato il movimento a '
                  'farlo.',
            ),
        ],
      ),
    );
  }
}

/// Il consumo della settimana e da dove viene il numero.
class CoachTdeeCard extends StatelessWidget {
  const CoachTdeeCard({required this.metrics, super.key});

  final CoachMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final tdee = metrics.tdee;
    final change = tdee.weightChangeKg;
    return SectionCard(
      key: const Key('coach_tdee_card'),
      title: 'Quanto consumi',
      subtitle: tdee.isMeasured
          ? 'Misurato sui tuoi dati, non su una tabella'
          : 'Ancora una stima: serve un po’ di storia',
      icon: Icons.local_fire_department_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow(
            label: 'Consumo giornaliero',
            value: tdee.kcal.round().toString(),
            unit: 'kcal',
            unitSemantics: 'chilocalorie',
            caption: tdee.estimate.explanation,
            trailing: StatusChip(
              level: tdee.isMeasured
                  ? AppStatusLevel.good
                  : AppStatusLevel.warning,
              label: tdee.isMeasured ? 'Misurato' : 'Stimato',
              compact: true,
            ),
          ),
          if (tdee.averageDailyKcal case final eaten?)
            StatRow(
              label: 'Media mangiata',
              value: eaten.round().toString(),
              unit: 'kcal',
              unitSemantics: 'chilocalorie',
              caption: '${coachDaysLabel(tdee.diaryDays)} di diario su 7',
            ),
          if (change != null)
            StatRow(
              label: 'Peso, media a 7 giorni',
              value: coachSignedNumber(change, decimals: 2),
              unit: 'kg',
              unitSemantics: 'chilogrammi',
              caption: 'Rispetto alla media della settimana prima',
            ),
          if (tdee.missingDataReason case final reason?) _Note(text: reason),
        ],
      ),
    );
  }
}

/// Quanto il reale si è discostato dal previsto.
class CoachAdherenceCard extends StatelessWidget {
  const CoachAdherenceCard({required this.adherence, super.key});

  final WeeklyAdherence adherence;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      key: const Key('coach_adherence_card'),
      title: 'Aderenza',
      subtitle: 'Il reale contro il previsto',
      icon: Icons.checklist_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in adherence.lines) _AdherenceRow(line: line),
        ],
      ),
    );
  }
}

class _AdherenceRow extends StatelessWidget {
  const _AdherenceRow({required this.line});

  final AdherenceLine line;

  @override
  Widget build(BuildContext context) {
    final status = statusOfAdherence(line.grade);
    final actual = line.actual;
    final planned = line.planned;
    final caption = StringBuffer();
    if (planned != null) {
      caption.write('Previsto ${coachNumber(planned, decimals: 0)}');
      if (line.unit.isNotEmpty) {
        caption.write(' ${line.unit}');
      }
    }
    if (line.daysMissing > 0 && line.daysExpected == 7) {
      if (caption.isNotEmpty) {
        caption.write(' · ');
      }
      caption.write('${coachDaysLabel(line.daysMissing)} senza diario');
    }

    return StatRow(
      label: line.label,
      value: actual == null ? '—' : coachNumber(actual, decimals: 0),
      unit: line.unit.isEmpty ? null : line.unit,
      caption: caption.isEmpty ? null : caption.toString(),
      trailing: status == null
          ? null
          : StatusChip(level: status, label: line.grade.label, compact: true),
    );
  }
}

/// Massa magra e massa grassa, sempre a medie di 7 giorni.
class CoachRecompositionCard extends StatelessWidget {
  const CoachRecompositionCard({required this.recomposition, super.key});

  final Recomposition recomposition;

  @override
  Widget build(BuildContext context) {
    final status = statusOfLeanTrend(recomposition.leanTrend);
    return SectionCard(
      key: const Key('coach_recomposition_card'),
      title: 'Ricomposizione',
      subtitle: 'Medie a 7 giorni, mai due pesate',
      icon: Icons.donut_small_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Headline(text: recomposition.headline, status: status),
          if (recomposition.leanChangeKg case final lean?)
            StatRow(
              label: 'Massa magra',
              value: coachSignedNumber(lean, decimals: 2),
              unit: 'kg',
              unitSemantics: 'chilogrammi',
              caption: 'Rispetto alla settimana prima',
            ),
          if (recomposition.fatChangeKg case final fat?)
            StatRow(
              label: 'Massa grassa',
              value: coachSignedNumber(fat, decimals: 2),
              unit: 'kg',
              unitSemantics: 'chilogrammi',
              caption: 'Rispetto alla settimana prima',
            ),
        ],
      ),
    );
  }
}

/// La proiezione: distanza dalla data, mai una colpa.
class CoachProjectionCard extends StatelessWidget {
  const CoachProjectionCard({required this.projection, super.key});

  final GoalProjection projection;

  @override
  Widget build(BuildContext context) {
    final rate = projection.observedKgPerWeek;
    return SectionCard(
      key: const Key('coach_projection_card'),
      title: 'Dove arrivi',
      subtitle: 'A questo ritmo, non a quello promesso',
      icon: Icons.flag_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Headline(text: projection.headline),
          if (rate != null)
            StatRow(
              label: 'Ritmo osservato',
              value: coachSignedNumber(rate, decimals: 2),
              unit: 'kg/sett.',
              unitSemantics: 'chilogrammi a settimana',
              caption: projection.weeksObserved > 0
                  ? 'Misurato su ${coachWeeksLabel(projection.weeksObserved)}'
                  : null,
            ),
          if (projection.plannedDate case final planned?)
            StatRow(
              label: 'Data promessa',
              value: coachDayLabel(planned),
              caption: 'Quella dell’obiettivo, al ritmo scelto',
            ),
        ],
      ),
    );
  }
}

/// Il semaforo del sovrallenamento, con i buchi dichiarati.
class CoachOvertrainingCard extends StatelessWidget {
  const CoachOvertrainingCard({required this.light, super.key});

  final OvertrainingLight light;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      key: const Key('coach_overtraining_card'),
      title: 'Sovrallenamento',
      subtitle: 'Cinque segnali, e quelli che non so',
      icon: Icons.battery_alert_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Headline(
            text: light.headline,
            status: statusOfOvertraining(light.level),
          ),
          for (final reason in light.reasons) _Bullet(text: reason),
          if (light.missingDataNote case final note?) _Note(text: note),
        ],
      ),
    );
  }
}

/// «Quel calo è acqua, non grasso».
class CoachFalseMovementCard extends StatelessWidget {
  const CoachFalseMovementCard({required this.movement, super.key});

  final FalseMovement movement;

  @override
  Widget build(BuildContext context) {
    final explanation = movement.explanation;
    if (explanation == null) {
      return const SizedBox.shrink();
    }
    return SectionCard(
      key: const Key('coach_false_movement_card'),
      title: 'Non era grasso',
      subtitle: 'Quando la bilancia si muove per altro',
      icon: Icons.water_drop_outlined,
      child: _Headline(text: explanation),
    );
  }
}

/// **Il commento del modello.** Sotto ai numeri, mai al posto loro.
///
/// Col Mac spento questa card dice la verità e mostra comunque l'ultimo
/// commento arrivato, con la sua data: un rapporto vecchio dichiarato vale
/// più di uno schermo vuoto.
class CoachNarrativeCard extends StatelessWidget {
  const CoachNarrativeCard({
    required this.narrative,
    required this.isWaiting,
    required this.currentWeekEnd,
    this.error,
    this.busy = false,
    this.onRequest,
    this.onCancel,
    super.key,
  });

  final CoachNarrative? narrative;
  final bool isWaiting;

  /// La domenica del rapporto che si sta guardando: serve a dire se il
  /// commento è di questa settimana o di una vecchia.
  final DateTime currentWeekEnd;

  final String? error;
  final bool busy;
  final VoidCallback? onRequest;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final text = narrative;
    final isStale = text != null && text.week.end != currentWeekEnd;

    return SectionCard(
      key: const Key('coach_narrative_card'),
      title: 'Il perché',
      subtitle: 'Le parole le scrive il Mac, i numeri no',
      icon: Icons.chat_bubble_outline_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isWaiting)
            const _Waiting()
          else if (error case final error?)
            _Note(key: const Key('coach_narrative_error'), text: error),
          if (text == null && !isWaiting) ...[
            const SizedBox(height: 2),
            Text(
              'Nessun commento, per ora. Il rapporto qui sopra è completo '
              'lo stesso: sono numeri calcolati sul telefono.',
              key: const Key('coach_narrative_empty'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
          ],
          if (text != null) ...[
            if (isStale)
              _Note(
                key: const Key('coach_narrative_stale'),
                text:
                    'Questo commento è della ${coachWeekdayLabel(text.week.end)}: '
                    'quello di questa settimana non è ancora arrivato.',
              ),
            if (text.headline case final headline?) ...[
              const SizedBox(height: 4),
              Text(headline, style: theme.textTheme.titleMedium),
            ],
            for (final paragraph in text.paragraphs) ...[
              const SizedBox(height: 10),
              Text(
                paragraph,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
            ],
            if (text.droppedParagraphs > 0)
              _Note(
                text:
                    'Ho tolto ${coachParagraphsLabel(text.droppedParagraphs)} '
                    'perché contenevano cifre: i numeri li calcola l’app.',
              ),
          ],
          const SizedBox(height: 14),
          if (isWaiting)
            OutlinedButton(
              key: const Key('coach_cancel_button'),
              onPressed: onCancel,
              child: const Text('Smetti di aspettare'),
            )
          else
            FilledButton(
              key: const Key('coach_request_button'),
              onPressed: busy ? null : onRequest,
              child: Text(
                text == null ? 'Chiedi il commento' : 'Chiedine uno nuovo',
              ),
            ),
        ],
      ),
    );
  }
}

/// «2 capoversi», «1 capoverso».
String coachParagraphsLabel(int count) =>
    count == 1 ? '1 capoverso' : '$count capoversi';

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      key: const Key('coach_waiting'),
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Il Mac sta scrivendo il commento. Se è spento non arriverà, e '
            'lo dirò invece di lasciarti qui.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// La frase deterministica in evidenza, con il suo eventuale stato.
class _Headline extends StatelessWidget {
  const _Headline({required this.text, this.status});

  final String text;
  final AppStatusLevel? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status case final status?) ...[
            StatusChip(level: status),
            const SizedBox(height: 8),
          ],
          Text(text, style: theme.textTheme.bodyLarge?.copyWith(height: 1.35)),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ExcludeSemantics(
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Nota in tono minore: quello che manca, quello che è stato tolto.
class _Note extends StatelessWidget {
  const _Note({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppAccents.of(context).mutedInk,
          height: 1.35,
        ),
      ),
    );
  }
}
