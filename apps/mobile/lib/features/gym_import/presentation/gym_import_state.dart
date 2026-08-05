import 'package:kal_tracker/features/gym_import/domain/gym_import_report.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_file_gateway.dart';

/// I tre passi del travaso, nell'ordine in cui avvengono.
///
/// Servono alla barra di avanzamento e sono volutamente pochi: l'importer non
/// espone un progresso riga per riga, quindi promettere una percentuale
/// sarebbe una bugia. Il passo, invece, è vero.
enum GymImportStep {
  reading('Leggo i file', 1),
  previewing('Provo l\'import a vuoto', 2),
  writing('Scrivo nel diario', 3);

  const GymImportStep(this.label, this.number);

  /// Cosa sta succedendo, in italiano.
  final String label;

  /// Posizione nella sequenza, da 1 a [total].
  final int number;

  static const int total = 3;
}

/// Un file scelto e già decodificato.
///
/// Il JSON si legge una volta sola, quando il file entra: se è illeggibile lo
/// si scopre subito, non dopo aver premuto «Importa».
class GymImportSource {
  const GymImportSource({required this.file, required this.document});

  final GymImportFile file;
  final Map<String, Object?> document;
}

/// Tutto ciò che la schermata di import deve sapere.
///
/// [preview] e [result] sono lo stesso tipo ma NON la stessa cosa: il primo è
/// il rendiconto di una prova annullata, il secondo di una scrittura vera.
/// Tenerli separati è ciò che permette alla schermata di non confondere «sta
/// per entrare» con «è entrato».
class GymImportState {
  const GymImportState({
    this.exportSource,
    this.dumpSource,
    this.step,
    this.preview,
    this.result,
    this.error,
  });

  /// L'export dell'app: obbligatorio.
  final GymImportSource? exportSource;

  /// Il dump Firestore: facoltativo, aggiunge ciò che l'export non scriveva.
  final GymImportSource? dumpSource;

  /// Non nullo solo mentre l'import sta lavorando.
  final GymImportStep? step;

  /// Rendiconto della prova a vuoto: dice cosa entrerebbe, senza aver scritto.
  final GymImportReport? preview;

  /// Rendiconto della scrittura vera.
  final GymImportReport? result;

  /// Messaggio di errore già scritto per essere letto da un umano.
  final String? error;

  bool get isBusy => step != null;

  bool get hasExport => exportSource != null;

  /// La prova a vuoto si può lanciare solo con l'export scelto e solo prima
  /// della scrittura: dopo, il rendiconto vero ha la precedenza.
  bool get canPreview => hasExport && !isBusy && result == null;

  /// C'è un'anteprima con qualcosa dentro: è il momento della conferma.
  bool get awaitsConfirmation =>
      result == null && !isBusy && preview != null && !preview!.isNoop;

  /// L'anteprima dice che non c'è niente di nuovo: è la prova che l'import è
  /// idempotente, non un errore.
  bool get previewIsNoop =>
      result == null && preview != null && preview!.isNoop;

  GymImportState copyWith({
    GymImportSource? exportSource,
    GymImportSource? dumpSource,
    GymImportStep? step,
    GymImportReport? preview,
    GymImportReport? result,
    String? error,
    bool clearDump = false,
    bool clearStep = false,
    bool clearPreview = false,
    bool clearResult = false,
    bool clearError = false,
  }) {
    return GymImportState(
      exportSource: exportSource ?? this.exportSource,
      dumpSource: clearDump ? null : (dumpSource ?? this.dumpSource),
      step: clearStep ? null : (step ?? this.step),
      preview: clearPreview ? null : (preview ?? this.preview),
      result: clearResult ? null : (result ?? this.result),
      error: clearError ? null : (error ?? this.error),
    );
  }
}
