import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/status_chip.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

void main() {
  Widget host(Widget child, {ThemeData? theme}) => MaterialApp(
    theme: theme ?? AppTheme.light,
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('ogni livello ha la sua parola', (tester) async {
    await tester.pumpWidget(
      host(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusChip(level: AppStatusLevel.good),
            StatusChip(level: AppStatusLevel.warning),
            StatusChip(level: AppStatusLevel.critical),
          ],
        ),
      ),
    );

    expect(find.text('Buono'), findsOneWidget);
    expect(find.text('Attenzione'), findsOneWidget);
    expect(find.text('Critico'), findsOneWidget);
  });

  testWidgets('il significato non è affidato al solo colore: forme diverse', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusChip(level: AppStatusLevel.good),
            StatusChip(level: AppStatusLevel.warning),
            StatusChip(level: AppStatusLevel.critical),
          ],
        ),
      ),
    );

    final icons = tester
        .widgetList<Icon>(find.byType(Icon))
        .map((icon) => icon.icon)
        .toList();
    expect(icons.toSet().length, 3, reason: 'tre livelli, tre forme diverse');
    expect(icons, contains(Icons.check_circle_rounded));
    expect(icons, contains(Icons.warning_amber_rounded));
    expect(icons, contains(Icons.dangerous_rounded));
  });

  testWidgets('un\'etichetta su misura resta accompagnata dal livello', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const StatusChip(level: AppStatusLevel.critical, label: '4 scadute'),
      ),
    );

    expect(find.text('4 scadute'), findsOneWidget);
    final node = tester.getSemantics(find.byType(StatusChip));
    expect(node.label, 'Stato critico: 4 scadute');
    handle.dispose();
  });

  testWidgets('i colori arrivano dal tema e cambiano al buio', (tester) async {
    Color foregroundIn(ThemeData theme) {
      return AppStatusLevel.warning.foreground(theme.extension<AppAccents>()!);
    }

    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(
        host(const StatusChip(level: AppStatusLevel.warning), theme: theme),
      );
      // MaterialApp interpola il cambio di tema: senza attendere si
      // leggerebbe un colore a metà strada.
      await tester.pumpAndSettle();
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, foregroundIn(theme));
    }

    expect(
      foregroundIn(AppTheme.light),
      isNot(foregroundIn(AppTheme.dark)),
      reason: 'di notte l\'ambra piena non si legge, serve la versione chiara',
    );
  });

  testWidgets('la versione compatta resta leggibile', (tester) async {
    await tester.pumpWidget(
      host(const StatusChip(level: AppStatusLevel.good, compact: true)),
    );
    expect(find.text('Buono'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
