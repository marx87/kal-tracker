import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/notifications/water_reminder_providers.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';
import 'package:kal_tracker/features/wellbeing/presentation/wellbeing_providers.dart';
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
  // Installa il ricettario fit del profilo, sempre senza bloccare l'avvio:
  // l'import è versionato e le liste reattive si riempiono a batch concluso.
  unawaited(_importRecipeCatalog(container));
  // Ripianifica i promemoria acqua se Marco li ha attivi: lo scheduling
  // vive nel sistema (zonedSchedule), non in un timer in-app.
  unawaited(_rescheduleWaterReminders(container));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KalTrackerApp(),
    ),
  );
}

Future<void> _importRecipeCatalog(ProviderContainer container) async {
  try {
    final profile = await container.read(marcoProfileProvider.future);
    await container
        .read(recipeCatalogImporterProvider)
        .importIfNeeded(profile.id);
  } on Object {
    // Il ricettario non deve mai bloccare l'avvio: si ritenta al lancio dopo.
  }
}

Future<void> _rescheduleWaterReminders(ProviderContainer container) async {
  try {
    final settings = await container.read(waterSettingsStoreProvider).read();
    await container
        .read(waterRemindersServiceProvider)
        .rescheduleOnStartup(settings);
  } on Object {
    // I promemoria non devono mai bloccare l'avvio dell'app.
  }
}
