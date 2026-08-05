/// Il lucchetto attorno al gesto «serie fatta». COPIA VERBATIM di
/// `features/workouts/set_completion_guard.dart` di Gym Tracker.
///
/// Flutter consegna due tap prima che il primo salvataggio atteso finisca: da
/// qui in poi ogni completamento in più è un no-op finché la scrittura non è
/// andata a fondo. Commenti in inglese come nel sorgente, apposta.
library;

/// Small synchronous lock used around a set completion gesture.
///
/// Flutter can deliver two taps before the first awaited save finishes. This
/// guard makes every further completion a no-op until the durable write has
/// finished. The lock is global because the focused CTA can advance to the
/// next cell before the first cell's save completes.
class SetCompletionGuard {
  String? _locked;

  String _key(int exerciseIndex, int setIndex) => '$exerciseIndex:$setIndex';

  bool acquire(int exerciseIndex, int setIndex) {
    if (_locked != null) return false;
    _locked = _key(exerciseIndex, setIndex);
    return true;
  }

  void release(int exerciseIndex, int setIndex) {
    if (_locked == _key(exerciseIndex, setIndex)) _locked = null;
  }

  bool isLocked(int exerciseIndex, int setIndex) =>
      _locked == _key(exerciseIndex, setIndex);

  bool get isBusy => _locked != null;
}
