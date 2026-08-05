import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/section_card.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

void main() {
  Widget host(Widget child, {ThemeData? theme}) => MaterialApp(
    theme: theme ?? AppTheme.light,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );

  testWidgets('mostra titolo, sottotitolo e contenuto', (tester) async {
    await tester.pumpWidget(
      host(
        const SectionCard(
          title: 'Allenamenti',
          subtitle: 'Ultimi sette giorni',
          icon: Icons.fitness_center_rounded,
          child: Text('contenuto'),
        ),
      ),
    );

    expect(find.text('Allenamenti'), findsOneWidget);
    expect(find.text('Ultimi sette giorni'), findsOneWidget);
    expect(find.text('contenuto'), findsOneWidget);
    expect(find.byIcon(Icons.fitness_center_rounded), findsOneWidget);
  });

  testWidgets('l\'azione è opzionale e quando c\'è è toccabile a 48', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      host(
        SectionCard(
          title: 'Peso',
          actionLabel: 'Storico',
          onAction: () => tapped++,
          child: const Text('contenuto'),
        ),
      ),
    );

    final action = find.byKey(const Key('section_card_action'));
    expect(action, findsOneWidget);
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(action).width, greaterThanOrEqualTo(48));

    await tester.tap(action);
    expect(tapped, 1);
  });

  testWidgets('senza azione non compare nessun bottone', (tester) async {
    await tester.pumpWidget(
      host(const SectionCard(title: 'Peso', child: Text('contenuto'))),
    );
    expect(find.byKey(const Key('section_card_action')), findsNothing);
  });

  test('etichetta e callback non possono essere scompagnate', () {
    expect(
      () => SectionCard(
        title: 'Peso',
        actionLabel: 'Storico',
        child: const SizedBox.shrink(),
      ),
      throwsAssertionError,
    );
  });

  testWidgets('il titolo è annunciato come intestazione', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(const SectionCard(title: 'Allenamenti', child: Text('contenuto'))),
    );

    expect(
      tester.getSemantics(find.text('Allenamenti')),
      isSemantics(isHeader: true),
    );
    handle.dispose();
  });

  testWidgets('eredita la forma della card dal tema, anche al buio', (
    tester,
  ) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(
        host(
          const SectionCard(title: 'Peso', child: Text('contenuto')),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      final card = tester.widget<Card>(find.byType(Card));
      // Nessun colore scritto a mano nel widget: viene tutto dal tema.
      expect(card.color, isNull);
      expect(
        Theme.of(tester.element(find.byType(Card))).cardTheme.color,
        theme.cardTheme.color,
      );
    }
  });
}
