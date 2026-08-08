import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';
import 'package:kal_tracker/features/workouts/domain/live_load_guidance.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/live_load_guidance_card.dart';

void main() {
  const guidance = LiveLoadGuidance(
    verdict: ProgressionVerdict.salire,
    reason: 'Hai completato l’intervallo.',
    sourceSets: 3,
    lastWeightKg: 20,
    lastReps: 12,
    lastRpe: 8,
    proposedWeightKg: 22,
    proposedReps: 8,
  );

  testWidgets('mostra ultimo risultato e proposta applicabile', (tester) async {
    var applied = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveLoadGuidanceCard(
            guidance: guidance,
            onApply: () => applied = true,
          ),
        ),
      ),
    );

    expect(find.text('22 kg × 8 rip.'), findsOneWidget);
    expect(find.text('Ultima: 20 kg · 12 rip. · RPE 8'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_load_apply')));
    expect(applied, isTrue);
  });

  testWidgets('dopo applicazione offre undo al posto del secondo apply', (
    tester,
  ) async {
    var undone = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveLoadGuidanceCard(
            guidance: guidance,
            onApply: () {},
            onUndo: () => undone = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('live_load_apply')), findsNothing);
    await tester.tap(find.byKey(const Key('live_load_undo')));
    expect(undone, isTrue);
  });
}
