import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/diary_number_field.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';
import 'package:kal_tracker/features/quick_add/barcode_lookup_repository.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

/// Firma della vista scanner: nei widget test si overrida con un finto
/// widget che emette i codici, senza mai istanziare il plugin reale
/// (i platform channel non esistono nei test).
typedef BarcodeScannerViewBuilder =
    Widget Function(BuildContext context, ValueChanged<String> onBarcode);

final barcodeScannerViewBuilderProvider = Provider<BarcodeScannerViewBuilder>(
  (ref) =>
      (context, onBarcode) => _MobileScannerView(onBarcode: onBarcode),
);

/// Scansione del codice a barre: prima il catalogo locale, poi Open Food
/// Facts; il prodotto confermato diventa un alimento locale con barcode,
/// così la volta dopo funziona tutto offline. Raggiungibile anche come
/// rotta ('barcode-scan').
class BarcodeScanScreen extends ConsumerStatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  ConsumerState<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends ConsumerState<BarcodeScanScreen> {
  /// Lo scanner emette in continuazione: questo guard copre l'INTERO
  /// flusso (ricerca + sheet) per non impilare sheet doppi.
  bool _handling = false;

  /// Lo spinner invece gira solo durante la ricerca: mentre gli sheet
  /// sono aperti non deve restare nessuna animazione infinita.
  bool _searching = false;

  @override
  Widget build(BuildContext context) {
    final buildScanner = ref.watch(barcodeScannerViewBuilderProvider);
    return Scaffold(
      key: const Key('barcode_scan_screen'),
      appBar: AppBar(title: const Text('Scansiona il codice')),
      body: Column(
        children: [
          // Il mirino resta a tutto schermo anche sul tablet: qui più pixel
          // significano un codice a barre più grande e più facile da
          // agganciare, quindi limitarne la larghezza sarebbe un danno.
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(26),
              ),
              child: buildScanner(context, _onBarcode),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              // La didascalia invece è testo: si ferma alla colonna
              // leggibile e si centra sotto il mirino.
              child: AdaptiveContent(
                child: _searching
                    ? Row(
                        key: const Key('barcode_lookup_progress'),
                        children: [
                          const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Cerco il prodotto…',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: AppPalette.mutedInk),
                          ),
                        ],
                      )
                    : Text(
                        key: const Key('barcode_scan_hint'),
                        'Inquadra il codice a barre: guardo prima nel tuo '
                        'catalogo, poi su Open Food Facts.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppPalette.mutedInk,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onBarcode(String barcode) async {
    if (_handling || !mounted) {
      return;
    }
    _handling = true;
    setState(() => _searching = true);
    final messenger = ScaffoldMessenger.of(context);
    BarcodeLookupResult? result;
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      result = await ref
          .read(barcodeLookupRepositoryProvider)
          .lookup(profileId: profile.id, barcode: barcode);
    } on FormatException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Non riesco a leggere questo codice: riprova.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
    if (result == null || !mounted) {
      _handling = false;
      return;
    }
    try {
      switch (result) {
        case BarcodeFoodMatch(:final food):
          await _addFoodToDiary(food);
        case BarcodeProductProposal(:final product):
          await _confirmAndSave(product: product, message: null);
        case BarcodeUnknownProduct(:final barcode):
          await _confirmAndSave(
            product: OpenFoodFactsProduct(barcode: barcode),
            message:
                'Open Food Facts non conosce questo codice: dimmi tu i '
                'valori dall’etichetta e me li ricordo per la prossima volta.',
          );
        case BarcodeLookupOffline(:final barcode):
          await _confirmAndSave(
            product: OpenFoodFactsProduct(barcode: barcode),
            message:
                'Ora sei offline: inserisci i valori dall’etichetta e al '
                'prossimo scan farò tutto da solo.',
          );
      }
    } finally {
      _handling = false;
    }
  }

  Future<void> _confirmAndSave({
    required OpenFoodFactsProduct product,
    required String? message,
  }) async {
    final food = await showModalBottomSheet<FoodCatalogItem>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          BarcodeFoodSheet(product: product, message: message),
    );
    if (food == null || !mounted) {
      return;
    }
    await _addFoodToDiary(food);
  }

  /// Inserimento nel diario precompilato: il pasto lo sceglie Marco nel
  /// dropdown del sheet, il giorno è quello selezionato nel diario.
  Future<void> _addFoodToDiary(FoodCatalogItem food) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => AddManualFoodSheet(
        initialFoodName: food.name,
        initialGrams: food.defaultServingGrams,
        initialPer100g: food.per100g,
      ),
    );
    if (added != true || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final dayLabel = diaryDayLabel(
      ref.read(selectedDayProvider),
      ref.read(todayProvider),
    ).toLowerCase();
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(foodCatalogRepositoryProvider)
          .markUsed(profileId: profile.id, foodId: food.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text('${food.name} aggiunto al diario di $dayLabel.'),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${food.name} è nel diario, ma non nei recenti.'),
        ),
      );
    }
    if (mounted && context.canPop()) {
      context.pop();
    }
  }
}

