import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/training_profile/data/training_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

final trainingProfileRepositoryProvider = Provider<TrainingProfileRepository>(
  (ref) => TrainingProfileRepository(ref.watch(databaseProvider)),
);

/// Il profilo di allenamento di Marco, che si aggiorna da solo.
///
/// Stream e non lettura secca perché le limitazioni si aprono e si chiudono
/// dalla stessa schermata che le mostra: dopo una chiusura l'elenco deve già
/// essere quello nuovo, senza che qualcuno si ricordi di ricaricarlo.
///
/// Non emette mai errore per «riga assente»: il repository restituisce
/// comunque un profilo vuoto, che è lo stato normale di chi non ha ancora
/// risposto a niente.
final trainingProfileProvider = StreamProvider<TrainingProfile>((ref) async* {
  // Tutte le watch sincrone PRIMA del primo await: nel buco asincrono il
  // provider non deve perdere le dipendenze (è la stessa regola già scritta
  // nei provider del corpo e dell'acqua).
  final repository = ref.watch(trainingProfileRepositoryProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* repository.watchProfile(profile.id);
});
