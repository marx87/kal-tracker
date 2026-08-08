import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/effort_scale.dart';

void main() {
  group('EffortScale', () {
    test('converte RIR 0–4 nella scala RPE esistente', () {
      expect(EffortScale.rpeFromRir(0), 10);
      expect(EffortScale.rpeFromRir(1), 9);
      expect(EffortScale.rpeFromRir(2), 8);
      expect(EffortScale.rpeFromRir(3), 7);
      expect(EffortScale.rpeFromRir(4), 6);
    });

    test('limita valori RIR fuori scala', () {
      expect(EffortScale.rpeFromRir(-2), 10);
      expect(EffortScale.rpeFromRir(8), 6);
    });

    test('ricostruisce RIR solo quando la conversione non perde dati', () {
      expect(EffortScale.rirFromRpe(10), 0);
      expect(EffortScale.rirFromRpe(6), 4);
      expect(EffortScale.rirFromRpe(5), isNull);
      expect(EffortScale.rirFromRpe(null), isNull);
    });

    test('mantiene visibili gli RPE storici sotto 6', () {
      expect(EffortScale.compactLabel(8), 'RIR 2');
      expect(EffortScale.compactLabel(4), 'RPE 4');
    });
  });
}
