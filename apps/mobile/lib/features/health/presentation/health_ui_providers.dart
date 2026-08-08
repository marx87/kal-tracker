import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:kal_tracker/features/health/presentation/health_providers.dart';

/// Stato dichiarato dall'adapter reale. La schermata lo ricarica solo dopo
/// un'azione esplicita dell'utente: leggere lo stato non apre finestre di
/// permesso e non avvia importazioni in background.
final healthGatewayStatusProvider =
    FutureProvider.autoDispose<HealthGatewayStatus>(
      (ref) => ref.watch(healthDataServiceProvider).status(),
    );

/// I riepiloghi già salvati sul dispositivo negli ultimi sette giorni.
///
/// Questo provider non interroga Health Connect o HealthKit: guarda solo il
/// database locale. Il gateway viene letto esclusivamente quando l'utente
/// tocca «Importa ultimi 7 giorni».
final recentHealthSummariesProvider =
    StreamProvider.autoDispose<List<HealthDailySummary>>((ref) async* {
      final profile = await ref.watch(marcoProfileProvider.future);
      final throughDay = healthCalendarDay(ref.watch(todayProvider));
      final fromDay = throughDay.subtract(const Duration(days: 6));
      yield* ref
          .watch(dailyHealthSummaryRepositoryProvider)
          .watch(
            profileId: profile.id,
            fromDay: fromDay,
            throughDay: throughDay,
          );
    });

/// Il repository tratta il giorno come una data UTC, non come un istante.
/// Ricostruirlo evita che la mezzanotte italiana diventi il giorno prima.
DateTime healthCalendarDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
