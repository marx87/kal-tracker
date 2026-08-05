import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/gym_import/data/gym_tracker_importer.dart';
import 'package:kal_tracker/features/gym_import/domain/gym_import_report.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_file_gateway.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_state.dart';

/// Come si arriva ai due file. Nei test si sostituisce con un finto che
/// restituisce le fixture, senza toccare il disco.
final gymImportFileGatewayProvider = Provider<GymImportFileGateway>(
  (ref) => const LocalGymImportFileGateway(),
);

final gymTrackerImporterProvider = Provider<GymTrackerImporter>(
  (ref) => GymTrackerImporter(ref.watch(databaseProvider)),
);

final gymImportControllerProvider =
    NotifierProvider<GymImportController, GymImportState>(
      GymImportController.new,
    );

/// Il regista del travaso: sceglie i file, prova a vuoto, e solo dopo una
/// conferma esplicita scrive.
///
/// La prova a vuoto non è una stima: fa girare l'import VERO dentro una
/// transazione annullata, quindi i numeri che Marco vede prima di confermare
/// sono esattamente quelli che entreranno, avvisi compresi.
class GymImportController extends Notifier<GymImportState> {
  /// Riverpod 2 non ha `ref.mounted`: se la schermata viene chiusa mentre
  /// l'import scrive, assegnare `state` lancerebbe. L'import in corso invece
  /// arriva in fondo da solo — è dentro una transazione, non lascia mezzo
  /// storico dentro.
  bool _disposed = false;

