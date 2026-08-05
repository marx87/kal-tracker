import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';

void main() {
  group('soglie', () {
    test('le tre taglie si dividono su 840 e 1180', () {
      expect(AppBreakpoints.fromWidth(360), AppWindowSize.compact);
      expect(AppBreakpoints.fromWidth(839.9), AppWindowSize.compact);
      expect(AppBreakpoints.fromWidth(840), AppWindowSize.medium);
      expect(AppBreakpoints.fromWidth(1179.9), AppWindowSize.medium);
      expect(AppBreakpoints.fromWidth(1180), AppWindowSize.expanded);
    });

    test('il rail parte da medium, esteso solo da expanded', () {
      expect(AppWindowSize.compact.usesNavigationRail, isFalse);
      expect(AppWindowSize.medium.usesNavigationRail, isTrue);
      expect(AppWindowSize.expanded.usesNavigationRail, isTrue);

      expect(AppWindowSize.medium.usesExtendedRail, isFalse);
      expect(AppWindowSize.expanded.usesExtendedRail, isTrue);
    });

    test('colonne, margini e gutter crescono con lo spazio', () {
      expect(AppBreakpoints.columns(AppWindowSize.compact), 1);
      expect(AppBreakpoints.columns(AppWindowSize.medium), 2);
      expect(AppBreakpoints.columns(AppWindowSize.expanded), 3);

      expect(
        AppBreakpoints.gutter(AppWindowSize.compact),
        lessThan(AppBreakpoints.gutter(AppWindowSize.expanded)),
      );
      expect(
        AppBreakpoints.pagePadding(AppWindowSize.compact).left,
        lessThan(AppBreakpoints.pagePadding(AppWindowSize.expanded).left),
      );
    });

    test('la colonna di contenuto smette di crescere oltre il telefono', () {
      expect(
        AppBreakpoints.contentMaxWidth(AppWindowSize.compact),
        double.infinity,
      );
      expect(AppBreakpoints.contentMaxWidth(AppWindowSize.medium), 720);
      expect(AppBreakpoints.contentMaxWidth(AppWindowSize.expanded), 880);
    });
  });

  group('AdaptiveLayout', () {
    Future<void> resizeTo(WidgetTester tester, double width) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    Future<AppWindowSize> sizeAt(WidgetTester tester, double width) async {
      await resizeTo(tester, width);
      late AppWindowSize seen;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AdaptiveLayout(
            builder: (context, size) {
              seen = size;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return seen;
    }

    testWidgets('misura lo spazio disponibile, non lo schermo', (tester) async {
      expect(await sizeAt(tester, 400), AppWindowSize.compact);
      expect(await sizeAt(tester, 900), AppWindowSize.medium);
      expect(await sizeAt(tester, 1300), AppWindowSize.expanded);
    });

    testWidgets('dentro un pannello stretto di uno schermo largo resta '
        'compatto', (tester) async {
      await resizeTo(tester, 1300);
      late AppWindowSize seen;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              SizedBox(
                width: 380,
                child: AdaptiveLayout(
                  builder: (context, size) {
                    seen = size;
                    return const SizedBox.shrink();
                  },
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      );
      expect(seen, AppWindowSize.compact);
    });

    testWidgets('senza larghezza vincolata non lancia', (tester) async {
      await resizeTo(tester, 400);
      late AppWindowSize seen;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              AdaptiveLayout(
                builder: (context, size) {
                  seen = size;
                  return const SizedBox(width: 50);
                },
              ),
            ],
          ),
        ),
      );
      expect(seen, AppWindowSize.compact);
      expect(tester.takeException(), isNull);
    });
  });

  group('AdaptiveContent', () {
    Future<double> widthAt(WidgetTester tester, double available) async {
      await tester.binding.setSurfaceSize(Size(available, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: AdaptiveContent(
            child: SizedBox(
              key: Key('content'),
              width: double.infinity,
              height: 40,
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const Key('content'))).width;
    }

    testWidgets('sul telefono occupa tutto, sul tablet si ferma', (
      tester,
    ) async {
      expect(await widthAt(tester, 400), 400);
      expect(await widthAt(tester, 1000), 720);
      expect(await widthAt(tester, 1400), 880);
    });
  });
}
