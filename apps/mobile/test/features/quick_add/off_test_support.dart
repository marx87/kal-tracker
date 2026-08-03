import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Adapter Dio finto per Open Food Facts: risponde con l'handler dato e
/// registra le richieste, così i test dimostrano il local-first (zero
/// chiamate quando il barcode è già nel DB) e l'assenza di API key.
class FakeOffAdapter implements HttpClientAdapter {
  FakeOffAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  int get calls => requests.length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody offJsonResponse(String body, {int status = 200}) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Dio offDio(FakeOffAdapter adapter) => Dio()..httpClientAdapter = adapter;

/// Risposta OFF v2 «reale-tipo»: campi extra che ignoriamo, marche
/// concatenate con la virgola e numeri sia num che stringa, come arrivano
/// davvero dall'API.
const String offNutellaJson = '''
{
  "code": "3017620422003",
  "status": 1,
  "status_verbose": "product found",
  "product": {
    "product_name": "Nutella",
    "product_name_it": "Nutella crema alle nocciole",
    "brands": "Ferrero, Nutella",
    "nutriments": {
      "energy_100g": 2255,
      "energy-kcal_100g": 539,
      "energy-kcal_unit": "kcal",
      "proteins_100g": "6.3",
      "proteins_unit": "g",
      "carbohydrates_100g": 57.5,
      "sugars_100g": 56.3,
      "fat_100g": 30.9,
      "saturated-fat_100g": 10.6,
      "fiber_100g": 3.4,
      "salt_100g": 0.107
    }
  }
}
''';

/// Prodotto che dichiara solo i kJ: 1046 kJ / 4,184 = 250 kcal.
const String offOnlyKilojoulesJson = '''
{
  "code": "8076809513692",
  "status": 1,
  "status_verbose": "product found",
  "product": {
    "product_name": "Pesto alla genovese",
    "brands": "Barilla",
    "nutriments": {
      "energy_100g": 1046,
      "proteins_100g": 5.2,
      "carbohydrates_100g": 9.8,
      "fat_100g": 22.5
    }
  }
}
''';

/// OFF risponde 404 con status 0 per i codici che non conosce.
const String offNotFoundJson =
    '{"code":"4000000000000","status":0,"status_verbose":"product not found"}';
