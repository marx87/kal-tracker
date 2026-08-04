/// Costruzione della lista della spesa dal piano settimanale.
///
/// È una funzione PURA: piano + ingredienti reali delle ricette → lista
/// raggruppata per reparto. Niente database, niente Flutter, niente rete, così
/// il calcolo si prova a tavolino.
///
/// Regole decise qui, una volta sola:
///  * i grammi di uno slot sono `ingrediente.grams * porzioni / porzioniRicetta`
///    (le porzioni frazionarie del piano scalano tutto, mezza porzione = metà
///    ingredienti);
///  * gli slot già segnati "Fatto" RESTANO nella lista, marcati come già
///    usati. Marco potrebbe aver già comprato quella roba, ma potrebbe anche
///    aver cucinato con quello che aveva in casa: toglierli d'ufficio farebbe
///    tornare dal supermercato senza mezza spesa. La riga dice quanto di quel
///    totale è già stato consumato, e la decisione resta a lui (c'è la spunta);
///  * una ricetta cancellata dopo la generazione non inventa ingredienti: il
///    suo nome finisce in [ShoppingList.unavailableRecipes] e la schermata lo
///    dice apertamente.
library;

import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_departments.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_quantity.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_text.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

/// Una riga della spesa: un alimento, i suoi grammi e il reparto.
class ShoppingListItem {
  ShoppingListItem({
    required this.key,
    required this.label,
    required this.department,
    required this.grams,
    required this.usedGrams,
    required this.quantity,
    Iterable<String> recipeNames = const <String>[],
  }) : recipeNames = List.unmodifiable(recipeNames);

  /// Chiave normalizzata: identità della riga e id stabile delle spunte.
  final String key;

  /// Nome da mostrare (la grafia più usata fra le ricette del piano).
  final String label;

  final ShoppingDepartment department;

  /// Grammi totali richiesti dal piano.
  final double grams;

  /// Parte dei grammi che arriva da slot già segnati "Fatto".
  final double usedGrams;

  final ShoppingQuantity quantity;

  /// Ricette del piano che lo usano, in ordine alfabetico.
  final List<String> recipeNames;

  /// Tutto quello che serviva è già stato cucinato.
  bool get isFullyUsed => grams > 0 && usedGrams >= grams - _tolerance;

  /// Una parte è già stata cucinata, ma non tutta.
  bool get isPartlyUsed => usedGrams > _tolerance && !isFullyUsed;

  static const double _tolerance = 0.01;
}

/// Le righe di un reparto.
class ShoppingListDepartment {
  ShoppingListDepartment({
    required this.department,
    required Iterable<ShoppingListItem> items,
  }) : items = List.unmodifiable(items);

  final ShoppingDepartment department;
  final List<ShoppingListItem> items;
}

/// La lista della spesa completa di un piano.
class ShoppingList {
  ShoppingList({
    required this.planId,
    required DateTime startDate,
    required this.days,
    required Iterable<ShoppingListDepartment> departments,
    Iterable<String> unavailableRecipes = const <String>[],
  }) : startDate = PlanDate.normalize(startDate),
       departments = List.unmodifiable(departments),
       unavailableRecipes = List.unmodifiable(unavailableRecipes);

  final String planId;
  final DateTime startDate;
  final int days;

  /// Reparti non vuoti, nell'ordine del giro fra i banchi.
  final List<ShoppingListDepartment> departments;

  /// Ricette del piano di cui non si conoscono più gli ingredienti.
  final List<String> unavailableRecipes;

  /// Tutte le righe, nell'ordine in cui si mostrano.
  List<ShoppingListItem> get items => List.unmodifiable([
    for (final department in departments) ...department.items,
  ]);

  int get itemCount => items.length;

  bool get isEmpty => departments.isEmpty;

  DateTime get endDate => PlanDate.addDays(startDate, days - 1);

