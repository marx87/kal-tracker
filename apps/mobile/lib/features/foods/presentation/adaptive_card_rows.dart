import 'package:flutter/material.dart';

/// Una riga di una griglia di card, con celle di pari larghezza.
///
/// La usano il catalogo alimenti e il ricettario, che sono elenchi di card e
/// non testo da leggere: su un tablet una colonna sola centrata lascerebbe
/// metà schermo vuoto senza mostrare un alimento in più, mentre due o tre
/// colonne fanno vedere il doppio o il triplo del catalogo. La larghezza
/// leggibile qui è quella della singola card, non quella della pagina.
///
/// Non è una [GridView] perché queste card hanno altezze diverse (un nome che
/// va a capo, una descrizione che a volte manca): con [IntrinsicHeight] le
/// compagne di riga si allineano da sole e non c'è nessuna altezza fissa da
/// indovinare — che è poi il numero che si rompe al primo ingrandimento del
/// testo di sistema.
class AdaptiveCardRow extends StatelessWidget {
  const AdaptiveCardRow({
    required this.rowIndex,
    required this.itemCount,
    required this.columns,
    required this.gutter,
    required this.itemBuilder,
    super.key,
  });

  /// Indice della riga, non della card: la card la calcola questa classe.
  final int rowIndex;

  /// Quante card ci sono in tutto l'elenco.
  final int itemCount;

  /// Colonne da tenere: di norma `AppBreakpoints.columns(size)`.
  final int columns;

  /// Spazio tra una colonna e l'altra: `AppBreakpoints.gutter(size)`.
  final double gutter;

  /// Costruisce la card con l'indice dell'elenco originale, così chi chiama
  /// non deve rifare i conti tra riga e posizione.
  final IndexedWidgetBuilder itemBuilder;

  /// Quante righe servono per [itemCount] card: da passare all'`itemCount` di
  /// una lista pigra, che così continua a costruire solo il visibile.
  static int rowCount(int itemCount, int columns) =>
      columns <= 1 ? itemCount : (itemCount + columns - 1) ~/ columns;

  @override
  Widget build(BuildContext context) {
    // Su telefono la riga è la card: niente Row, niente IntrinsicHeight, il
    // comportamento resta identico a prima.
    if (columns <= 1) {
      return itemBuilder(context, rowIndex);
    }

    final cells = <Widget>[];
    for (var column = 0; column < columns; column++) {
      if (column > 0) {
        cells.add(SizedBox(width: gutter));
      }
      final index = rowIndex * columns + column;
      // Le celle avanzate nell'ultima riga restano vuote ma occupano il loro
      // posto: senza, l'ultima card si allargherebbe da sola su tutta la riga
      // e sembrerebbe un errore di allineamento.
      cells.add(
        Expanded(
          child: index < itemCount
              ? itemBuilder(context, index)
              : const SizedBox.shrink(),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: cells,
      ),
    );
  }
}
