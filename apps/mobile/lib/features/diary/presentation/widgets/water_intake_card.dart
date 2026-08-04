import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';
import 'package:kal_tracker/features/wellbeing/domain/wellbeing_models.dart';
import 'package:kal_tracker/features/wellbeing/presentation/water_day_sheet.dart';
import 'package:kal_tracker/features/wellbeing/presentation/water_palette.dart';
import 'package:kal_tracker/features/wellbeing/presentation/wellbeing_providers.dart';
import 'package:kal_tracker/core/presentation/snackbars.dart';

/// L'acqua del giorno, in evidenza nel diario: bicchiere che si riempie,
/// pulsanti rapidi con annulla, e tap sul widget per storico, obiettivo
/// e promemoria. La persistenza è quella di sempre (WaterLogs + outbox).
class WaterIntakeCard extends ConsumerWidget {
  const WaterIntakeCard({
    required this.day,
    required this.today,
    required this.dayLabel,
    super.key,
  });

  final DateTime day;
  final DateTime today;
  final String dayLabel;

  static const quickAmounts = [200, 330, 500];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final intake = ref
        .watch(selectedDayWaterProvider)
        .maybeWhen(
          data: (value) => value,
          orElse: () => const DailyWaterIntake.empty(),
        );
    final settings = ref
        .watch(waterSettingsProvider)
        .maybeWhen(data: (value) => value, orElse: () => const WaterSettings());
    final goal = settings.goalMilliliters;
    final progress = goal <= 0
        ? 0.0
        : (intake.totalMilliliters / goal).clamp(0.0, 1.0).toDouble();

    return Card(
      key: const Key('water_card'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('water_card_tap'),
        onTap: () => _openSheet(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Semantics(
                    label:
                        'Acqua: ${intake.totalMilliliters} di $goal millilitri',
                    child: ExcludeSemantics(child: _WaterGlass(progress)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Acqua',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: WaterPalette.soft,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                child: Text(
                                  '${(progress * 100).round()}%',
                                  key: const Key('water_percent'),
                                  style: const TextStyle(
                                    color: WaterPalette.deep,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${intake.totalMilliliters} / $goal ml',
                          key: const Key('water_daily_total'),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: WaterPalette.deep,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _messageFor(intake.totalMilliliters, goal),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppPalette.mutedInk),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final amount in quickAmounts) ...[
                    Expanded(
                      child: OutlinedButton(
                        key: Key('water_add_$amount'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WaterPalette.deep,
                          side: const BorderSide(
                            color: WaterPalette.soft,
                            width: 1.4,
                          ),
                        ),
                        onPressed: () => _addWater(context, ref, amount),
                        child: Text('+$amount ml'),
                      ),
                    ),
                    if (amount != quickAmounts.last) const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _messageFor(int total, int goal) {
    if (total <= 0) {
      return 'Si parte dal primo sorso: tocca un pulsante.';
    }
    if (total >= goal) {
      return 'Obiettivo raggiunto: oggi ti sei voluto bene.';
    }
    if (total >= goal * 0.7) {
      return 'Ci sei quasi: mancano ${goal - total} ml.';
    }
    return 'Buon ritmo, continua così.';
  }

  Future<void> _openSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => WaterDaySheet(dayLabel: dayLabel),
    );
  }

  Future<void> _addWater(
    BuildContext context,
    WidgetRef ref,
    int milliliters,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(wellbeingRepositoryProvider);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      // Come il resto del diario: il bicchiere finisce nel giorno scelto.
      final loggedAt = DiaryDay.isSameDay(day, today)
          ? AppTime.nowInRome()
          : DiaryDay.instantFor(day);
      final id = await repository.addWater(
        profileId: profile.id,
        milliliters: milliliters,
        loggedAt: loggedAt,
      );
      // Tap veloci in fila: ogni feedback sostituisce il precedente,
      // così «Annulla» toglie sempre l'ultimo bicchiere.
      messenger.removeCurrentSnackBar();
      showAutoClosingSnackBar(
        messenger,
        SnackBar(
          content: Text('+$milliliters ml: continua così!'),
          action: SnackBarAction(
            label: 'Annulla',
            onPressed: () => _undoWater(messenger, ref, id),
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a registrare l’acqua.')),
      );
    }
  }

  Future<void> _undoWater(
    ScaffoldMessengerState messenger,
    WidgetRef ref,
    String id,
  ) async {
    try {
      await ref.read(wellbeingRepositoryProvider).deleteWater(id);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco ad annullare l’aggiunta.')),
      );
    }
  }
}

/// Il bicchiere che si riempie: onda morbida, bollicine, animazione
/// dolce quando cambia il progresso. Niente animazioni infinite, così
/// pumpAndSettle nei test resta felice.
class _WaterGlass extends StatelessWidget {
  const _WaterGlass(this.progress);

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      height: 72,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: progress.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
        builder: (context, animated, _) =>
            CustomPaint(painter: _WaterGlassPainter(animated)),
      ),
    );
  }
}

