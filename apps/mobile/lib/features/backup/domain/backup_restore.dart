enum BackupRestoreMode {
  merge(
    'merge',
    'Unisci',
    'Aggiunge quello che manca e aggiorna solo le voci più recenti del '
        'backup. Non cancella niente.',
  ),
  replace(
    'replace',
    'Sostituisci',
    'Cancella i dati di adesso e rimette esattamente quelli del backup. '
        'Da usare su un telefono nuovo.',
  );

  const BackupRestoreMode(this.storageValue, this.label, this.description);

  final String storageValue;
  final String label;
  final String description;
}

class BackupRestoreSummary {
  const BackupRestoreSummary({
    required this.mode,
    required this.created,
    required this.updated,
    required this.skipped,
  });

  final BackupRestoreMode mode;
  final int created;
  final int updated;
  final int skipped;

  int get total => created + updated + skipped;

  String get message =>
      'Ripristino completato: $created voci nuove, $updated aggiornate, '
      '$skipped lasciate come stavano.';
}
