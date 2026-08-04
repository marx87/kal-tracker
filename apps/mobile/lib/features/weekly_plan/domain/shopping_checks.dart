/// Le spunte della lista della spesa.
///
/// Non è un dato del piano: è un promemoria di quello che è già finito nel
/// carrello. Per questo NON vive nel database (niente tabelle nuove, niente
/// sync) ma in un file JSON accanto alle altre preferenze locali, esattamente
/// come le impostazioni acqua e lo stato del backup.
///
/// Si ricorda un piano solo: quando arriva un piano nuovo la spesa ricomincia
/// da zero, che è anche quello che succede nella realtà.
library;

class ShoppingChecks {
  ShoppingChecks({this.planId, Iterable<String> checked = const <String>[]})
    : checked = Set.unmodifiable({
        for (final key in checked)
          if (key.trim().isNotEmpty) key.trim(),
      });

  const ShoppingChecks.empty() : planId = null, checked = const <String>{};

  /// Lettura indulgente: qualsiasi cosa storta torna [ShoppingChecks.empty].
  factory ShoppingChecks.fromJson(Object? value) {
    if (value is! Map) {
      return const ShoppingChecks.empty();
    }
    final planId = value['plan_id'];
    final checked = value['checked'];
    if (planId is! String || planId.trim().isEmpty) {
      return const ShoppingChecks.empty();
    }
    return ShoppingChecks(
      planId: planId.trim(),
      checked: checked is List ? checked.whereType<String>() : const <String>[],
    );
  }

  /// Piano a cui appartengono le spunte (null = nessuna spesa in corso).
  final String? planId;

  /// Chiavi delle voci già prese ([ShoppingListItem.key]).
  final Set<String> checked;

  bool isChecked(String planId, String key) =>
      this.planId == planId && checked.contains(key);

  /// Le spunte del piano richiesto: quelle di un piano vecchio non contano.
  Set<String> forPlan(String planId) =>
      this.planId == planId ? checked : const <String>{};

  ShoppingChecks toggled({required String planId, required String key}) {
    final current = {...forPlan(planId)};
    if (!current.remove(key)) {
      current.add(key);
    }
    return ShoppingChecks(planId: planId, checked: current);
  }

  ShoppingChecks clearedFor(String planId) =>
      ShoppingChecks(planId: planId, checked: const <String>[]);

  Map<String, Object?> toJson() => {
    'plan_id': planId,
    'checked': checked.toList()..sort(),
  };

  @override
  bool operator ==(Object other) =>
      other is ShoppingChecks &&
      other.planId == planId &&
      other.checked.length == checked.length &&
      other.checked.containsAll(checked);

  @override
  int get hashCode => Object.hash(planId, checked.length);
}

/// Persistenza delle spunte. Interfaccia minima: i test usano un fake in
/// memoria e la schermata non tocca mai il filesystem.
abstract class ShoppingChecksStore {
  Future<ShoppingChecks> read();

  Future<void> write(ShoppingChecks checks);
}
