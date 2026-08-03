import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';

/// Origine degli alimenti nati da una scansione: la riga resta personale
/// e modificabile come un 'custom', ma si riconosce da dove arriva.
const String barcodeFoodSource = 'barcode';

/// Esito della ricerca per codice a barre, in ordine di preferenza:
/// prima il DB locale, poi Open Food Facts, altrimenti si scrive a mano.
sealed class BarcodeLookupResult {
  const BarcodeLookupResult();
}

/// L'alimento è già vivo nel catalogo locale: nessuna rete, si va
/// dritti all'inserimento nel diario.
class BarcodeFoodMatch extends BarcodeLookupResult {
  const BarcodeFoodMatch(this.food);

  final FoodCatalogItem food;
}

/// Proposta da confermare, coi valori modificabili: arriva da Open Food
/// Facts (i per-100 g di OFF sono spesso sporchi) o da un proprio alimento
/// eliminato con lo stesso barcode, che torna vivo solo alla conferma.
class BarcodeProductProposal extends BarcodeLookupResult {
  const BarcodeProductProposal(this.product);

  final OpenFoodFactsProduct product;
}

/// Nessuno conosce questo codice: si compila l'alimento a mano,
/// col barcode già valorizzato per la prossima volta.
class BarcodeUnknownProduct extends BarcodeLookupResult {
  const BarcodeUnknownProduct(this.barcode);

  final String barcode;
}

/// Rete assente o lenta: local-first, si prosegue offline a mano.
class BarcodeLookupOffline extends BarcodeLookupResult {
  const BarcodeLookupOffline(this.barcode);

  final String barcode;
}

/// I soli campi Open Food Facts che ci interessano: nome, marca e i
/// per-100 g. Ogni valore può mancare: la scheda di conferma li chiede.
class OpenFoodFactsProduct {
  const OpenFoodFactsProduct({
    required this.barcode,
    this.name,
    this.brand,
    this.caloriesPer100g,
    this.proteinPer100g,
    this.carbsPer100g,
    this.fatPer100g,
  });

  final String barcode;
  final String? name;
  final String? brand;
  final double? caloriesPer100g;
  final double? proteinPer100g;
  final double? carbsPer100g;
  final double? fatPer100g;

  factory OpenFoodFactsProduct.fromApi(
    String barcode,
    Map<String, Object?> product,
  ) {
    final nutriments = product['nutriments'];
    final values = nutriments is Map
        ? Map<String, Object?>.from(nutriments)
        : const <String, Object?>{};
    var calories = _cleanNumber(values['energy-kcal_100g']);
    if (calories == null) {
      // Alcuni prodotti dichiarano solo i kJ: 1 kcal = 4,184 kJ.
      final kilojoules = _cleanNumber(values['energy_100g']);
      calories = kilojoules == null ? null : _round1(kilojoules / 4.184);
    }
    return OpenFoodFactsProduct(
      barcode: barcode,
      name:
          _cleanText(product['product_name_it'], maxLength: 160) ??
          _cleanText(product['product_name'], maxLength: 160),
      brand: _cleanBrand(product['brands']),
      caloriesPer100g: calories,
      proteinPer100g: _cleanNumber(values['proteins_100g']),
      carbsPer100g: _cleanNumber(values['carbohydrates_100g']),
      fatPer100g: _cleanNumber(values['fat_100g']),
    );
  }

  bool get hasCompleteNutrition =>
      caloriesPer100g != null &&
      proteinPer100g != null &&
      carbsPer100g != null &&
      fatPer100g != null;

  Nutrients? get per100g => hasCompleteNutrition
      ? Nutrients(
          calories: caloriesPer100g!,
          protein: proteinPer100g!,
          carbs: carbsPer100g!,
          fat: fatPer100g!,
        )
      : null;

  static String? _cleanText(Object? value, {required int maxLength}) {
    if (value is! String) {
      return null;
    }
    final clean = value.trim();
    if (clean.isEmpty) {
      return null;
    }
    return clean.length > maxLength ? clean.substring(0, maxLength) : clean;
  }

  /// OFF concatena le marche con la virgola: la prima basta e avanza.
  static String? _cleanBrand(Object? value) {
    if (value is! String) {
      return null;
    }
    final first = value.split(',').first;
    return _cleanText(first, maxLength: 120);
  }

  /// I numeri OFF arrivano come num o come stringa (anche con la virgola):
  /// tutto il resto — negativi, infiniti, spazzatura — diventa null.
  static double? _cleanNumber(Object? value) {
    double? parsed;
    if (value is num) {
      parsed = value.toDouble();
    } else if (value is String) {
      parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    }
    if (parsed == null || !parsed.isFinite || parsed < 0) {
      return null;
    }
    return _round1(parsed);
  }

