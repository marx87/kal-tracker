import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppPalette.paper,
          border: Border(top: BorderSide(color: AppPalette.outline)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            key: const Key('main_navigation_bar'),
            selectedIndex: navigationShell.currentIndex,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            backgroundColor: AppPalette.paper,
            surfaceTintColor: Colors.transparent,
            indicatorColor: AppPalette.mint,
            onDestinationSelected: (index) => navigationShell.goBranch(
              index,
              initialLocation: index == navigationShell.currentIndex,
            ),
            destinations: const [
              NavigationDestination(
                key: Key('nav_today'),
                icon: Icon(Icons.today_outlined),
                selectedIcon: Icon(Icons.today_rounded),
                label: 'Oggi',
              ),
              NavigationDestination(
                key: Key('nav_foods'),
                icon: Icon(Icons.local_grocery_store_outlined),
                selectedIcon: Icon(Icons.local_grocery_store_rounded),
                label: 'Alimenti',
              ),
              NavigationDestination(
                key: Key('nav_recipes'),
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book_rounded),
                label: 'Ricette',
              ),
              // Nuova voce: l'ordine di queste destinazioni deve restare
              // identico a quello dei branch in app_router.dart.
              NavigationDestination(
                key: Key('nav_plan'),
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month_rounded),
                label: 'Piano',
              ),
              NavigationDestination(
                key: Key('nav_progress'),
                icon: Icon(Icons.insights_outlined),
                selectedIcon: Icon(Icons.insights_rounded),
                label: 'Progressi',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
