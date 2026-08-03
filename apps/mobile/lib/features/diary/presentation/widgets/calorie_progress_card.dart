import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';

abstract final class DiaryPresentationDefaults {
  /// Mirrors the standard app target for isolated widget use.
  static const double dailyCalorieTarget = 2000;
}

class CalorieProgressCard extends StatelessWidget {
  const CalorieProgressCard({
    required this.nutrients,
    this.targetCalories = DiaryPresentationDefaults.dailyCalorieTarget,
    super.key,
  });

  final Nutrients nutrients;
  final double targetCalories;

  @override
  Widget build(BuildContext context) {
    final consumed = nutrients.calories;
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
          const Positioned(
            right: -28,
            top: -35,
            child: _DecorativeBubble(size: 104, color: AppPalette.yellowSoft),
          ),
          const Positioned(
            right: 45,
            top: 24,
            child: _DecorativeBubble(size: 18, color: AppPalette.lilacSoft),
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
                Row(
                  children: [
                    Expanded(
                      child: _MacroPill(
                        label: 'Proteine',
                        value: nutrients.protein,
                        color: AppPalette.coral,
                        background: AppPalette.coralSoft,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroPill(
                        label: 'Carbo',
                        value: nutrients.carbs,
                        color: AppPalette.yellow,
                        background: AppPalette.yellowSoft,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroPill(
                        label: 'Grassi',
                        value: nutrients.fat,
                        color: AppPalette.lilac,
                        background: AppPalette.lilacSoft,
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
              progressColor: overTarget ? AppPalette.coral : AppPalette.forest,
            ),
            child: child,
          );
        },
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.restaurant_rounded,
                size: 18,
                color: AppPalette.leaf,
              ),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${calories.round()} kcal',
                    key: const Key('daily_calories'),
                    maxLines: 1,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AppPalette.forestDark,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
              Text(
                'su ${NumberFormat.decimalPattern('it').format(target.round())}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
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
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatter.format(value.round()),
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: overTarget ? AppPalette.coral : AppPalette.forestDark,
                ),
              ),
            ),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 9),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.forest,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MacroPill extends StatelessWidget {
  const _MacroPill({
    required this.label,
    required this.value,
    required this.color,
    required this.background,
  });

  final String label;
  final double value;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label, ${value.toStringAsFixed(1)} grammi',
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
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppPalette.mutedInk,
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
                    '${value.toStringAsFixed(1)} g',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: AppPalette.ink,
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
  });

  final double progress;
  final Color progressColor;

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
        ..color = AppPalette.mint
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
      canvas.drawCircle(markerCenter, 4, Paint()..color = AppPalette.coral);
    }

    // Three small “ingredients” keep the ring food-oriented and distinct from
    // the fitness activity ring used by the companion app.
    _drawIngredientDot(canvas, center, radius + 7, -0.12, AppPalette.yellow);
    _drawIngredientDot(canvas, center, radius + 7, 2.22, AppPalette.lilac);
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
        oldDelegate.progressColor != progressColor;
  }
}
