import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';
import 'package:kal_tracker/features/wellbeing/domain/wellbeing_models.dart';
import 'package:kal_tracker/features/wellbeing/presentation/wellbeing_providers.dart';

class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});

  static const _waterGoal = 2000;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(nutritionTargetProvider);
    final water = ref.watch(todayWaterProvider);
    final weights = ref.watch(recentWeightsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Progressi'),
            Text(
              'Obiettivi, acqua e peso',
              style: TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('open_sync_button'),
            tooltip: 'Sincronizzazione',
            onPressed: () => context.pushNamed('sync'),
            icon: const Icon(Icons.cloud_sync_rounded),
          ),
          IconButton(
            key: const Key('open_backup_button'),
            tooltip: 'Backup e ripristino',
            onPressed: () => context.pushNamed('backup'),
            icon: const Icon(Icons.save_alt_rounded),
          ),
        ],
      ),
      body: ListView(
        key: const Key('progress_list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          const _ProgressIntro(),
          const SizedBox(height: 18),
          target.when(
            data: (value) => _TargetCard(
              target: value,
              onEdit: () => _editTarget(context, ref, value),
            ),
            loading: () => const _LoadingCard(),
            error: (error, stackTrace) => _ErrorCard(
              label: 'Ricarica obiettivi',
              onRetry: () => ref.invalidate(nutritionTargetProvider),
            ),
          ),
          const SizedBox(height: 14),
          water.when(
            data: (value) => _WaterCard(
              intake: value,
              goal: _waterGoal,
              onAdd250: () => _addWater(context, ref, 250),
              onAdd500: () => _addWater(context, ref, 500),
            ),
            loading: () => const _LoadingCard(),
            error: (error, stackTrace) => _ErrorCard(
              label: 'Ricarica acqua',
              onRetry: () => ref.invalidate(todayWaterProvider),
            ),
          ),
          const SizedBox(height: 14),
          weights.when(
            data: (value) => _WeightCard(
              measurements: value,
              onAdd: () => _addWeight(context, ref),
            ),
            loading: () => const _LoadingCard(),
            error: (error, stackTrace) => _ErrorCard(
              label: 'Ricarica peso',
              onRetry: () => ref.invalidate(recentWeightsProvider),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editTarget(
    BuildContext context,
    WidgetRef ref,
    NutritionTarget current,
  ) async {
    final edited = await showModalBottomSheet<NutritionTarget>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _TargetEditorSheet(initial: current),
    );
    if (edited == null || !context.mounted) {
      return;
    }
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(targetRepositoryProvider)
          .upsertTarget(profileId: profile.id, target: edited);
      if (context.mounted) {
        _message(context, 'Obiettivi aggiornati.');
      }
    } on Object {
      if (context.mounted) {
        _message(context, 'Non riesco a salvare gli obiettivi.');
      }
    }
  }

  Future<void> _addWater(
    BuildContext context,
    WidgetRef ref,
    int milliliters,
  ) async {
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(wellbeingRepositoryProvider)
          .addWater(
            profileId: profile.id,
            milliliters: milliliters,
            loggedAt: AppTime.nowInRome(),
          );
      if (context.mounted) {
        _message(context, '+$milliliters ml: continua così!');
      }
    } on Object {
      if (context.mounted) {
        _message(context, 'Non riesco a registrare l’acqua.');
      }
    }
  }

  Future<void> _addWeight(BuildContext context, WidgetRef ref) async {
    final weight = await showModalBottomSheet<double>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _WeightEditorSheet(),
    );
    if (weight == null || !context.mounted) {
      return;
    }
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(wellbeingRepositoryProvider)
          .addWeight(
            profileId: profile.id,
            weightKg: weight,
            measuredAt: AppTime.nowInRome(),
          );
      if (context.mounted) {
        _message(context, 'Peso registrato.');
      }
    } on Object {
      if (context.mounted) {
        _message(context, 'Non riesco a registrare il peso.');
      }
    }
  }

  void _message(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ProgressIntro extends StatelessWidget {
  const _ProgressIntro();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.lilacSoft,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppPalette.paper,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.emoji_events_rounded,
                color: AppPalette.lilac,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Piccoli passi, ogni giorno',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'I dati restano sul tuo dispositivo e si aggiornano '
                    'subito.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.target, required this.onEdit});

  final NutritionTarget target;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final number = NumberFormat.decimalPattern('it');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _SectionIcon(
                  icon: Icons.flag_rounded,
                  color: AppPalette.coral,
                  background: AppPalette.coralSoft,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Obiettivi giornalieri',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton.filledTonal(
                  key: const Key('edit_targets_button'),
                  tooltip: 'Modifica obiettivi',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _TargetValue(
                    value: number.format(target.calories.round()),
                    label: 'kcal',
                    color: AppPalette.forest,
                  ),
                ),
                Expanded(
                  child: _TargetValue(
                    value: number.format(target.protein.round()),
                    label: 'g proteine',
                    color: AppPalette.coral,
                  ),
                ),
                Expanded(
                  child: _TargetValue(
                    value: number.format(target.carbs.round()),
                    label: 'g carbo',
                    color: AppPalette.yellow,
                  ),
                ),
                Expanded(
                  child: _TargetValue(
                    value: number.format(target.fat.round()),
                    label: 'g grassi',
                    color: AppPalette.lilac,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WaterCard extends StatelessWidget {
  const _WaterCard({
    required this.intake,
    required this.goal,
    required this.onAdd250,
    required this.onAdd500,
  });

  final DailyWaterIntake intake;
  final int goal;
  final VoidCallback onAdd250;
  final VoidCallback onAdd500;

  @override
  Widget build(BuildContext context) {
    final progress = (intake.totalMilliliters / goal).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _SectionIcon(
                  icon: Icons.water_drop_rounded,
                  color: Color(0xFF397CB3),
                  background: Color(0xFFE0F0FC),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Acqua di oggi',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '${intake.totalMilliliters} / $goal ml',
                        key: const Key('water_total'),
                        style: const TextStyle(color: AppPalette.mutedInk),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${(progress * 100).round()}%',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: const Color(0xFF397CB3),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              minHeight: 10,
              borderRadius: BorderRadius.circular(10),
              value: progress,
              backgroundColor: const Color(0xFFE0F0FC),
              color: const Color(0xFF397CB3),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('add_water_250'),
                    onPressed: onAdd250,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('250 ml'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('add_water_500'),
                    onPressed: onAdd500,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('500 ml'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WeightCard extends StatelessWidget {
  const _WeightCard({required this.measurements, required this.onAdd});

  final List<WeightMeasurement> measurements;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const _SectionIcon(
                  icon: Icons.monitor_weight_outlined,
                  color: AppPalette.leaf,
                  background: AppPalette.mintSoft,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Andamento peso',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton.filled(
                  key: const Key('add_weight_button'),
                  tooltip: 'Registra peso',
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (measurements.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Text(
                    'Registra il primo peso per vedere l’andamento.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppPalette.mutedInk),
                  ),
                ),
              )
            else ...[
              Semantics(
                label: 'Grafico delle ultime misurazioni del peso',
                child: ExcludeSemantics(
                  child: SizedBox(
                    key: const Key('weight_chart'),
                    height: 130,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _WeightChartPainter(
                        measurements.reversed.toList(),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              for (final measurement in measurements.take(5))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(
                    Icons.circle,
                    size: 10,
                    color: AppPalette.leaf,
                  ),
                  title: Text(
                    '${measurement.weightKg.toStringAsFixed(1)} kg',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  trailing: Text(
                    DateFormat(
                      'd MMM y',
                      'it',
                    ).format(AppTime.inRome(measurement.measuredAt)),
                    style: const TextStyle(color: AppPalette.mutedInk),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TargetEditorSheet extends StatefulWidget {
  const _TargetEditorSheet({required this.initial});

  final NutritionTarget initial;

  @override
  State<_TargetEditorSheet> createState() => _TargetEditorSheetState();
}

class _TargetEditorSheetState extends State<_TargetEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _calories;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;

  @override
  void initState() {
    super.initState();
    _calories = _controller(widget.initial.calories);
    _protein = _controller(widget.initial.protein);
    _carbs = _controller(widget.initial.carbs);
    _fat = _controller(widget.initial.fat);
  }

  @override
  void dispose() {
    _calories.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'I tuoi obiettivi',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 5),
              const Text('Potrai cambiarli quando vuoi.'),
              const SizedBox(height: 18),
              _DecimalField(
                key: const Key('target_calories_field'),
                controller: _calories,
                label: 'Calorie (kcal)',
                mustBePositive: true,
              ),
              const SizedBox(height: 10),
              _DecimalField(
                key: const Key('target_protein_field'),
                controller: _protein,
                label: 'Proteine (g)',
              ),
              const SizedBox(height: 10),
              _DecimalField(
                key: const Key('target_carbs_field'),
                controller: _carbs,
                label: 'Carboidrati (g)',
              ),
              const SizedBox(height: 10),
              _DecimalField(
                key: const Key('target_fat_field'),
                controller: _fat,
                label: 'Grassi (g)',
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const Key('save_targets_button'),
                onPressed: _save,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Salva obiettivi'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    Navigator.pop(
      context,
      NutritionTarget(
        calories: _parse(_calories.text)!,
        protein: _parse(_protein.text)!,
        carbs: _parse(_carbs.text)!,
        fat: _parse(_fat.text)!,
      ),
    );
  }
}

class _WeightEditorSheet extends StatefulWidget {
  const _WeightEditorSheet();

  @override
  State<_WeightEditorSheet> createState() => _WeightEditorSheetState();
}

class _WeightEditorSheetState extends State<_WeightEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  final _weight = TextEditingController();

  @override
  void dispose() {
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Registra il peso',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 5),
            const Text('Una misurazione alla volta, senza giudizi.'),
            const SizedBox(height: 18),
            _DecimalField(
              key: const Key('weight_field'),
              controller: _weight,
              label: 'Peso (kg)',
              minimum: 20,
              maximum: 500,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('save_weight_button'),
              onPressed: () {
                if (_formKey.currentState!.validate()) {
                  Navigator.pop(context, _parse(_weight.text));
                }
              },
              icon: const Icon(Icons.check_rounded),
              label: const Text('Registra'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecimalField extends StatelessWidget {
  const _DecimalField({
    required this.controller,
    required this.label,
    this.mustBePositive = false,
    this.minimum,
    this.maximum,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool mustBePositive;
  final double? minimum;
  final double? maximum;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        final parsed = _parse(value ?? '');
        if (parsed == null) {
          return 'Valore non valido';
        }
        if (mustBePositive && parsed <= 0) {
          return 'Deve essere maggiore di zero';
        }
        if (!mustBePositive && parsed < 0) {
          return 'Non può essere negativo';
        }
        if (minimum != null && parsed < minimum!) {
          return 'Minimo ${minimum!.round()}';
        }
        if (maximum != null && parsed > maximum!) {
          return 'Massimo ${maximum!.round()}';
        }
        return null;
      },
    );
  }
}

class _TargetValue extends StatelessWidget {
  const _TargetValue({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        FittedBox(child: Text(label, style: const TextStyle(fontSize: 11))),
      ],
    );
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({
    required this.icon,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.label, required this.onRetry});

  final String label;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: FilledButton.tonalIcon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(label),
        ),
      ),
    );
  }
}

class _WeightChartPainter extends CustomPainter {
  _WeightChartPainter(this.measurements);

  final List<WeightMeasurement> measurements;

  @override
  void paint(Canvas canvas, Size size) {
    const padding = 10.0;
    final chart = Rect.fromLTWH(
      padding,
      padding,
      math.max(0, size.width - padding * 2),
      math.max(0, size.height - padding * 2),
    );
    final gridPaint = Paint()
      ..color = AppPalette.outline
      ..strokeWidth = 1;
    for (var index = 0; index < 4; index++) {
      final y = chart.top + chart.height * index / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }

    final values = measurements.map((item) => item.weightKg).toList();
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final range = math.max(1.0, maximum - minimum);
    final points = <Offset>[
      for (final (index, value) in values.indexed)
        Offset(
          values.length == 1
              ? chart.center.dx
              : chart.left + chart.width * index / (values.length - 1),
          chart.bottom - chart.height * (value - minimum) / range,
        ),
    ];

    if (points.length > 1) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = AppPalette.leaf
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }
    final pointPaint = Paint()..color = AppPalette.forest;
    for (final point in points) {
      canvas.drawCircle(point, 5, pointPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WeightChartPainter oldDelegate) =>
      oldDelegate.measurements != measurements;
}

TextEditingController _controller(double value) => TextEditingController(
  text: value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1),
);

double? _parse(String value) {
  final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
  return parsed != null && parsed.isFinite ? parsed : null;
}