/// Scheda di conferma del prodotto scansionato: valori modificabili e
/// porzione. Serve anche da editor «gentile» quando OFF non conosce il
/// codice o si è offline. Ritorna il [FoodCatalogItem] appena salvato.
///
/// È un modulo, ma non gli serve [AdaptiveContent]: vive in un foglio modale,
/// e i fogli di Material 3 si fermano da soli a 640 dp anche sul tablet.
class BarcodeFoodSheet extends ConsumerStatefulWidget {
  const BarcodeFoodSheet({required this.product, this.message, super.key});

  final OpenFoodFactsProduct product;
  final String? message;

  @override
  ConsumerState<BarcodeFoodSheet> createState() => _BarcodeFoodSheetState();
}

class _BarcodeFoodSheetState extends ConsumerState<BarcodeFoodSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _brand;
  late final TextEditingController _calories;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _serving;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    _name = TextEditingController(text: product.name ?? '');
    _brand = TextEditingController(text: product.brand ?? '');
    _calories = TextEditingController(text: _editable(product.caloriesPer100g));
    _protein = TextEditingController(text: _editable(product.proteinPer100g));
    _carbs = TextEditingController(text: _editable(product.carbsPer100g));
    _fat = TextEditingController(text: _editable(product.fatPer100g));
    _serving = TextEditingController(text: '100');
  }

  static String _editable(double? value) =>
      value == null ? '' : editableDiaryNumber(value);

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _calories.dispose();
    _protein.dispose();
    _carbs.dispose();
    _fat.dispose();
    _serving.dispose();
    super.dispose();
  }

  Nutrients? _per100g() {
    final calories = parseDiaryNumber(_calories.text);
    final protein = parseDiaryNumber(_protein.text);
    final carbs = parseDiaryNumber(_carbs.text);
    final fat = parseDiaryNumber(_fat.text);
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

  @override
  Widget build(BuildContext context) {
    // I per-100 g di OFF sono spesso sporchi: il controllo Atwater segnala
    // le calorie che non tornano coi macro, ma non blocca il salvataggio.
    final per100g = _per100g();
    final warning = per100g == null
        ? null
        : AtwaterCalculator.check(per100g).warning;

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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.product.name == null
                          ? 'Nuovo prodotto'
                          : 'Confermi i valori?',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Chiudi',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              if (widget.message case final message?) ...[
                Container(
                  key: const Key('barcode_lookup_message'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppPalette.mintSoft,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.emoji_objects_outlined,
                        color: AppPalette.leaf,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(message)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  const Icon(
                    Icons.qr_code_rounded,
                    size: 18,
                    color: AppPalette.mutedInk,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Codice ${widget.product.barcode}',
                    key: const Key('barcode_value_label'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppPalette.mutedInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('barcode_food_name_field'),
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
                  return clean.length > 160 ? 'Massimo 160 caratteri' : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('barcode_food_brand_field'),
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
              const SizedBox(height: 12),
              DiaryNumberField(
                key: const Key('barcode_food_calories_field'),
                controller: _calories,
                label: 'Calorie per 100 g (kcal)',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('barcode_food_protein_field'),
                      controller: _protein,
                      label: 'Proteine per 100 g',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('barcode_food_carbs_field'),
                      controller: _carbs,
                      label: 'Carboidrati per 100 g',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('barcode_food_fat_field'),
                      controller: _fat,
                      label: 'Grassi per 100 g',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DiaryNumberField(
                      key: const Key('barcode_food_serving_field'),
                      controller: _serving,
                      label: 'Porzione abituale (g)',
                      mustBePositive: true,
                    ),
                  ),
                ],
              ),
              if (warning != null) ...[
                const SizedBox(height: 12),
                Container(
                  key: const Key('barcode_atwater_warning'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppPalette.yellowSoft,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppPalette.yellow),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline_rounded,
                        color: AppPalette.yellow,
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(warning)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('barcode_food_save_button'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(
                  _saving ? 'Salvataggio…' : 'Salva e aggiungi al diario',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final per100g = _per100g();
    final serving = parseDiaryNumber(_serving.text);
    if (per100g == null || serving == null || serving <= 0) {
      return;
    }
    setState(() => _saving = true);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final food = await ref
          .read(barcodeLookupRepositoryProvider)
          .saveScannedFood(
            profileId: profile.id,
            draft: FoodDraft(
              name: _name.text,
              brand: _brand.text,
              barcode: widget.product.barcode,
              per100g: per100g,
              defaultServingGrams: serving,
            ),
          );
      if (mounted) {
        Navigator.pop(context, food);
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

/// Vista scanner reale (mobile_scanner): solo EAN/UPC, torcia e messaggi
/// in italiano quando la fotocamera è negata o non parte. La richiesta del
/// permesso runtime la gestisce il plugin all'avvio del controller.
class _MobileScannerView extends StatefulWidget {
  const _MobileScannerView({required this.onBarcode});

  final ValueChanged<String> onBarcode;

  @override
  State<_MobileScannerView> createState() => _MobileScannerViewState();
}

class _MobileScannerViewState extends State<_MobileScannerView> {
  late final MobileScannerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error) => _CameraErrorPanel(error: error),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: IconButton.filledTonal(
              key: const Key('barcode_torch_button'),
              tooltip: 'Accendi o spegni la torcia',
              onPressed: _controller.toggleTorch,
              icon: const Icon(Icons.flashlight_on_rounded),
            ),
          ),
        ),
      ],
    );
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim() ?? '';
      if (value.isNotEmpty && RegExp(r'^\d+$').hasMatch(value)) {
        widget.onBarcode(value);
        return;
      }
    }
  }
}

/// Fotocamera negata o rotta: mai un crash, un invito alle impostazioni.
class _CameraErrorPanel extends StatelessWidget {
  const _CameraErrorPanel({required this.error});

  final MobileScannerException error;

  bool get _denied =>
      error.errorCode == MobileScannerErrorCode.permissionDenied;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('barcode_camera_error'),
      color: AppPalette.cream,
      padding: const EdgeInsets.all(28),
      // Il pannello prende il posto del mirino, ma è tutto testo: qui la
      // colonna leggibile serve, e centrata verticalmente com'era prima.
      child: AdaptiveContent(
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              size: 44,
              color: AppPalette.mutedInk,
            ),
            const SizedBox(height: 14),
            Text(
              _denied
                  ? 'La fotocamera per Coach360 è spenta. Aprila dalle '
                        'Impostazioni del telefono (Coach360 → Fotocamera) '
                        'e torna qui: ci metti un attimo.'
                  : 'Non riesco ad aprire la fotocamera. Chiudi questa '
                        'schermata e riprova tra poco.',
              textAlign: TextAlign.center,
            ),
            if (_denied) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('barcode_open_settings_button'),
                onPressed: () => _openSettings(context),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Apri le impostazioni'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openSettings(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Su iOS 'app-settings:' apre la pagina dell'app; dove non funziona
      // resta l'invito testuale (niente crash, niente dipendenze nuove).
      final opened = await launchUrl(Uri.parse('app-settings:'));
      if (!opened) {
        throw StateError('impostazioni non raggiungibili');
      }
    } on Object {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Apri le Impostazioni del telefono e attiva la fotocamera '
            'per Coach360.',
          ),
        ),
      );
    }
  }
}
