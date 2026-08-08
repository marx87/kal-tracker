import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/health/data/daily_health_summary_repository.dart';
import 'package:kal_tracker/features/health/data/health_data_service.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';

/// Punto di innesto dell'adapter di piattaforma.
///
/// Il default non simula Health Connect ne' un produttore: dichiara la funzione
/// indisponibile. L'app Android puo' sovrascriverlo con un adapter reale solo
/// dopo aver aggiunto dipendenza, manifest, consenso e test sul dispositivo.
final healthDataGatewayProvider = Provider<HealthDataGateway>(
  (ref) => const UnavailableHealthDataGateway(
    detail: 'Nessun adapter salute configurato su questa installazione.',
  ),
);

final dailyHealthSummaryRepositoryProvider =
    Provider<DailyHealthSummaryRepository>(
      (ref) => DailyHealthSummaryRepository(ref.watch(databaseProvider)),
    );

final healthDataServiceProvider = Provider<HealthDataService>(
  (ref) => HealthDataService(
    ref.watch(healthDataGatewayProvider),
    ref.watch(dailyHealthSummaryRepositoryProvider),
  ),
);
