import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';

/// Quanto resta oggi: calorie nell'anello, proteine in evidenza.
///
/// Le proteine hanno una riga tutta loro e non una pastiglia come le altre
/// due, perché non sono un macro fra tre: sono il vincolo che protegge la
/// massa magra durante il deficit. Un traguardo di peso raggiunto perdendo
/// muscolo è un fallimento travestito da successo.
///
/// Carboidrati e grassi restano, in piccolo: servono a spiegare il margine,
/// non a essere centrati.
class CalorieProgressCard extends StatelessWidget {
  const CalorieProgressCard({
    required this.nutrients,
    this.target = const NutritionTarget.standard(),
    super.key,
  });

  /// Quello che è già entrato oggi.
  final Nutrients nutrients;

  /// Il riferimento del giorno. Senza obiettivo impostato è quello standard:
  /// la schermata non resta mai senza un metro, e nessun numero qui dentro
  /// viene inventato.
  final NutritionTarget target;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    final consumed = nutrients.calories;
    final targetCalories = target.calories;
    final remaining = math.max(0.0, targetCalories - consumed);
    final overTarget = consumed > targetCalories;
    final progress = targetCalories <= 0
        ? 0.0
        : (consumed / targetCalories).clamp(0.0, 1.0);
    final formatter = NumberFormat.decimalPattern('it');

