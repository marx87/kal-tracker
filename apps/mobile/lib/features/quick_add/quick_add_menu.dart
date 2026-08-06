import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/meal_type_presentation.dart';

/// Le quattro strade dell'aggiunta al volo dal diario.
enum QuickAddAction { manual, catalog, photo, barcode }

/// Menu smart del FAB «Aggiungi alimento»: un bottom sheet con le quattro
/// azioni, tutte a portata di pollice. Ritorna null se Marco chiude.
///
/// Sul tablet non si allarga: i fogli modali di Material 3 si fermano a
/// 640 dp da soli, quindi qui non serve nessun limite di larghezza in più —
/// il test `quick_add_width_test` lo tiene fermo.
Future<QuickAddAction?> showQuickAddMenu(BuildContext context) =>
    showModalBottomSheet<QuickAddAction>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const QuickAddMenuSheet(),
    );

class QuickAddMenuSheet extends StatelessWidget {
  const QuickAddMenuSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cosa aggiungiamo?',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'Scegli la strada più comoda: nel diario arriva sempre '
              'la stessa cosa.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 14),
            const _QuickAddTile(
              key: Key('quick_add_manual'),
              action: QuickAddAction.manual,
              icon: Icons.edit_rounded,
              color: AppPalette.leaf,
              softColor: AppPalette.mintSoft,
              title: 'Scrivi a mano',
              subtitle: 'Nome, grammi e valori per 100 g',
            ),
            const _QuickAddTile(
              key: Key('quick_add_catalog'),
              action: QuickAddAction.catalog,
              icon: Icons.menu_book_rounded,
              color: AppPalette.yellow,
              softColor: AppPalette.yellowSoft,
              title: 'Dal catalogo e ricette',
              subtitle: 'Alimenti salvati, preferiti e piatti pronti',
            ),
            const _QuickAddTile(
              key: Key('quick_add_photo'),
              action: QuickAddAction.photo,
              icon: Icons.photo_camera_rounded,
              color: AppPalette.lilac,
              softColor: AppPalette.lilacSoft,
              title: 'Fotografa il pasto',
              subtitle: 'Tu scatti, l’app propone, tu confermi',
            ),
            const _QuickAddTile(
              key: Key('quick_add_barcode'),
              action: QuickAddAction.barcode,
              icon: Icons.qr_code_scanner_rounded,
              color: AppPalette.coral,
              softColor: AppPalette.coralSoft,
              title: 'Scansiona codice a barre',
              subtitle: 'Prodotti confezionati in un attimo',
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAddTile extends StatelessWidget {
  const _QuickAddTile({
    required this.action,
    required this.icon,
    required this.color,
    required this.softColor,
    required this.title,
    required this.subtitle,
    super.key,
  });

  final QuickAddAction action;
  final IconData icon;
  final Color color;
  final Color softColor;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () => Navigator.pop(context, action),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        tileColor: AppPalette.paper,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: softColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: AppPalette.mutedInk, fontSize: 12.5),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: AppPalette.mutedInk,
        ),
      ),
    );
  }
}

/// Scelta del pasto per i flussi che non la chiedono dopo (es. la foto):
/// stessi colori e icone dei pasti del diario.
Future<MealType?> showQuickAddMealPicker(
  BuildContext context, {
  String title = 'Per quale pasto?',
}) => showModalBottomSheet<MealType>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final type in MealType.values)
            ListTile(
              key: Key('quick_add_meal_${type.storageValue}'),
              leading: Icon(type.icon, color: type.accent),
              title: Text(type.label),
              onTap: () => Navigator.pop(context, type),
            ),
        ],
      ),
    ),
  ),
);
