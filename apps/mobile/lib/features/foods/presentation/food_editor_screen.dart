import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';

class FoodEditorScreen extends ConsumerStatefulWidget {
  const FoodEditorScreen({this.foodId, super.key});

  final String? foodId;

  @override
  ConsumerState<FoodEditorScreen> createState() => _FoodEditorScreenState();
}

class _FoodEditorScreenState extends ConsumerState<FoodEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _barcode = TextEditingController();
  final _calories = TextEditingController();
  final _protein = TextEditingController();
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  final _serving = TextEditingController(text: '100');
  bool _loading = false;
  bool _saving = false;
  bool _isSeed = false;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    if (widget.foodId case final foodId?) {
      _loading = true;
      _load(foodId);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _barcode.dispose();
    _calories.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _serving.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.foodId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Modifica alimento' : 'Nuovo alimento'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_missing) {
      return const _MissingFood();
    }
    return _buildForm(context);
  }

  Widget _buildForm(BuildContext context) {
    final per100g = _readPer100g();
    final serving = _parseDecimal(_serving.text);
    final preview = per100g != null && serving != null && serving > 0
        ? NutritionCalculator.scale(per100g: per100g, grams: serving)
        : null;
    final warning = per100g == null
        ? null
        : AtwaterCalculator.check(per100g).warning;

    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: SingleChildScrollView(
        key: const Key('food_editor_list'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isSeed) ...[const _SeedNotice(), const SizedBox(height: 16)],
            Text("L'alimento", style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('food_editor_name_field'),
              controller: _name,
              enabled: !_saving,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Nome'),
              validator: (value) {
                final clean = value?.trim() ?? '';
                if (clean.isEmpty) {
                  return 'Inserisci il nome';
                }
                if (clean.length > 160) {
                  return 'Massimo 160 caratteri';
                }
                return null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('food_editor_brand_field'),
              controller: _brand,
              enabled: !_saving,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Marca (facoltativa)',
              ),
              validator: (value) => (value?.trim().length ?? 0) > 120
                  ? 'Massimo 120 caratteri'
                  : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('food_editor_barcode_field'),
              controller: _barcode,
              enabled: !_saving,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Codice a barre (facoltativo)',
              ),
              validator: (value) =>
                  (value?.trim().length ?? 0) > 32 ? 'Massimo 32 cifre' : null,
            ),
            const SizedBox(height: 20),
            Text(
              'Valori per 100 g',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            _DecimalField(
              key: const Key('food_editor_calories_field'),
              controller: _calories,
              label: 'Calorie (kcal)',
              enabled: !_saving,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _DecimalField(
                    key: const Key('food_editor_protein_field'),
                    controller: _protein,
                    label: 'Proteine (g)',
                    enabled: !_saving,
                    onChanged: () => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DecimalField(
                    key: const Key('food_editor_carbs_field'),
                    controller: _carbs,
                    label: 'Carboidrati (g)',
                    enabled: !_saving,
                    onChanged: () => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _DecimalField(
                    key: const Key('food_editor_fat_field'),
                    controller: _fat,
                    label: 'Grassi (g)',
                    enabled: !_saving,
                    onChanged: () => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DecimalField(
                    key: const Key('food_editor_serving_field'),
                    controller: _serving,
                    label: 'Porzione abituale (g)',
                    enabled: !_saving,
                    mustBePositive: true,
                    onChanged: () => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _ServingPreview(grams: serving, nutrients: preview),
            if (warning != null) ...[
              const SizedBox(height: 12),
              _AtwaterWarning(message: warning),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('save_food_editor_button'),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(_saving ? 'Salvataggio…' : 'Salva nel catalogo'),
            ),
          ],
        ),
      ),
    );
  }

  Nutrients? _readPer100g() {
    final calories = _parseDecimal(_calories.text);
    final protein = _parseDecimal(_protein.text);
    final carbs = _parseDecimal(_carbs.text);
    final fat = _parseDecimal(_fat.text);
    if (calories == null || protein == null || carbs == null || fat == null) {
      return null;
    }
    final nutrients = Nutrients(
      calories: calories,
      protein: protein,
      carbs: carbs,
      fat: fat,
    );
    return nutrients.isValid ? nutrients : null;
  }

  Future<void> _load(String foodId) async {
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final food = await ref
          .read(foodCatalogRepositoryProvider)
          .getFood(profileId: profile.id, foodId: foodId);
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _missing = food == null;
        if (food != null) {
          _isSeed = food.isSeed;
          _name.text = food.name;
          _brand.text = food.brand ?? '';
          _barcode.text = food.barcode ?? '';
          _calories.text = _editableNumber(food.per100g.calories);
          _protein.text = _editableNumber(food.per100g.protein);
          _carbs.text = _editableNumber(food.per100g.carbs);
          _fat.text = _editableNumber(food.per100g.fat);
          _serving.text = _editableNumber(food.defaultServingGrams);
        }
      });
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _missing = true;
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final per100g = _readPer100g();
    final serving = _parseDecimal(_serving.text);
    if (per100g == null || serving == null) {
      return;
    }

    setState(() => _saving = true);
    final draft = FoodDraft(
      name: _name.text,
      brand: _brand.text,
      barcode: _barcode.text,
      per100g: per100g,
      defaultServingGrams: serving,
    );
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final repository = ref.read(foodCatalogRepositoryProvider);
      final foodId = widget.foodId;
      final savedId = foodId == null
          ? await repository.createFood(profileId: profile.id, draft: draft)
          : await repository.updateFood(
              profileId: profile.id,
              foodId: foodId,
              draft: draft,
            );
      if (mounted) {
        context.pop(savedId);
      }
    } on FoodCatalogException catch (error) {
      _failWith(error.message);
    } on FormatException catch (error) {
      _failWith(error.message);
    } on Object {
      _failWith('Non riesco a salvare questo alimento.');
    }
  }

  void _failWith(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SeedNotice extends StatelessWidget {
  const _SeedNotice();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('food_editor_seed_notice'),
      color: AppPalette.mintSoft,
      child: const Padding(
        padding: EdgeInsets.all(17),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: AppPalette.leaf, size: 30),
            SizedBox(width: 13),
            Expanded(
              child: Text(
                'Questo è un alimento di base: salvando crei la tua copia '
                'personale e l’originale resta com’è.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServingPreview extends StatelessWidget {
  const _ServingPreview({required this.grams, required this.nutrients});

  final double? grams;
  final Nutrients? nutrients;

  @override
  Widget build(BuildContext context) {
    final value = nutrients;
    return Card(
      key: const Key('food_editor_preview'),
      color: AppPalette.lilacSoft,
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calculate_rounded, color: AppPalette.lilac),
                const SizedBox(width: 9),
                Text(
                  'Anteprima porzione',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (value == null || grams == null)
              const Text(
                'Completa i valori per 100 g e la porzione.',
                style: TextStyle(color: AppPalette.mutedInk),
              )
            else ...[
              Text(
                'Una porzione da ${_editableNumber(grams!)} g contiene '
                '${value.calories.round()} kcal',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'P ${value.protein.toStringAsFixed(1)} g  ·  '
                'C ${value.carbs.toStringAsFixed(1)} g  ·  '
                'G ${value.fat.toStringAsFixed(1)} g',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AtwaterWarning extends StatelessWidget {
  const _AtwaterWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('food_editor_atwater_warning'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.yellowSoft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppPalette.yellow),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: AppPalette.yellow),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _MissingFood extends StatelessWidget {
  const _MissingFood();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Questo alimento non è più nel catalogo.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _DecimalField extends StatelessWidget {
  const _DecimalField({
    required super.key,
    required this.controller,
    required this.label,
    required this.enabled,
    required this.onChanged,
    this.mustBePositive = false,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback onChanged;
  final bool mustBePositive;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => onChanged(),
      validator: (value) {
        final number = _parseDecimal(value ?? '');
        if (number == null) {
          return 'Valore non valido';
        }
        if (mustBePositive ? number <= 0 : number < 0) {
          return mustBePositive ? 'Deve essere > 0' : 'Non può essere negativo';
        }
        return null;
      },
    );
  }
}

double? _parseDecimal(String value) {
  final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
  return parsed != null && parsed.isFinite ? parsed : null;
}

String _editableNumber(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