class _WaterGlassPainter extends CustomPainter {
  const _WaterGlassPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final glass = _glassPath(size);

    // Interno del bicchiere.
    canvas.drawPath(glass, Paint()..color = WaterPalette.mist);

    // Acqua con onda sul pelo, ritagliata dentro il bicchiere.
    if (progress > 0) {
      canvas.save();
      canvas.clipPath(glass);

      final top = size.height * (1 - 0.92 * progress);
      final wave = Path()..moveTo(-4, top);
      const amplitude = 2.6;
      final phase = progress * math.pi * 2;
      for (double x = -4; x <= size.width + 4; x += 2) {
        wave.lineTo(x, top + math.sin(x / 9 + phase) * amplitude);
      }
      wave
        ..lineTo(size.width + 4, size.height + 4)
        ..lineTo(-4, size.height + 4)
        ..close();
      canvas.drawPath(wave, Paint()..color = WaterPalette.deep);

      // Cresta più chiara sul pelo dell'acqua.
      final crest = Path()..moveTo(-4, top);
      for (double x = -4; x <= size.width + 4; x += 2) {
        crest.lineTo(x, top + math.sin(x / 9 + phase) * amplitude);
      }
      canvas.drawPath(
        crest,
        Paint()
          ..color = WaterPalette.crest
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );

      // Bollicine: compaiono via via che il livello sale.
      final bubbles = Paint()
        ..color = WaterPalette.crest.withValues(alpha: 0.8);
      for (final (dx, level, radius) in const [
        (0.34, 0.28, 2.2),
        (0.62, 0.52, 1.7),
        (0.48, 0.74, 2.6),
      ]) {
        final bubbleY = size.height - (size.height - top) * level - 4;
        if (bubbleY > top + 6) {
          canvas.drawCircle(Offset(size.width * dx, bubbleY), radius, bubbles);
        }
      }
      canvas.restore();
    }

    // Contorno del bicchiere sopra tutto.
    canvas.drawPath(
      glass,
      Paint()
        ..color = WaterPalette.deep
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round,
    );
  }

  /// Bicchiere leggermente svasato con base arrotondata.
  Path _glassPath(Size size) {
    final width = size.width;
    final height = size.height;
    const taper = 7.0;
    return Path()
      ..moveTo(2, 2)
      ..lineTo(width - 2, 2)
      ..lineTo(width - 2 - taper, height - 8)
      ..quadraticBezierTo(
        width - 2 - taper,
        height - 2,
        width - 8 - taper,
        height - 2,
      )
      ..lineTo(8 + taper, height - 2)
      ..quadraticBezierTo(2 + taper, height - 2, 2 + taper, height - 8)
      ..close();
  }

  @override
  bool shouldRepaint(_WaterGlassPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
