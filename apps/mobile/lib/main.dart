import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppTime.initialize();

  const config = AppConfig.fromEnvironment();
  if (config.hasSupabaseConfiguration) {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
    );
  }

  final container = ProviderContainer(
    overrides: [appConfigProvider.overrideWithValue(config)],
  );
  // Importa il catalogo piatti senza bloccare l'avvio: se fallisce l'app
  // parte comunque e l'import si ritenta al lancio successivo.
  unawaited(container.read(catalogSeedImporterProvider).importIfNeeded());

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KalTrackerApp(),
    ),
  );
}
