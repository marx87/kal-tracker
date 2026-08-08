import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/workouts/domain/countdown.dart';

/// Il cronometro del recupero. Copia funzionale di `RestTimerController` di
/// Gym Tracker: cambia solo che qui non c'è dentro anche il banner — quello è
/// in `presentation/widgets/rest_timer_banner.dart`.
///
/// Il conto alla rovescia è ancorato a una SCADENZA ASSOLUTA, non alla somma
/// dei tick: il `Timer.periodic` si ferma quando l'app va in secondo piano, e
/// senza [synchronize] al ritorno il recupero durerebbe quanto è durata la
/// telefonata.
class RestTimerController extends ChangeNotifier {
  RestTimerController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  Duration _total = Duration.zero;
  bool _completed = false;
  void Function(int remainingSec)? _onTick;
  VoidCallback? _onComplete;
  bool _completionDelivered = false;
  DateTime? _deadline;

  Duration get remaining => _remaining;
  Duration get total => _total;
  DateTime? get deadline => _deadline;
  bool get isRunning => _ticker?.isActive ?? false;
  bool get isCompleted => _completed;

  /// Vero quando c'è qualcosa da mostrare: in corso, oppure finito e in
  /// attesa che l'utente lo chiuda.
  bool get isVisible => isRunning || _completed || _remaining > Duration.zero;

  void start(
    Duration duration, {
    void Function(int remainingSec)? onTick,
    VoidCallback? onComplete,
  }) {
    _ticker?.cancel();
    _total = duration;
    _remaining = duration;
    _completed = false;
    _completionDelivered = false;
    _deadline = _now().add(duration);
    _onTick = onTick;
    _onComplete = onComplete;
    notifyListeners();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => synchronize());
  }

  /// Riallinea il display alla scadenza assoluta. Si può chiamare anche dal
  /// ritorno in primo piano, quando il timer periodico è rimasto sospeso.
  void synchronize({DateTime? now}) {
    final deadline = _deadline;
    if (deadline == null || _completed) return;
    final seconds = remainingCountdownSeconds(deadline, now ?? _now());
    if (seconds <= 0) {
      _ticker?.cancel();
      _remaining = Duration.zero;
      _completed = true;
      notifyListeners();
      _deliverComplete();
      return;
    }
    if (seconds == _remaining.inSeconds) return;
    _remaining = Duration(seconds: seconds);
    _onTick?.call(seconds);
    notifyListeners();
  }

  void cancel() {
    _ticker?.cancel();
    _remaining = Duration.zero;
    _total = Duration.zero;
    _completed = false;
    _onTick = null;
    _onComplete = null;
    _completionDelivered = false;
    _deadline = null;
    notifyListeners();
  }

  /// Chiude il recupero SUBITO seguendo la strada normale di fine.
  ///
  /// È volutamente diverso da [cancel]: la superserie guidata lo usa per
  /// «Salta e continua», quindi la stazione successiva deve partire lo stesso
  /// — esattamente una volta. [cancel] invece ferma il flusso senza farlo
  /// avanzare.
  void skip() {
    if (_total == Duration.zero || _completionDelivered) return;
    _ticker?.cancel();
    _remaining = Duration.zero;
    _completed = true;
    _deadline = null;
    notifyListeners();
    _deliverComplete();
  }

  void _deliverComplete() {
    if (_completionDelivered) return;
    _completionDelivered = true;
    final callback = _onComplete;
    _onComplete = null;
    callback?.call();
  }

  /// ±15 secondi. Se il saldo va a zero o sotto, il recupero finisce come se
  /// fosse scaduto — con la sua callback, non in silenzio.
  void addSeconds(int seconds) {
    if (_total == Duration.zero) return;
    final next = _remaining + Duration(seconds: seconds);
    if (next <= Duration.zero) {
      _ticker?.cancel();
      _remaining = Duration.zero;
      _completed = true;
      _deadline = null;
      notifyListeners();
      _deliverComplete();
      return;
    }
    _deadline = (_deadline ?? _now()).add(Duration(seconds: seconds));
    _remaining = next;
    final adjustedTotal = _total + Duration(seconds: seconds);
    _total = adjustedTotal < _remaining ? _remaining : adjustedTotal;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
