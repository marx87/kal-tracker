import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/onboarding/data/onboarding_store.dart';
import 'package:kal_tracker/features/onboarding/data/personal_details_repository.dart';
import 'package:kal_tracker/features/onboarding/domain/personal_details.dart';

final onboardingStoreProvider = Provider<OnboardingStore>(
  (ref) => FileOnboardingStore(),
);

final personalDetailsRepositoryProvider = Provider<PersonalDetailsRepository>(
  (ref) => PersonalDetailsRepository(ref.watch(databaseProvider)),
);

final personalDetailsProvider = FutureProvider<PersonalDetails>((ref) async {
  // Tutte le `watch` sincrone prima del primo await: nel buco asincrono il
  // provider non deve perdere le sue dipendenze.
  final repository = ref.watch(personalDetailsRepositoryProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  return repository.read(profile.id);
});

/// Se il benvenuto va mostrato adesso.
///
/// Due condizioni, in quest'ordine: mancano dei dati, e non li ho ancora
/// chiesti. La seconda è quella che rende il «lo faccio dopo» una risposta e
/// non un rinvio: chi salta non se lo ritrova davanti al lancio successivo.
///
/// **Se non riesco a leggere dove ho segnato la domanda, non la faccio.** Non
/// è prudenza eccessiva: senza un posto in cui scrivere «già chiesto», la
/// schermata tornerebbe a ogni avvio e «salta» smetterebbe di significare
/// qualcosa. Succede nei test — dove `path_provider` non esiste — e su
/// un'installazione con lo spazio di supporto rotto; in entrambi i casi
/// l'app deve limitarsi ad aprirsi.
final onboardingNeededProvider = FutureProvider<bool>((ref) async {
  final store = ref.watch(onboardingStoreProvider);
  final details = await ref.watch(personalDetailsProvider.future);
  if (details.isComplete) {
    return false;
  }
  final memory = await store.read();
  return memory.readable && memory.askedAt == null;
});

/// Le due sole azioni del primo avvio: salvare quello che si è scritto, o
/// dire che se ne riparla.
class OnboardingController {
  OnboardingController(this._ref);

  final Ref _ref;

  /// Salva i dati e segna la domanda come fatta.
  ///
  /// L'ordine conta: se la scrittura sul profilo fallisce l'eccezione esce di
  /// qui e la domanda NON risulta fatta, così il benvenuto ritorna invece di
  /// far sparire in silenzio quello che Marco aveva appena scritto.
  Future<void> save(PersonalDetails details) async {
    final profile = await _ref.read(marcoProfileProvider.future);
    await _ref
        .read(personalDetailsRepositoryProvider)
        .write(profile.id, details);
    await _ref.read(onboardingStoreProvider).markAsked(AppTime.nowUtc());
    _invalidate();
  }

  /// «Lo faccio dopo»: nessun dato scritto, domanda archiviata.
  Future<void> skip() async {
    await _ref.read(onboardingStoreProvider).markAsked(AppTime.nowUtc());
    _invalidate();
  }

  void _invalidate() {
    _ref.invalidate(personalDetailsProvider);
    // Anche il gate esplicitamente: il ricordo della domanda non è un
    // provider, quindi da solo non lo farebbe ricalcolare nessuno.
    _ref.invalidate(onboardingNeededProvider);
  }
}

final onboardingControllerProvider = Provider<OnboardingController>(
  OnboardingController.new,
);
