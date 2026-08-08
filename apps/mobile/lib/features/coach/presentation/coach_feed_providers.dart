import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/coach/data/coach_feed_repository.dart';
import 'package:kal_tracker/features/coach/domain/coach_feed_item.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

final coachFeedRepositoryProvider = Provider<CoachFeedRepository>(
  (ref) => CoachFeedRepository(ref.watch(databaseProvider)),
);

/// Il feed visibile del profilo, dal più recente.
final coachFeedProvider = StreamProvider.autoDispose<List<CoachFeedItem>>((
  ref,
) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(coachFeedRepositoryProvider).watch(profileId: profile.id);
});

/// Le mutazioni del feed sono separate dallo stream: la card può restare un
/// widget di sola presentazione e Drift emette subito il nuovo stato.
final coachFeedActionsProvider = Provider<CoachFeedActions>(
  (ref) => CoachFeedActions(ref.watch(coachFeedRepositoryProvider)),
);

class CoachFeedActions {
  const CoachFeedActions(this._repository);

  final CoachFeedRepository _repository;

  Future<void> markRead(String itemId) => _repository.markRead(itemId);

  Future<void> dismiss(String itemId) => _repository.dismiss(itemId);
}
