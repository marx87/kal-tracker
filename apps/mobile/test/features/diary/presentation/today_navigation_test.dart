import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/presentation/app_shell.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/presentation/weigh_in_sheet.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_detail_screen.dart';

/// Qui serve il router vero: le ricette vivono nella voce «Cibo» e il punto
/// da verificare è proprio che partendo da «Oggi» ci si arrivi davvero.
Widget _app(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    checkInStoreProvider.overrideWithValue(InMemoryCheckInStore()),
  ],
  child: const KalTrackerApp(),
);

void main() {
  testWidgets('dalla ricetta suggerita si apre la sua scheda', (tester) async {
    AppTime.initialize();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    final suggestion = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('today_recipe_'),
    );
    expect(suggestion, findsWidgets);

    await tester.ensureVisible(suggestion.first);
    await tester.pumpAndSettle();
    await tester.tap(suggestion.first);
    await tester.pumpAndSettle();

    expect(find.byType(RecipeDetailScreen), findsOneWidget);
    // La barra in basso deve raccontare la verità su dove si è finiti: la
    // ricetta sta in «Cibo», non in «Oggi».
    final bar = tester.widget<NavigationBar>(
      find.byKey(const Key('main_navigation_bar')),
    );
    expect(bar.selectedIndex, AppDestination.food.index);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });

  testWidgets('dal check-in si apre il foglio della pesata', (tester) async {
    AppTime.initialize();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('check_in_weigh_in_button'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    // È il foglio della schermata Corpo, non una seconda strada per lo
    // stesso dato.
    expect(find.byType(WeighInSheet), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
