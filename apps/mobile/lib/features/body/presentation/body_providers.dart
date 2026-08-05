import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/data/body_repository.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

final bodyRepositoryProvider = Provider<BodyRepository>(
  (ref) => BodyRepository(ref.watch(databaseProvider)),
);

/// Finestra scelta dai chip. Tre mesi come default: un mese è troppo poco per
/// vedere una ricomposizione, sei rendono il grafico una riga piatta.
final bodyRangeProvider = StateProvider<BodyRange>((ref) => BodyRange.quarter);

/// Le pesate grezze del periodo. La query chiede anche i giorni di
/// riscaldamento della media mobile, altrimenti il primo punto del grafico
/// sarebbe una media a un giorno solo con l'aria di una media a sette.
final bodyMeasurementsProvider = StreamProvider<List<BodyMeasurement>>((
  ref,
) async* {
  // Tutte le watch sincrone PRIMA del primo await: nel buco asincrono il
  // provider non deve perdere le dipendenze (stessa regola già scritta nei
  // provider dell'acqua).
  final repository = ref.watch(bodyRepositoryProvider);
  final range = ref.watch(bodyRangeProvider);
  final today = ref.watch(todayProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  final since = AppTime.startOfDayUtc(
    today,
  ).subtract(Duration(days: range.days - 1 + BodyAnalysis.warmupDays));
  yield* repository.watchMeasurements(profileId: profile.id, since: since);
});

/// Tutto già calcolato: medie a 7 giorni, variazioni, verdetto, rumore della
/// BIA e circonferenze. La schermata legge questo e non fa conti propri.
final bodyInsightsProvider = Provider<AsyncValue<BodyInsights>>((ref) {
  final range = ref.watch(bodyRangeProvider);
  final today = ref.watch(todayProvider);
  return ref
      .watch(bodyMeasurementsProvider)
      .whenData(
        (measurements) => BodyAnalysis.build(
          measurements: measurements,
          range: range,
          now: today,
        ),
      );
});

/// Le etichette di circonferenza già usate, dalla più frequente: il foglio di
/// inserimento propone quelle invece di un elenco deciso a tavolino, così chi
/// arriva da Gym Tracker ritrova le sue ('Vita', 'Braccio', …).
final knownCircumferenceLabelsProvider = Provider<List<String>>((ref) {
  final measurements =
      ref.watch(bodyMeasurementsProvider).valueOrNull ??
      const <BodyMeasurement>[];
  final counts = <String, int>{};
  for (final measurement in measurements) {
    for (final label in measurement.circumferences.keys) {
      counts[label] = (counts[label] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) {
    return const ['Vita', 'Petto', 'Braccio', 'Coscia'];
  }
  final labels = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : a.compareTo(b);
    });
  return List.unmodifiable(labels);
});
