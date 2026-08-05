import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/stat_row.dart';
import 'package:kal_tracker/core/presentation/status_chip.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

void main() {
  Widget host(Widget child, {TextScaler scaler = TextScaler.noScaling}) {
    return MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: scaler),
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }

  testWidgets('mostra etichetta, valore e unità', (tester) async {
    await tester.pumpWidget(
      host(
        const StatRow(
          label: 'Peso',
          value: '82,4',
          unit: 'kg',
          caption: '-0,6 kg in sette giorni',
          icon: Icons.monitor_weight_rounded,
        ),
      ),
    );

    expect(find.text('Peso'), findsOneWidget);
    expect(find.text('82,4'), findsOneWidget);
    expect(find.text('kg'), findsOneWidget);
    expect(find.text('-0,6 kg in sette giorni'), findsOneWidget);
  });

  testWidgets('il valore usa cifre tabulari', (tester) async {
    await tester.pumpWidget(
      host(const StatRow(label: 'Calorie', value: '1.980', unit: 'kcal')),
    );

    final value = tester.widget<Text>(find.text('1.980'));
    expect(
      value.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
      reason: 'senza cifre tabulari la colonna dei numeri balla',
    );
  });

  testWidgets('il valore è più grande dell\'etichetta', (tester) async {
    await tester.pumpWidget(
      host(const StatRow(label: 'Calorie', value: '1.980', unit: 'kcal')),
    );

    final label = tester.widget<Text>(find.text('Calorie')).style!.fontSize!;
    final value = tester.widget<Text>(find.text('1.980')).style!.fontSize!;
    expect(value, greaterThan(label));
  });

  testWidgets('a caratteri ingranditi si impila invece di troncare', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const StatRow(
          label: 'Volume settimanale',
          value: '12.400',
          unit: 'kg',
          caption: 'Serie allenanti comprese',
        ),
        scaler: const TextScaler.linear(1.5),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('12.400'), findsOneWidget);
    expect(find.text('Volume settimanale'), findsOneWidget);
    // Impilata: il valore sta sotto l'etichetta, non alla sua destra.
    expect(
      tester.getTopLeft(find.text('12.400')).dy,
      greaterThan(tester.getTopLeft(find.text('Volume settimanale')).dy),
    );
  });

  testWidgets('è letta come una sola riga, con l\'unità per esteso', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const StatRow(
          label: 'Peso',
          value: '82,4',
          unit: 'kg',
          unitSemantics: 'chilogrammi',
        ),
      ),
    );

    final node = tester.getSemantics(find.byType(StatRow));
    expect(node.label, 'Peso');
    expect(node.value, '82,4 chilogrammi');
    handle.dispose();
  });

  testWidgets('lo stato accanto al valore conserva la sua voce', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const StatRow(
          label: 'Idratazione',
          value: '900',
          unit: 'ml',
          trailing: StatusChip(level: AppStatusLevel.warning, compact: true),
        ),
      ),
    );

    expect(
      find.bySemanticsLabel(RegExp('Stato attenzione')),
      findsOneWidget,
      reason: 'lo stato non deve sparire dentro la riga',
    );
    handle.dispose();
  });
}
