import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_checks.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_checks_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('shopping-checks-test');
  });

  tearDown(() => directory.delete(recursive: true));

  FileShoppingChecksStore store() =>
      FileShoppingChecksStore(directory: () async => directory);

  group('persistenza', () {
    test('senza file non c’è nessuna spunta', () async {
      final checks = await store().read();

      expect(checks, const ShoppingChecks.empty());
      expect(checks.planId, isNull);
      expect(checks.checked, isEmpty);
    });

    test('scrive e rilegge le spunte, anche da un nuovo store', () async {
      final checks = ShoppingChecks(
        planId: 'plan-1',
        checked: const ['pomodoro', 'riso basmati'],
      );

      await store().write(checks);
      final reloaded = await store().read();

      expect(reloaded, checks);
      expect(reloaded.forPlan('plan-1'), {'pomodoro', 'riso basmati'});
    });

    test('file rovinato: si riparte senza spunte e senza crash', () async {
      final file = File(
        '${directory.path}/${FileShoppingChecksStore.fileName}',
      );
      await file.writeAsString('questo non è JSON {');

      expect(await store().read(), const ShoppingChecks.empty());
    });

    test('JSON con campi assurdi viene sanificato', () async {
      final file = File(
        '${directory.path}/${FileShoppingChecksStore.fileName}',
      );
      await file.writeAsString('{"plan_id": 42, "checked": ["riso"]}');

      expect(await store().read(), const ShoppingChecks.empty());
    });

    test('le voci non stringa vengono scartate', () async {
      final file = File(
        '${directory.path}/${FileShoppingChecksStore.fileName}',
      );
      await file.writeAsString('{"plan_id": "plan-1", "checked": ["riso", 7]}');

      final checks = await store().read();

      expect(checks.forPlan('plan-1'), {'riso'});
    });
  });

  group('modello', () {
    test('le spunte di un piano vecchio non contano per quello nuovo', () {
      final checks = ShoppingChecks(
        planId: 'plan-1',
        checked: const ['pomodoro'],
      );

      expect(checks.isChecked('plan-1', 'pomodoro'), isTrue);
      expect(checks.isChecked('plan-2', 'pomodoro'), isFalse);
      expect(checks.forPlan('plan-2'), isEmpty);
    });

    test('la spunta si mette e si toglie', () {
      var checks = const ShoppingChecks.empty();

      checks = checks.toggled(planId: 'plan-1', key: 'pomodoro');
      expect(checks.forPlan('plan-1'), {'pomodoro'});

      checks = checks.toggled(planId: 'plan-1', key: 'riso');
      expect(checks.forPlan('plan-1'), {'pomodoro', 'riso'});

      checks = checks.toggled(planId: 'plan-1', key: 'pomodoro');
      expect(checks.forPlan('plan-1'), {'riso'});
    });

    test('spuntare su un piano nuovo ricomincia da zero', () {
      final checks = ShoppingChecks(
        planId: 'plan-1',
        checked: const ['pomodoro'],
      ).toggled(planId: 'plan-2', key: 'riso');

      expect(checks.planId, 'plan-2');
      expect(checks.checked, {'riso'});
    });

    test('azzerare svuota solo il piano indicato', () {
      final checks = ShoppingChecks(
        planId: 'plan-1',
        checked: const ['pomodoro', 'riso'],
      ).clearedFor('plan-1');

      expect(checks.planId, 'plan-1');
      expect(checks.checked, isEmpty);
    });

    test('il giro JSON è stabile', () {
      final checks = ShoppingChecks(
        planId: 'plan-1',
        checked: const ['riso', 'pomodoro'],
      );

      expect(checks.toJson(), {
        'plan_id': 'plan-1',
        'checked': ['pomodoro', 'riso'],
      });
      expect(ShoppingChecks.fromJson(checks.toJson()), checks);
    });
  });
}
