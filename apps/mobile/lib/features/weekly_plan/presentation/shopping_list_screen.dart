import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_checks.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_builder.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_text.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_list_providers.dart';

/// Lista della spesa del piano (sottorotta di /plan: resta dentro la shell,
/// quindi la barra in basso rimane visibile).
///
/// Tutto quello che si vede qui viene dagli ingredienti REALI delle ricette
/// scelte dal piano, scalati per le porzioni: niente è inventato e niente
/// arriva dall'AI. Le spunte sono un promemoria locale e non toccano né il
/// piano né il diario.
class ShoppingListScreen extends ConsumerWidget {
  const ShoppingListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shoppingList = ref.watch(shoppingListProvider);
    final checks =
        ref.watch(shoppingChecksProvider).valueOrNull ??
        const ShoppingChecks.empty();

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lista della spesa'),
            Text(
              'Tutto quello che serve per il piano',
              style: TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      // L'eccezione del gruppo: qui NON si legge, si cammina fra gli scaffali.
      // Le voci sono corte (nome + quantità), quindi su uno schermo largo i
      // reparti stanno affiancati due per riga invece che uno sotto l'altro:
      // metà scorrimento davanti al banco, e il giro del supermercato resta
      // nell'ordine giusto perché si legge da sinistra a destra.
      body: AdaptiveLayout(
        builder: (context, size) => AdaptiveContent(
          child: ListView(
            key: const Key('shopping_list'),
            padding: AppBreakpoints.pagePadding(size),
            children: switch (shoppingList) {
              AsyncData(:final value?) => _loaded(
                ref,
                size,
                value,
                checks.forPlan(value.planId),
              ),
              AsyncData() => const [_EmptyCard()],
              AsyncError() => const [_ErrorCard()],
              _ => const [_LoadingCard()],
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _loaded(
    WidgetRef ref,
    AppWindowSize size,
    ShoppingList list,
    Set<String> checkedKeys,
  ) {
    final blocks = [
      for (final department in list.departments)
        _DepartmentBlock(
          department: department,
          checkedKeys: checkedKeys,
          onToggle: (key) => ref
              .read(shoppingChecksProvider.notifier)
              .toggle(planId: list.planId, key: key),
        ),
    ];
    return [
      // Un piano fatto di sole ricette sparite non ha niente da comprare, ma
      // la spiegazione deve restare: sotto al vuoto si dice comunque cosa
      // manca.
      if (list.isEmpty)
        const _EmptyCard()
      else
        _SummaryCard(list: list, checkedKeys: checkedKeys),
      if (list.unavailableRecipes.isNotEmpty) ...[
        const SizedBox(height: 14),
        _MissingRecipesCard(names: list.unavailableRecipes),
      ],
      ..._departmentRows(size, blocks),
    ];
  }

  /// I reparti: in fila sul telefono, due per riga da `medium` in su.
  ///
  /// Restano appaiati nell'ordine del giro (ortofrutta accanto a macelleria,
  /// poi la coppia dopo): affiancarli in due colonne indipendenti
  /// costringerebbe a scendere tutta la prima e risalire, che è esattamente
  /// il contrario di come si gira fra gli scaffali.
  List<Widget> _departmentRows(AppWindowSize size, List<Widget> blocks) {
    if (size.isCompact) {
      return blocks;
    }
    final gutter = AppBreakpoints.gutter(size);
    return [
      for (var index = 0; index < blocks.length; index += 2)
        Row(
          // Reparti con un numero diverso di voci: si allineano in alto.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: blocks[index]),
            SizedBox(width: gutter),
            Expanded(
              child: index + 1 < blocks.length
                  ? blocks[index + 1]
                  : const SizedBox.shrink(),
            ),
          ],
        ),
    ];
  }
}

/// Un reparto: la sua intestazione e la card con le voci da spuntare.
class _DepartmentBlock extends StatelessWidget {
  const _DepartmentBlock({
    required this.department,
    required this.checkedKeys,
    required this.onToggle,
  });

  final ShoppingListDepartment department;
  final Set<String> checkedKeys;
  final void Function(String itemKey) onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 18),
        _DepartmentHeader(department: department),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final (index, item) in department.items.indexed) ...[
                if (index > 0) const Divider(height: 1, indent: 56),
                _ShoppingItemTile(
                  item: item,
                  checked: checkedKeys.contains(item.key),
                  onChanged: () => onToggle(item.key),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Intestazione: quante voci sono già nel carrello, più copia e azzeramento.
class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.list, required this.checkedKeys});

  final ShoppingList list;
  final Set<String> checkedKeys;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final taken = list.checkedCount(checkedKeys);
    final total = list.itemCount;
    final progress = total == 0 ? 0.0 : taken / total;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ShoppingListText.dateRange(list),
              style: const TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$taken di $total presi',
              key: const Key('shopping_list_counter'),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: AppPalette.mintSoft,
                valueColor: const AlwaysStoppedAnimation(AppPalette.forest),
              ),
            ),
            const SizedBox(height: 16),
            // Pulsanti impilati e a tutta larghezza: su un telefono stretto
            // due bottoni affiancati con queste etichette non ci stanno.
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('shopping_list_copy_button'),
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copia lista'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                key: const Key('shopping_list_reset_button'),
                onPressed: taken == 0 ? null : () => _reset(context, ref),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Azzera spunte'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(
        text: ShoppingListText.format(list, checkedKeys: checkedKeys),
      ),
    );
    messenger.showSnackBar(
      const SnackBar(content: Text('Lista copiata: incollala dove vuoi.')),
    );
  }

  void _reset(BuildContext context, WidgetRef ref) {
    ref.read(shoppingChecksProvider.notifier).reset(list.planId);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Spunte azzerate: la spesa riparte.')),
    );
  }
}

