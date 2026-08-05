import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_pace.dart';
import 'package:uuid/uuid.dart';

/// Legge e scrive l'Obiettivo, tenendo insieme corrente e storico.
///
/// La regola che governa tutto: **cambiare idea non azzera niente**. Un
/// obiettivo sostituito viene archiviato con la sua data di chiusura, e
/// quello nuovo riparte dal peso di oggi. Tendenze, pesate e TDEE misurato
/// non passano di qui: sono proprietà del corpo, non del traguardo.
class GoalRepository {
  GoalRepository(this._store, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final GoalStore _store;
  final Uuid _uuid;

  /// Quanti obiettivi chiusi si conservano. Oltre, lo storico diventa un
  /// archivio che nessuno guarda e un file che cresce per sempre.
  static const int maxHistoryEntries = 20;

  Future<GoalHistory> read() => _store.read();

  /// Imposta un obiettivo nuovo, archiviando quello in corso.
  ///
  /// [currentWeightKg] e [fatFreeMassKg] sono lo stato di partenza di
  /// *questo* traguardo: servono a misurarne i progressi senza andare a
  /// ripescare quando è stato creato.
  Future<GoalHistory> setGoal({
    required double targetWeightKg,
    required DefinitionLevel targetLevel,
    required double paceKgPerWeek,
    required double currentWeightKg,
    required double fatFreeMassKg,
  }) async {
    if (!targetWeightKg.isFinite ||
        targetWeightKg < 20 ||
        targetWeightKg > 500) {
      throw const FormatException('Il peso traguardo non è un peso.');
    }
    _requireSafePace(
      paceKgPerWeek: paceKgPerWeek,
      currentWeightKg: currentWeightKg,
    );
    final now = AppTime.nowUtc();
    final history = await _store.read();
    final goal = Goal(
      id: _uuid.v4(),
      targetWeightKg: targetWeightKg,
      targetLevel: targetLevel,
      paceKgPerWeek: paceKgPerWeek,
      startedAt: now,
      startWeightKg: currentWeightKg,
      startFatFreeMassKg: fatFreeMassKg,
      phaseStartedAt: now,
    );
    final updated = GoalHistory(
      current: goal,
      past: _archive(history, closedAt: now, outcome: GoalOutcome.replaced),
    );
    await _store.write(updated);
    return updated;
  }

  /// Cambia il solo ritmo. L'obiettivo resta lo stesso — stesso id, stessa
  /// data di partenza, stesso storico — e cambiano deficit e data stimata.
  Future<GoalHistory> setPace({
    required double paceKgPerWeek,
    required double currentWeightKg,
  }) async {
    _requireSafePace(
      paceKgPerWeek: paceKgPerWeek,
      currentWeightKg: currentWeightKg,
    );
    final history = await _store.read();
    final current = history.current;
    if (current == null) {
      return history;
    }
    final updated = GoalHistory(
      current: current.copyWith(paceKgPerWeek: paceKgPerWeek),
      past: history.past,
    );
    await _store.write(updated);
    return updated;
  }

  /// Passa alla fase indicata, segnandone l'inizio: è da lì che il
  /// consolidamento conta le settimane.
  Future<GoalHistory> setPhase(GoalPhase phase) async {
    final history = await _store.read();
    final current = history.current;
    if (current == null || current.phase == phase) {
      return history;
    }
    final updated = GoalHistory(
      current: current.copyWith(phase: phase, phaseStartedAt: AppTime.nowUtc()),
      past: history.past,
    );
    await _store.write(updated);
    return updated;
  }

  /// Chiude l'obiettivo corrente e lascia l'app senza traguardo: è uno
  /// stato legittimo, non un guasto.
  Future<GoalHistory> clearGoal({
    GoalOutcome outcome = GoalOutcome.abandoned,
  }) async {
    final history = await _store.read();
    if (history.current == null) {
      return history;
    }
    final updated = GoalHistory(
      past: _archive(history, closedAt: AppTime.nowUtc(), outcome: outcome),
    );
    await _store.write(updated);
    return updated;
  }

  /// Annulla l'ultimo cambio: rimette in corsa l'obiettivo archiviato più di
  /// recente e butta quello appena creato.
  ///
  /// Serve al «Annulla» della snackbar: cambiare traguardo è normale, ma
  /// cambiarlo per sbaglio con un dito sulla manopola lo è altrettanto.
  Future<GoalHistory> undoLastChange() async {
    final history = await _store.read();
    if (history.past.isEmpty) {
      return history;
    }
    final restored = history.past.first;
    final updated = GoalHistory(
      current: Goal(
        id: restored.id,
        targetWeightKg: restored.targetWeightKg,
        targetLevel: restored.targetLevel,
        paceKgPerWeek: restored.paceKgPerWeek,
        startedAt: restored.startedAt,
        startWeightKg: restored.startWeightKg,
        startFatFreeMassKg: restored.startFatFreeMassKg,
        phase: restored.phase,
        phaseStartedAt: restored.phaseStartedAt,
      ),
      past: history.past.skip(1).toList(growable: false),
    );
    await _store.write(updated);
    return updated;
  }

  /// Il limite dello 0,7 % non vive solo nel foglio del ritmo.
  ///
  /// Un rifiuto che sta unicamente nella UI è un rifiuto che il primo
  /// chiamante distratto aggira: qui la scrittura si ferma, con la stessa
  /// spiegazione che leggerebbe Marco.
  void _requireSafePace({
    required double paceKgPerWeek,
    required double currentWeightKg,
  }) {
    final verdict = GoalPace.assess(
      currentWeightKg: currentWeightKg,
      requestedKgPerWeek: paceKgPerWeek,
    );
    if (!verdict.accepted) {
      throw FormatException(verdict.refusal ?? 'Ritmo non accettabile.');
    }
  }

  List<Goal> _archive(
    GoalHistory history, {
    required DateTime closedAt,
    required GoalOutcome outcome,
  }) {
    final current = history.current;
    if (current == null) {
      return history.past;
    }
    // Il più recente in testa: è l'ordine in cui lo si guarda e quello che
    // rende `undoLastChange` una semplice `first`.
    return [
      current.copyWith(closedAt: closedAt, outcome: outcome),
      ...history.past,
    ].take(maxHistoryEntries).toList(growable: false);
  }
}