    return Card(
      key: const Key('calorie_progress_card'),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -28,
            top: -35,
            child: _DecorativeBubble(size: 104, color: accents.warningSurface),
          ),
          Positioned(
            right: 45,
            top: 24,
            child: _DecorativeBubble(size: 18, color: accents.infoSurface),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Semantics(
                      label: 'Calorie giornaliere',
                      value:
                          '${consumed.round()} di ${targetCalories.round()} '
                          'chilocalorie',
                      child: ExcludeSemantics(
                        child: _CalorieRing(
                          calories: consumed,
                          target: targetCalories,
                          progress: progress,
                          overTarget: overTarget,
                        ),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: _RemainingCalories(
                        formatter: formatter,
                        remaining: remaining,
                        overBy: math.max(0.0, consumed - targetCalories),
                        overTarget: overTarget,
                        consumed: consumed,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 14),
                _ProteinFocus(eaten: nutrients.protein, target: target.protein),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _MacroPill(
                        label: 'Carbo',
                        eaten: nutrients.carbs,
                        target: target.carbs,
                        color: accents.warning,
                        background: accents.warningSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroPill(
                        label: 'Grassi',
                        eaten: nutrients.fat,
                        target: target.fat,
                        color: accents.info,
                        background: accents.infoSurface,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CalorieRing extends StatelessWidget {
  const _CalorieRing({
    required this.calories,
    required this.target,
    required this.progress,
    required this.overTarget,
  });

  final double calories;
  final double target;
  final double progress;
  final bool overTarget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final scheme = theme.colorScheme;

    return SizedBox.square(
      dimension: 142,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: progress),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
        builder: (context, animatedProgress, child) {
          return CustomPaint(
            painter: _CalorieRingPainter(
              progress: animatedProgress,
              // Oltre il riferimento l'anello cambia tinta, non tono di voce:
              // è un'informazione, non un rimprovero.
              progressColor: overTarget ? scheme.secondary : scheme.primary,
              trackColor: scheme.primaryContainer,
              markerColor: scheme.secondary,
              warmDotColor: accents.warning,
              coolDotColor: accents.info,
            ),
            child: child,
          );
        },
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.restaurant_rounded, size: 18, color: scheme.primary),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${calories.round()} kcal',
                    key: const Key('daily_calories'),
                    maxLines: 1,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
              Text(
                'su ${NumberFormat.decimalPattern('it').format(target.round())}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemainingCalories extends StatelessWidget {
  const _RemainingCalories({
    required this.formatter,
    required this.remaining,
    required this.overBy,
    required this.overTarget,
    required this.consumed,
  });

  final NumberFormat formatter;
  final double remaining;
  final double overBy;
  final bool overTarget;
  final double consumed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final scheme = theme.colorScheme;
    final value = overTarget ? overBy : remaining;
    final label = overTarget ? 'kcal oltre il riferimento' : 'kcal disponibili';
    final message = switch ((consumed, overTarget)) {
      (0, _) => 'Pronto per iniziare?',
      (_, true) => 'Nessun giudizio: conta l’equilibrio.',
      _ => 'Stai costruendo il tuo equilibrio.',
    };

    return Semantics(
      label: '${formatter.format(value.round())} $label. $message',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              overTarget ? 'Oggi sei a' : 'Ti restano',
              style: theme.textTheme.labelLarge?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatter.format(value.round()),
                key: const Key('remaining_calories'),
                style: theme.textTheme.headlineLarge?.copyWith(
                  color: overTarget ? scheme.secondary : scheme.onSurface,
                ),
              ),
            ),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 9),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le proteine rimaste, grandi quanto contano.
class _ProteinFocus extends StatelessWidget {
  const _ProteinFocus({required this.eaten, required this.target});

  final double eaten;
  final double target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final scheme = theme.colorScheme;
    final remaining = math.max(0.0, target - eaten);
    final covered = target <= 0 ? 1.0 : (eaten / target).clamp(0.0, 1.0);
    final done = remaining <= 0;
    // A caratteri molto ingranditi etichetta e valore non ci stanno più
    // sulla stessa riga: sopra 1,3× si impilano, come fa `StatRow`. Meglio
    // due righe che un troncamento sul numero che conta.
    final stacked = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.3;

    final label = Text(
      'Proteine',
      style: theme.textTheme.labelLarge?.copyWith(color: accents.mutedInk),
    );
    final value = Text(
      done ? 'coperte' : '${remaining.round()} g ancora',
      key: const Key('remaining_protein'),
      style: theme.textTheme.titleLarge?.copyWith(
        color: done ? accents.positive : scheme.onSurface,
        fontWeight: FontWeight.w900,
      ),
    );

    return Semantics(
      container: true,
      label: 'Proteine',
      value: done
          ? 'obiettivo coperto, ${eaten.round()} grammi su ${target.round()}'
          : 'restano ${remaining.round()} grammi su ${target.round()}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stacked) ...[
              label,
              const SizedBox(height: 2),
              value,
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 10),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: value,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            // La barra è larga quanto la card: è la card che deve stare in
            // una colonna leggibile, non la barra a difendersi da sola. La
            // chiave serve al test che lo verifica sul tablet.
            _ProgressBar(
              key: const Key('protein_progress_bar'),
              value: covered,
            ),
            const SizedBox(height: 6),
            Text(
              '${eaten.round()} g su ${target.round()} — è il macro che '
              'protegge il muscolo.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, super.key});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 9,
        child: LinearProgressIndicator(
          value: value,
          backgroundColor: scheme.primaryContainer,
          valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
        ),
      ),
    );
  }
}

class _MacroPill extends StatelessWidget {
  const _MacroPill({
    required this.label,
    required this.eaten,
    required this.target,
    required this.color,
    required this.background,
  });

  final String label;
  final double eaten;
  final double target;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final remaining = math.max(0.0, target - eaten);

    return Semantics(
      label: '$label, restano ${remaining.round()} grammi',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accents.mutedInk,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${remaining.round()} g ancora',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DecorativeBubble extends StatelessWidget {
  const _DecorativeBubble({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

class _CalorieRingPainter extends CustomPainter {
  const _CalorieRingPainter({
    required this.progress,
    required this.progressColor,
    required this.trackColor,
    required this.markerColor,
    required this.warmDotColor,
    required this.coolDotColor,
  });

  final double progress;
  final Color progressColor;
  final Color trackColor;
  final Color markerColor;
  final Color warmDotColor;
  final Color coolDotColor;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 11.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    const startAngle = -math.pi / 2;

    canvas.drawArc(
      bounds,
      startAngle,
      math.pi * 2,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    if (progress > 0) {
      final sweep = math.pi * 2 * progress;
      canvas.drawArc(
        bounds,
        startAngle,
        sweep,
        false,
        Paint()
          ..color = progressColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );

      final markerAngle = startAngle + sweep;
      final markerCenter = Offset(
        center.dx + math.cos(markerAngle) * radius,
        center.dy + math.sin(markerAngle) * radius,
      );
      canvas.drawCircle(markerCenter, 4, Paint()..color = markerColor);
    }

    // Three small “ingredients” keep the ring food-oriented and distinct from
    // the fitness activity ring used by the companion app.
    _drawIngredientDot(canvas, center, radius + 7, -0.12, warmDotColor);
    _drawIngredientDot(canvas, center, radius + 7, 2.22, coolDotColor);
  }

  void _drawIngredientDot(
    Canvas canvas,
    Offset center,
    double radius,
    double angle,
    Color color,
  ) {
    canvas.drawCircle(
      Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      ),
      3,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_CalorieRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.markerColor != markerColor;
  }
}