class _DepartmentHeader extends StatelessWidget {
  const _DepartmentHeader({required this.department});

  final ShoppingListDepartment department;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('shopping_department_${department.department.name}'),
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              department.department.label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppPalette.forest,
              ),
            ),
          ),
          Text(
            '${department.items.length}',
            style: const TextStyle(
              color: AppPalette.mutedInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShoppingItemTile extends StatelessWidget {
  const _ShoppingItemTile({
    required this.item,
    required this.checked,
    required this.onChanged,
  });

  final ShoppingListItem item;
  final bool checked;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final note = item.quantity.note;
    final quantity = note == null
        ? item.quantity.display
        : '${item.quantity.display} · $note';

    return CheckboxListTile(
      key: Key('shopping_item_${item.key}'),
      value: checked,
      onChanged: (_) => onChanged(),
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: AppPalette.forest,
      contentPadding: const EdgeInsets.fromLTRB(8, 6, 16, 6),
      title: Text(
        item.label,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: checked ? AppPalette.mutedInk : AppPalette.ink,
          decoration: checked ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            quantity,
            style: const TextStyle(
              color: AppPalette.forest,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (item.isFullyUsed || item.isPartlyUsed)
            Text(
              item.isFullyUsed
                  ? 'Già cucinato: forse ce l’hai già'
                  : 'In parte già cucinato',
              style: const TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          if (item.recipeNames.isNotEmpty)
            Text(
              item.recipeNames.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppPalette.mutedInk, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class _MissingRecipesCard extends StatelessWidget {
  const _MissingRecipesCard({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('shopping_list_missing_recipes'),
      color: AppPalette.yellowSoft,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Qualche ricetta non c’è più',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Di ${names.join(', ')} non conosco più gli ingredienti: '
              'quel pezzo di spesa lo devi controllare a mano.',
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ancora niente da comprare',
              key: Key('shopping_list_placeholder_title'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Quando il piano sarà pronto, qui troverai gli ingredienti '
              'delle ricette scelte, già sommati e divisi per reparto.',
              style: TextStyle(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('shopping_list_plan_button'),
              onPressed: () => context.goNamed('plan'),
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Vai al piano'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      key: Key('shopping_list_loading'),
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            SizedBox(width: 14),
            Expanded(child: Text('Sto sommando gli ingredienti…')),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      key: Key('shopping_list_error'),
      color: AppPalette.coralSoft,
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Non riesco a leggere la lista',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 8),
            Text(
              'Il piano c’è, ma qualcosa è andato storto nel leggere le '
              'ricette. Riapri la schermata fra un attimo.',
              style: TextStyle(color: AppPalette.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}