  /// Quante righe della lista risultano spuntate, ignorando le spunte
  /// rimaste appese a voci che non esistono più.
  int checkedCount(Set<String> checkedKeys) =>
      items.where((item) => checkedKeys.contains(item.key)).length;
}

abstract final class ShoppingListBuilder {
  /// Somma gli ingredienti di tutte le ricette del piano.
  ///
  /// [recipes] è indicizzata per id ricetta: quello che manca non viene
  /// inventato, viene dichiarato.
  static ShoppingList build({
    required WeeklyPlan plan,
    required Map<String, FitRecipeDetails> recipes,
  }) {
    final totals = <String, _Accumulator>{};
    final unavailable = <String>[];

    for (final slot in plan.slots) {
      final recipeId = slot.recipeId;
      final details = recipeId == null ? null : recipes[recipeId];
      if (details == null) {
        if (!unavailable.contains(slot.recipeName)) {
          unavailable.add(slot.recipeName);
        }
        continue;
      }
      final servings = details.summary.servings;
      if (servings <= 0) {
        continue;
      }
      final factor = slot.servings / servings;
      for (final ingredient in details.ingredients) {
        final grams = ingredient.grams * factor;
        if (!grams.isFinite || grams <= 0) {
          continue;
        }
        final key = ShoppingText.ingredientKey(ingredient.name);
        if (key.isEmpty) {
          continue;
        }
        (totals[key] ??= _Accumulator(key)).add(
          label: ingredient.name.trim(),
          grams: grams,
          recipeName: details.summary.name,
          done: slot.isDone,
        );
      }
    }

    final byDepartment = <ShoppingDepartment, List<ShoppingListItem>>{};
    for (final accumulator in totals.values) {
      final item = accumulator.toItem();
      byDepartment.putIfAbsent(item.department, () => []).add(item);
    }

    final departments = <ShoppingListDepartment>[];
    for (final department in ShoppingDepartment.values) {
      final items = byDepartment[department];
      if (items == null || items.isEmpty) {
        continue;
      }
      items.sort((first, second) => first.key.compareTo(second.key));
      departments.add(
        ShoppingListDepartment(department: department, items: items),
      );
    }

    return ShoppingList(
      planId: plan.id,
      startDate: plan.startDate,
      days: plan.days,
      departments: departments,
      unavailableRecipes: unavailable,
    );
  }
}

/// Somma parziale di un ingrediente mentre si scorre il piano.
class _Accumulator {
  _Accumulator(this.key);

  final String key;
  final Map<String, int> _labels = {};
  final Set<String> _recipeNames = {};
  double grams = 0;
  double usedGrams = 0;

  void add({
    required String label,
    required double grams,
    required String recipeName,
    required bool done,
  }) {
    if (label.isNotEmpty) {
      _labels[label] = (_labels[label] ?? 0) + 1;
    }
    _recipeNames.add(recipeName);
    this.grams += grams;
    if (done) {
      usedGrams += grams;
    }
  }

  /// Etichetta: la grafia più usata; a pari merito la più corta e poi la
  /// prima in ordine alfabetico, così il risultato non dipende dall'ordine
  /// con cui il piano è stato letto.
  String get label {
    if (_labels.isEmpty) {
      return key;
    }
    final entries = _labels.entries.toList()
      ..sort((first, second) {
        final byCount = second.value.compareTo(first.value);
        if (byCount != 0) {
          return byCount;
        }
        final byLength = first.key.length.compareTo(second.key.length);
        return byLength != 0 ? byLength : first.key.compareTo(second.key);
      });
    return entries.first.key;
  }

  ShoppingListItem toItem() {
    final name = label;
    final recipeNames = _recipeNames.toList()..sort();
    return ShoppingListItem(
      key: key,
      label: name,
      department: ShoppingDepartments.classify(name),
      grams: grams,
      usedGrams: usedGrams,
      quantity: ShoppingQuantities.format(name: name, grams: grams),
      recipeNames: recipeNames,
    );
  }
}
