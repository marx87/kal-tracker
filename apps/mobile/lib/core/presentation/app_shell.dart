import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';

/// Le cinque destinazioni di Coach360.
///
/// Le due app fuse avevano cinque voci ciascuna: dieci sono impraticabili, e
/// raggrupparle per «tipo di dato» (alimenti, esercizi, misure) avrebbe
/// ricalcato la struttura del database invece del modo in cui si usa l'app.
/// Queste cinque seguono il momento della giornata: cosa faccio adesso, cosa
/// mangio, cosa alleno, come sto andando, cosa farò.
enum AppDestination {
  today(
    label: 'Oggi',
    icon: Icons.today_outlined,
    selectedIcon: Icons.today_rounded,
    key: 'nav_today',
  ),
  food(
    label: 'Cibo',
    icon: Icons.restaurant_outlined,
    selectedIcon: Icons.restaurant_rounded,
    key: 'nav_food',
  ),
  gym(
    label: 'Palestra',
    icon: Icons.fitness_center_outlined,
    selectedIcon: Icons.fitness_center,
    key: 'nav_gym',
  ),
  body(
    label: 'Corpo',
    icon: Icons.monitor_weight_outlined,
    selectedIcon: Icons.monitor_weight_rounded,
    key: 'nav_body',
  ),
  plan(
    label: 'Piano',
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month_rounded,
    key: 'nav_plan',
  );

  const AppDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.key,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String key;
}

/// Guscio di navigazione: barra in basso sul telefono, guida laterale sul
/// tablet.
///
/// Marco ha telefono e tablet, e li usa per cose diverse: il telefono in
/// palestra con una mano sola, il tablet a casa per pianificare e guardare i
/// grafici. La barra in basso è comoda dove il pollice arriva; su uno schermo
/// largo sprecherebbe altezza e allontanerebbe i comandi dagli occhi.
class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  void _select(int index) => navigationShell.goBranch(
    index,
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context) {
    return AdaptiveLayout(
      builder: (context, size) => size == AppWindowSize.compact
          ? _CompactShell(shell: navigationShell, onSelect: _select)
          : _ExpandedShell(
              shell: navigationShell,
              onSelect: _select,
              extended: size == AppWindowSize.expanded,
            ),
    );
  }
}

class _CompactShell extends StatelessWidget {
  const _CompactShell({required this.shell, required this.onSelect});

  final StatefulNavigationShell shell;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: shell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            key: const Key('main_navigation_bar'),
            selectedIndex: shell.currentIndex,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            backgroundColor: colors.surfaceContainerLowest,
            surfaceTintColor: Colors.transparent,
            indicatorColor: colors.primaryContainer,
            onDestinationSelected: onSelect,
            destinations: [
              for (final destination in AppDestination.values)
                NavigationDestination(
                  key: Key(destination.key),
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: destination.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Su tablet la guida resta sempre visibile: il contenuto non si sposta
/// cambiando sezione, così l'occhio non deve ritrovare il punto ogni volta.
class _ExpandedShell extends StatelessWidget {
  const _ExpandedShell({
    required this.shell,
    required this.onSelect,
    required this.extended,
  });

  final StatefulNavigationShell shell;
  final ValueChanged<int> onSelect;

  /// Sopra i 1180 logici c'è spazio per le etichette accanto alle icone.
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            key: const Key('main_navigation_rail'),
            selectedIndex: shell.currentIndex,
            onDestinationSelected: onSelect,
            extended: extended,
            labelType: extended
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            backgroundColor: colors.surfaceContainerLowest,
            indicatorColor: colors.primaryContainer,
            destinations: [
              for (final destination in AppDestination.values)
                NavigationRailDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: Text(destination.label),
                ),
            ],
          ),
          VerticalDivider(width: 1, color: colors.outlineVariant),
          Expanded(child: shell),
        ],
      ),
    );
  }
}