  @override
  GymImportState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const GymImportState();
  }

  GymImportFileGateway get gateway => ref.read(gymImportFileGatewayProvider);

  /// Vero quando esiste un selettore di sistema: la schermata usa questo per
  /// decidere se «Scegli» apre il selettore o il foglio del percorso.
  bool get canBrowse => gateway.canBrowse;

  Future<void> browseExport() =>
      _adopt(isDump: false, load: () => gateway.browse());

  Future<void> browseDump() =>
      _adopt(isDump: true, load: () => gateway.browse());

  Future<void> useExportSource(String rawInput) =>
      _adopt(isDump: false, load: () => gateway.read(rawInput));

  Future<void> useDumpSource(String rawInput) =>
      _adopt(isDump: true, load: () => gateway.read(rawInput));

  /// Toglie il dump. Restituisce quello che c'era, così la schermata può
  /// offrire «Annulla» invece di far rifare la scelta.
  GymImportSource? removeDump() {
    final removed = state.dumpSource;
    if (removed == null) {
      return null;
    }
    _emit(
      state.copyWith(clearDump: true, clearPreview: true, clearError: true),
    );
    return removed;
  }

  /// Rimette il dump tolto per sbaglio.
  void restoreDump(GymImportSource source) {
    _emit(
      state.copyWith(dumpSource: source, clearPreview: true, clearError: true),
    );
  }

  /// Prova a vuoto: scrive davvero e poi annulla tutto, così il rendiconto
  /// mostrato prima della conferma è quello vero e non una stima.
  Future<void> preview() async {
    if (!state.canPreview) {
      return;
    }
    _emit(
      state.copyWith(
        step: GymImportStep.previewing,
        clearPreview: true,
        clearError: true,
      ),
    );
    await _guard((profileId) async {
      final report = await _rollback(() => _importOnce(profileId));
      _emit(state.copyWith(clearStep: true, preview: report));
    });
  }

  /// La scrittura vera. Si può chiedere solo dopo aver visto l'anteprima:
  /// è il principio dell'app, propone la macchina e conferma Marco.
  Future<void> confirm() async {
    if (!state.awaitsConfirmation) {
      return;
    }
    _emit(state.copyWith(step: GymImportStep.writing, clearError: true));
    await _guard((profileId) async {
      final report = await _importOnce(profileId);
      _emit(
        state.copyWith(clearStep: true, clearPreview: true, result: report),
      );
    });
  }

  /// Rimette la schermata da capo, file compresi.
  void startOver() => _emit(const GymImportState());

  /// Dimentica l'anteprima e torna alla scelta dei file, senza perderli.
  void backToFiles() =>
      _emit(state.copyWith(clearPreview: true, clearError: true));

  Future<void> _adopt({
    required bool isDump,
    required Future<GymImportFile?> Function() load,
  }) async {
    if (state.isBusy) {
      return;
    }
    _emit(
      state.copyWith(
        step: GymImportStep.reading,
        // Un file nuovo rende falsi sia l'anteprima sia il rendiconto
        // precedente: sparire è meglio che restare a mentire.
        clearPreview: true,
        clearResult: true,
        clearError: true,
      ),
    );
    try {
      final file = await load();
      if (file == null) {
        // Selettore chiuso senza scegliere: non è un errore, non si dice
        // niente.
        _emit(state.copyWith(clearStep: true));
        return;
      }
      final source = GymImportSource(file: file, document: _decode(file));
      _emit(
        state.copyWith(
          exportSource: isDump ? null : source,
          dumpSource: isDump ? source : null,
          clearStep: true,
        ),
      );
    } on GymImportFileException catch (error) {
      _emit(state.copyWith(clearStep: true, error: error.message));
    }
  }

  Map<String, Object?> _decode(GymImportFile file) {
    final Object? decoded;
    try {
      decoded = jsonDecode(file.contents);
    } on FormatException {
      throw GymImportFileException(
        '«${file.name}» non è un file JSON leggibile.',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw GymImportFileException(
        '«${file.name}» è un JSON, ma dentro non c\'è un documento: '
        'l\'export di Gym Tracker comincia con una graffa.',
      );
    }
    return decoded;
  }

  Future<GymImportReport> _importOnce(String profileId) {
    final export = state.exportSource!;
    // `enqueueSync` resta al suo falso di serie: `SyncPushMapper` non conosce
    // ancora schede, esercizi e sessioni, e accodarle svuoterebbe la coda
    // senza mandare niente. La schermata lo dice invece di nasconderlo.
    return ref
        .read(gymTrackerImporterProvider)
        .importExport(
          profileId: profileId,
          export: export.document,
          firestoreDump: state.dumpSource?.document,
        );
  }

  /// Fa girare [body] dentro una transazione che viene SEMPRE annullata.
  ///
  /// In Drift l'unico modo di annullare una transazione è uscirne con
  /// un'eccezione: qui non segnala un guasto, è il punto della prova a vuoto.
  Future<GymImportReport> _rollback(
    Future<GymImportReport> Function() body,
  ) async {
    final database = ref.read(databaseProvider);
    try {
      // La transazione non torna mai normalmente: o esce con il rendiconto
      // dentro _PreviewDone, o esce con l'errore dell'import. In entrambi i
      // casi Drift ha già annullato tutto.
      await database.transaction(() async {
        throw _PreviewDone(await body());
      });
    } on _PreviewDone catch (signal) {
      return signal.report;
    }
  }

  /// Traduce in italiano tutto ciò che può andare storto, e non lascia mai la
  /// schermata bloccata sul passo in corso.
  ///
  /// Il profilo si risolve QUI, fuori dalla transazione della prova a vuoto:
  /// `getOrCreateMarco` lo crea se manca, e crearlo dentro una transazione
  /// annullata lascerebbe in cache un profileId che nel database non esiste —
  /// la scrittura vera fallirebbe poi sulla chiave esterna.
  Future<void> _guard(Future<void> Function(String profileId) body) async {
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await body(profile.id);
    } on FormatException catch (error) {
      // I controlli dell'importer parlano già italiano: «Questo file non è un
      // export di Gym Tracker», «la sessione X finisce prima di iniziare».
      _emit(state.copyWith(clearStep: true, error: error.message));
    } on GymImportFileException catch (error) {
      _emit(state.copyWith(clearStep: true, error: error.message));
    } on Object catch (error) {
      _emit(
        state.copyWith(
          clearStep: true,
          error: 'L\'import si è fermato e non ha scritto niente: $error',
        ),
      );
    }
  }

  void _emit(GymImportState next) {
    if (_disposed) {
      return;
    }
    state = next;
  }
}

/// Segnale interno: porta fuori il rendiconto annullando la transazione.
class _PreviewDone implements Exception {
  const _PreviewDone(this.report);

  final GymImportReport report;
}
