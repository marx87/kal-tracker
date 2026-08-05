import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/body/data/flutter_blue_plus_scale_link.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/data/scale_reader.dart';
import 'package:kal_tracker/features/body/domain/bia_formula.dart';
import 'package:kal_tracker/features/body/domain/scale_session.dart';
import 'package:kal_tracker/features/body/presentation/body_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

/// La porta verso il Bluetooth. Nei test si sostituisce con una bilancia
/// finta: è l'unico modo di provare una funzione che nella vita vera richiede
/// di salire su una bilancia.
final scaleLinkProvider = Provider<ScaleLink>(
  (ref) => FlutterBluePlusScaleLink(),
);

final scaleReaderProvider = Provider<ScaleReader>((ref) {
  final reader = ScaleReader(ref.watch(scaleLinkProvider));
  ref.onDispose(reader.cancel);
  return reader;
});

final scaleSessionProvider =
    NotifierProvider<ScaleSessionController, ScaleStatus>(
      ScaleSessionController.new,
    );

/// Il regista della sessione: avvia la lettura, tiene lo stato che la
/// schermata disegna, e salva solo quando Marco lo chiede.
///
/// La pesata **non si salva da sola**. Sarebbe comodo e sbagliato: una salita
/// di prova sulla bilancia, o una pesata vestito, finirebbe nelle medie a 7
/// giorni senza che nessuno l'abbia voluta.
class ScaleSessionController extends Notifier<ScaleStatus> {
  /// Riverpod 2 non ha `ref.mounted`: se la schermata si chiude mentre la
  /// bilancia sta ancora parlando, assegnare `state` lancerebbe.
  bool _disposed = false;

  @override
  ScaleStatus build() {
    _disposed = false;
    // Il lettore si prende ORA, non dentro `onDispose`: quando la schermata
    // si chiude il contenitore dei provider è già smontato, e leggerlo lì
    // lancerebbe invece di chiudere il collegamento Bluetooth.
    final reader = ref.watch(scaleReaderProvider);
    ref.onDispose(() {
      _disposed = true;
      reader.cancel();
    });
    return const ScaleStatus.idle();
  }

  Future<void> start() async {
    if (state.isBusy) {
      return;
    }
    final reader = ref.read(scaleReaderProvider);
    await reader.read(onStatus: _emit);
  }

  /// Torna al punto di partenza, senza toccare quello che è già stato salvato.
  void reset() => _emit(const ScaleStatus.idle());

  /// Scrive la pesata. Lancia [FormatException] con un messaggio già
  /// leggibile quando c'è qualcosa da dire a Marco (un doppio salvataggio,
  /// per esempio).
  Future<void> save() async {
    final reading = state.reading;
    if (reading == null) {
      return;
    }
    final profile = await ref.read(marcoProfileProvider.future);
    final preview = _previewFor(
      reading: reading,
      heightCm: profile.heightCm,
      birthDate: profile.birthDate,
      sexCode: profile.sex,
    );
    await ref
        .read(bodyRepositoryProvider)
        .addScaleMeasurement(
          profileId: profile.id,
          reading: reading,
          composition: preview.composition,
        );
    _emit(state.copyWith(phase: ScalePhase.saved));
  }

  void _emit(ScaleStatus status) {
    if (_disposed) {
      return;
    }
    state = status;
  }
}

/// Quello che la formula ha da dire su una lettura, prima di salvarla —
/// **compresi i casi in cui non ha niente da dire**, che sono quelli in cui
/// una schermata mal fatta mostrerebbe uno zero.
@immutable
class ScalePreview {
  const ScalePreview({
    this.composition,
    this.profileIncomplete = false,
    this.outOfRange = false,
  });

  final BodyCompositionEstimate? composition;

  /// Mancano altezza, data di nascita o sesso: senza, nessuna equazione BIA
  /// ha qualcosa da dire, e vanno chiesti invece che stimati.
  final bool profileIncomplete;

  /// L'impedenza è fuori dal dominio della formula. Capita con un contatto
  /// parziale: il numero c'è ma non significa niente, e si tace.
  final bool outOfRange;

  bool get hasComposition => composition != null;
}

ScalePreview _previewFor({
  required ScaleReading reading,
  required double? heightCm,
  required DateTime? birthDate,
  required String? sexCode,
}) {
  if (!reading.hasImpedance) {
    return const ScalePreview();
  }
  final input = biaInputFrom(
    heightCm: heightCm,
    birthDate: birthDate,
    sexCode: sexCode,
    weightKg: reading.weightKg,
    impedanceOhm: reading.impedanceOhm,
    measuredAt: reading.measuredAt,
  );
  if (input == null) {
    return const ScalePreview(profileIncomplete: true);
  }
  final composition = BiaFormulas.current.estimate(input);
  if (composition == null) {
    return const ScalePreview(outOfRange: true);
  }
  return ScalePreview(composition: composition);
}

/// L'anteprima della composizione per la lettura corrente.
final scalePreviewProvider = FutureProvider<ScalePreview>((ref) async {
  final reading = ref.watch(scaleSessionProvider).reading;
  if (reading == null) {
    return const ScalePreview();
  }
  final profile = await ref.watch(marcoProfileProvider.future);
  return _previewFor(
    reading: reading,
    heightCm: profile.heightCm,
    birthDate: profile.birthDate,
    sexCode: profile.sex,
  );
});

/// Quante pesate una nuova versione della formula rifarebbe.
///
/// Il ricalcolo si **propone**, non si esegue di nascosto: riscrivere mesi di
/// storico senza dirlo sarebbe una sorpresa sgradevole, e per giunta
/// invisibile — i numeri cambierebbero senza che niente lo spieghi.
final scaleRecalculationProvider = FutureProvider<int>((ref) async {
  final profile = await ref.watch(marcoProfileProvider.future);
  final pending = await ref
      .watch(bodyRepositoryProvider)
      .pendingRecalculation(profileId: profile.id);
  return pending.length;
});
