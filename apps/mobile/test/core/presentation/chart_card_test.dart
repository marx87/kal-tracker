import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/chart_card.dart';
import 'package:kal_tracker/core/presentation/empty_state.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );

  const fakeChart = ColoredBox(
    key: Key('fake_chart'),
    color: Color(0xFF000000),
    child: SizedBox.expand(),
  );

  testWidgets('senza dati mostra lo stato vuoto al posto del grafico', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const ChartCard(
          title: 'Andamento peso',
          chart: null,
          emptyMessage: 'Pesati una prima volta per vedere la curva.',
          series: [ChartSeries(label: 'Peso', color: Color(0xFF245B45))],
        ),
      ),
    );

    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(
      find.text('Pesati una prima volta per vedere la curva.'),
      findsOneWidget,
    );
    // La legenda descrive dati che non ci sono: sparisce con loro.
    expect(find.text('Peso'), findsNothing);
    expect(find.byKey(const Key('fake_chart')), findsNothing);
  });

  testWidgets('con i dati mostra grafico e legenda', (tester) async {
    await tester.pumpWidget(
      host(
        const ChartCard(
          title: 'Andamento',
          height: 180,
          chart: fakeChart,
          series: [
            ChartSeries(label: 'Peso', color: Color(0xFF245B45)),
            ChartSeries(
              label: 'Media 7 giorni',
              color: Color(0xFFE86F5B),
              marker: Icons.timeline_rounded,
            ),
          ],
        ),
      ),
    );

    expect(find.byType(AppEmptyState), findsNothing);
    expect(tester.getSize(find.byKey(const Key('fake_chart'))).height, 180);
    expect(find.text('Peso'), findsOneWidget);
    expect(find.text('Media 7 giorni'), findsOneWidget);
    expect(find.byIcon(Icons.timeline_rounded), findsOneWidget);
  });

  testWidgets('la legenda è letta in blocco, non voce per voce', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const ChartCard(
          title: 'Andamento',
          chart: fakeChart,
          series: [
            ChartSeries(label: 'Peso', color: Color(0xFF245B45)),
            ChartSeries(label: 'Media 7 giorni', color: Color(0xFFE86F5B)),
          ],
        ),
      ),
    );

    expect(
      find.bySemanticsLabel('Legenda: Peso, Media 7 giorni'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('porta con sé titolo e azione della sezione', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      host(
        ChartCard(
          title: 'Andamento',
          subtitle: 'Ultimi 30 giorni',
          icon: Icons.insights_rounded,
          chart: fakeChart,
          actionLabel: 'Apri',
          onAction: () => tapped++,
        ),
      ),
    );

    expect(find.text('Andamento'), findsOneWidget);
    expect(find.text('Ultimi 30 giorni'), findsOneWidget);
    await tester.tap(find.byKey(const Key('section_card_action')));
    expect(tapped, 1);
  });
}
