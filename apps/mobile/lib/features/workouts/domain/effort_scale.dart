/// Conversioni fra RIR (ripetizioni in riserva) e la scala RPE già salvata.
///
/// Il database continua a conservare un solo numero RPE: in questo modo lo
/// storico, la progressione e la sincronizzazione non cambiano formato. Nella
/// sessione live si può però rispondere con il più immediato RIR 0–4.
abstract final class EffortScale {
  static const int minRir = 0;
  static const int maxRir = 4;

  /// RIR 0 = RPE 10, RIR 4 = RPE 6.
  static int rpeFromRir(int rir) => 10 - rir.clamp(minRir, maxRir);

  /// Gli RPE 6–10 hanno una corrispondenza RIR 4–0. Valori più bassi restano
  /// RPE puri: chiamarli RIR 4 nasconderebbe informazione.
  static int? rirFromRpe(int? rpe) {
    if (rpe == null || rpe < 6 || rpe > 10) return null;
    return 10 - rpe;
  }

  static String compactLabel(int? rpe) {
    if (rpe == null) return 'RIR';
    final rir = rirFromRpe(rpe);
    return rir == null ? 'RPE $rpe' : 'RIR $rir';
  }

  static String semanticLabel(int? rpe) {
    if (rpe == null) {
      return 'Ripetizioni in riserva non impostate. Tocca per scegliere.';
    }
    final rir = rirFromRpe(rpe);
    if (rir == null) return 'Sforzo percepito $rpe su 10.';
    return '$rir ripetizioni in riserva, equivalente a RPE $rpe su 10.';
  }
}
