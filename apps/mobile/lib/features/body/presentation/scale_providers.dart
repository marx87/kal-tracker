import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/local_settings_store.dart';
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

final localSettingsProvider = Provider<LocalSettingsStore>(
  (ref) => LocalSettingsStore(ref.watch(databaseProvider)),
);

/// La bilancia scelta a mano, se c'è già stata una volta.
final rememberedScaleProvider = FutureProvider<RememberedScale?>((ref) async {
  final store = ref.watch(localSettingsProvider);
  final id = await store.read(LocalSettingsStore.scaleDeviceId);
  if (id == null || id.isEmpty) {
    return null;
  }
  final name = await store.read(LocalSettingsStore.scaleDeviceName);
  return RememberedScale(id: id, name: name ?? '');
});

/// La bilancia che Marco ha indicato una volta, e che da lì in poi si cerca
/// per indirizzo invece che per indovinello.
@immutable
class RememberedScale {
  const RememberedScale({required this.id, required this.name});

  final String id;
  final String name;

  String get label => name.isEmpty ? id : name;
}

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

  /// Vero mentre un gesto è stato raccolto ma la sessione che ne nasce non è
  /// ancora partita.
  ///
  /// `state.isBusy` non basta più. Prima bastava, perché `read()` emetteva la
  /// prima fase in modo sincrono e al secondo tocco lo stato era già occupato;
  /// da quando in mezzo c'è la lettura della bilancia ricordata — che gira su
  /// un isolate di sfondo, quindi un giro di messaggi vero — la fase resta
  /// `idle` per tutto quel tempo, il pulsante resta premibile e due tocchi
  /// aprono due sessioni. È esattamente il momento in cui Marco tocca
  /// «Cerca», non vede succedere niente e ritocca.
  bool _handling = false;

  Future<void> start() async {
    if (_handling || state.isBusy) {
      return;
    }
    _handling = true;
    final ScaleReader reader;
    final RememberedScale? remembered;
    final ScaleUser? user;
    try {
      reader = ref.read(scaleReaderProvider);
      remembered = await ref.read(rememberedScaleProvider.future);
      user = await _scaleUser(ref);
    } finally {
      _handling = false;
    }
    // Nessun `await` fra qui e la riga sotto: `read()` emette `checkingRadio`
    // prima di sospendersi, quindi da questo punto in poi è `isBusy` a fare
    // la guardia e la staffetta si chiude senza buchi.
    await reader.read(
      onStatus: _emit,
      preferredDeviceId: remembered?.id,
      user: user,
    );
  }

  /// Marco ha indicato quale dei dispositivi visti è la bilancia.
  ///
  /// La scelta si **ricorda subito**, prima ancora di provare a collegarsi:
  /// se il collegamento fallisce per un motivo qualsiasi — è sceso dalla
  /// bilancia, è passato un microonde — la risposta a «qual è la tua
  /// bilancia?» resta valida lo stesso, e non ha senso richiederla.
  Future<void> choose(ScaleDevice device) async {
    // La stessa regola che decide se l'elenco è in schermata: scegliere ha
    // senso solo finché c'è qualcosa da scegliere. Il secondo tocco di una
    // doppietta arriva quando la sessione è già partita, e va lasciato cadere.
    if (_handling || !state.phase.canChooseDevice) {
      return;
    }
    _handling = true;
    // La fase cambia **subito e in modo sincrono**, prima di qualunque
    // attesa. Non è cosmesi: l'elenco dei candidati si disegna solo nelle fasi
    // `scanning` e `chooseDevice`, quindi da questa riga in poi non c'è più
    // niente da toccare. Senza, fra il tocco e il collegamento restavano due
    // scritture su database — su un isolate di sfondo, quindi tempo vero — con
    // le righe ancora lì: un secondo tocco apriva una seconda sessione sulla
    // stessa bilancia, che è precisamente ciò che fa fallire anche la prima,
    // perché la Renpho accetta un collegamento solo.
    _emit(state.copyWith(phase: ScalePhase.connecting));

    final ScaleReader reader;
    final bool raccolta;
    try {
      final store = ref.read(localSettingsProvider);
      await store.write(LocalSettingsStore.scaleDeviceId, device.id);
      await store.write(LocalSettingsStore.scaleDeviceName, device.name);
      ref.invalidate(rememberedScaleProvider);
      reader = ref.read(scaleReaderProvider);
      // Se la scansione è ancora aperta la scelta la raccoglie lei, e la
      // lettura già in volo prosegue da sola: ricollegarsi qui vorrebbe dire
      // aprire due sessioni sulla stessa bilancia.
      raccolta = reader.chooseWhileScanning(device);
    } finally {
      _handling = false;
    }
    if (raccolta) {
      return;
    }
    await reader.connectTo(
      device,
      onStatus: _emit,
      user: await _scaleUser(ref),
    );
  }

  /// Chi sta salendo, dal profilo dell'app.
  ///
  /// Torna `null` quando il profilo è incompleto, e in quel caso la bilancia
  /// a otto elettrodi darà il solo peso: mandarle un'altezza inventata
  /// produrrebbe una composizione inventata, che è peggio di non averla.
  Future<ScaleUser?> _scaleUser(Ref ref) async {
    final profile = await ref.read(marcoProfileProvider.future);
    // L'ultimo peso salvato serve a presentarsi PRIMA di salire: la bilancia
    // non consegna la pesata che tiene in memoria a chi non si è ancora
    // annunciato, e senza un peso da mettere nel profilo non ci si può
    // annunciare. È lo stesso peso che l'app Renpho manda al collegamento.
    double? ultimo;
    try {
      ultimo = await ref
          .read(bodyRepositoryProvider)
          .latestWeightKg(profileId: profile.id);
    } on Object {
      // Nessun peso noto: ci si presenterà appena qualcuno sale, come prima.
    }
    return ScaleUser.from(
      heightCm: profile.heightCm,
      birthDate: profile.birthDate,
      sexCode: profile.sex,
      now: DateTime.now(),
      lastWeightKg: ultimo,
    );
  }

  /// Dimentica la bilancia scelta: si torna a riconoscerla da sola.
  Future<void> forget() async {
    final store = ref.read(localSettingsProvider);
    await store.remove(LocalSettingsStore.scaleDeviceId);
    await store.remove(LocalSettingsStore.scaleDeviceName);
    ref.invalidate(rememberedScaleProvider);
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