  static double _round1(double value) => (value * 10).roundToDouble() / 10;
}

/// Local-first: prima la colonna barcode di Foods, poi Open Food Facts v2
/// (senza alcuna API key), e il risultato confermato si salva come alimento
/// locale — la scansione successiva non tocca più la rete.
class BarcodeLookupRepository {
  BarcodeLookupRepository({
    required this._catalog,
    required this._dio,
    this._baseUrl = defaultBaseUrl,
  });

  static const String defaultBaseUrl = 'https://world.openfoodfacts.org';
  static const String _fields =
      'product_name,product_name_it,brands,nutriments';

  final FoodCatalogRepository _catalog;
  final Dio _dio;
  final String _baseUrl;

  Future<BarcodeLookupResult> lookup({
    required String profileId,
    required String barcode,
  }) async {
    final clean = barcode.trim();
    if (clean.isEmpty ||
        clean.length > 32 ||
        !RegExp(r'^\d+$').hasMatch(clean)) {
      throw const FormatException(
        'Questo non sembra un codice a barre: riprova a inquadrarlo.',
      );
    }
    final local = await _catalog.findByBarcode(
      profileId: profileId,
      barcode: clean,
    );
    if (local != null) {
      return BarcodeFoodMatch(local);
    }
    // Un proprio alimento eliminato con questo barcode NON torna vivo per
    // la sola scansione: se ne ripropongono i valori (sempre senza rete) e
    // la riesumazione avviene solo alla conferma, in [saveScannedFood].
    final deleted = await _catalog.findTombstoneDraftByBarcode(
      profileId: profileId,
      barcode: clean,
    );
    if (deleted != null) {
      return BarcodeProductProposal(
        OpenFoodFactsProduct(
          barcode: clean,
          name: deleted.name,
          brand: deleted.brand,
          caloriesPer100g: deleted.per100g.calories,
          proteinPer100g: deleted.per100g.protein,
          carbsPer100g: deleted.per100g.carbs,
          fatPer100g: deleted.per100g.fat,
        ),
      );
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/api/v2/product/$clean',
        queryParameters: const {'fields': _fields},
        options: Options(
          responseType: ResponseType.json,
          // OFF risponde 404 (con status 0 nel body) per i codici ignoti:
          // non è un errore di rete, è «prodotto sconosciuto».
          validateStatus: (status) => status == 200 || status == 404,
        ),
      );
      final body = response.data;
      final product = body?['product'];
      if (body?['status'] == 1 && product is Map) {
        return BarcodeProductProposal(
          OpenFoodFactsProduct.fromApi(
            clean,
            Map<String, Object?>.from(product),
          ),
        );
      }
      return BarcodeUnknownProduct(clean);
    } on DioException {
      return BarcodeLookupOffline(clean);
    } on Object {
      // Body malformato o sorprese di parsing: per Marco è come essere
      // offline, si prosegue a mano senza crash.
      return BarcodeLookupOffline(clean);
    }
  }

  /// Salva il prodotto confermato come alimento personale con source
  /// 'barcode' e barcode valorizzato: la prossima scansione è tutta
  /// offline. È SOLO qui, alla conferma, che un eventuale tombstone con
  /// questo barcode torna vivo — coi valori appena confermati.
  Future<FoodCatalogItem> saveScannedFood({
    required String profileId,
    required FoodDraft draft,
  }) async {
    final id =
        await _catalog.resurrectFoodByBarcode(
          profileId: profileId,
          draft: draft,
        ) ??
        await _catalog.createFood(
          profileId: profileId,
          draft: draft,
          source: barcodeFoodSource,
        );
    final food = await _catalog.getFood(profileId: profileId, foodId: id);
    if (food == null) {
      throw const FoodCatalogException('Non riesco a salvare questo alimento.');
    }
    return food;
  }
}

/// Client Open Food Facts: timeout brevi (mai bloccare il diario per la
/// rete) e User-Agent identificativo come chiede la loro policy. Nessuna
/// API key: OFF non ne richiede.
final openFoodFactsDioProvider = Provider<Dio>(
  (ref) => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 6),
      headers: const {
        'User-Agent': 'KalTracker/0.6 (diario alimentare personale offline)',
      },
    ),
  ),
);

final barcodeLookupRepositoryProvider = Provider<BarcodeLookupRepository>(
  (ref) => BarcodeLookupRepository(
    catalog: ref.watch(foodCatalogRepositoryProvider),
    dio: ref.watch(openFoodFactsDioProvider),
  ),
);
