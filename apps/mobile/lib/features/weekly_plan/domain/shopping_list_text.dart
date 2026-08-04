/// La lista della spesa come testo semplice, da incollare dove capita
/// (messaggio, nota, biglietto sul frigo).
///
/// Funzione pura e senza `intl`: i nomi dei mesi stanno qui perché questa
/// formattazione deve funzionare anche in un test di puro Dart, senza
/// inizializzare i dati di localizzazione.
library;

import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_builder.dart';

abstract final class ShoppingListText {
  static const List<String> months = [
    'gennaio',
    'febbraio',
    'marzo',
    'aprile',
    'maggio',
    'giugno',
    'luglio',
    'agosto',
    'settembre',
    'ottobre',
    'novembre',
    'dicembre',
  ];

  /// Testo completo della lista. [checkedKeys] sono le voci già prese.
  static String format(
    ShoppingList list, {
    Set<String> checkedKeys = const <String>{},
  }) {
    final buffer = StringBuffer()
      ..writeln('Lista della spesa')
      ..writeln(dateRange(list));

    for (final department in list.departments) {
      buffer
        ..writeln()
        ..writeln(department.department.label.toUpperCase());
      for (final item in department.items) {
        buffer.writeln(line(item, checked: checkedKeys.contains(item.key)));
      }
    }

    if (list.isEmpty) {
      buffer
        ..writeln()
        ..writeln('Non c’è niente da comprare.');
    } else {
      buffer
        ..writeln()
        ..writeln(
          'Presi ${list.checkedCount(checkedKeys)} di ${list.itemCount}.',
        );
    }

    if (list.unavailableRecipes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(
          'Ricette non più nel ricettario (ingredienti da controllare a mano): '
          '${list.unavailableRecipes.join(', ')}.',
        );
    }

    return buffer.toString().trimRight();
  }

  /// Una riga: `[x] Pomodori — 500 g`.
  static String line(ShoppingListItem item, {required bool checked}) {
    final box = checked ? '[x]' : '[ ]';
    final note = item.quantity.note;
    final quantity = note == null
        ? item.quantity.display
        : '${item.quantity.display} ($note)';
    final used = item.isFullyUsed
        ? ' · già cucinato'
        : (item.isPartlyUsed ? ' · in parte già cucinato' : '');
    return '$box ${item.label} — $quantity$used';
  }

  /// «5 - 11 agosto 2026», «28 luglio - 3 agosto 2026».
  static String dateRange(ShoppingList list) {
    final start = list.startDate;
    final end = list.endDate;
    if (start.year == end.year && start.month == end.month) {
      return '${start.day} - ${end.day} ${_month(end)} ${end.year}';
    }
    if (start.year == end.year) {
      return '${start.day} ${_month(start)} - '
          '${end.day} ${_month(end)} ${end.year}';
    }
    return '${start.day} ${_month(start)} ${start.year} - '
        '${end.day} ${_month(end)} ${end.year}';
  }

  static String _month(DateTime date) => months[date.month - 1];
}
