import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// Un file scelto per il travaso: il contenuto è già letto, perché la
/// schermata deve poterlo controllare PRIMA di scrivere qualsiasi cosa.
///
/// Nome e dimensione non sono decorazione: sono l'unico modo che ha Marco di
/// accorgersi di aver preso il file sbagliato (o quello vecchio) prima della
/// conferma.
class GymImportFile {
  const GymImportFile({
    required this.name,
    required this.contents,
    required this.sizeBytes,
  });

  final String name;
  final String contents;
  final int sizeBytes;

  /// Dimensione in italiano, con la virgola decimale.
  String get sizeLabel {
    if (sizeBytes < 1024) {
      return '$sizeBytes byte';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).round()} kB';
    }
    final megabytes = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
    return '${megabytes.replaceAll('.', ',')} MB';
  }
}

/// Errore leggibile da un umano mentre si sceglie un file: qui dentro non
/// arrivano mai eccezioni di sistema in inglese.
class GymImportFileException implements Exception {
  const GymImportFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Da dove arrivano i due file dell'import.
///
/// È un'interfaccia e non una chiamata diretta a `file_picker` perché nei
/// test il selettore di sistema non esiste: si sostituisce con un finto che
/// restituisce le fixture. In produzione ci va
/// [SystemGymImportFileGateway], che il selettore lo apre davvero.
abstract class GymImportFileGateway {
  /// Vero solo quando c'è davvero un selettore di sistema da aprire. La
  /// schermata mostra il bottone «Sfoglia» soltanto in quel caso: un bottone
  /// che non apre niente è peggio che non averlo.
  bool get canBrowse;

  /// Apre il selettore. Restituisce `null` se l'utente lo chiude senza
  /// scegliere — e anche quando [canBrowse] è falso, così una chiamata di
  /// troppo non fa esplodere niente.
  Future<GymImportFile?> browse();

  /// Legge un file dal percorso, oppure accetta direttamente il contenuto
  /// JSON incollato. Lancia [GymImportFileException] con un messaggio già
  /// scritto per essere mostrato.
  Future<GymImportFile> read(String rawInput);
}

/// Il file indicato a mano: percorso oppure contenuto incollato, senza
/// selettore di sistema.
///
/// Resta la base di [SystemGymImportFileGateway] e non un ripiego morto: sul
/// Mac e nei test il percorso digitato è il modo più rapido di puntare a un
/// file, e il contenuto incollato è l'unico che funzioni senza disco.
class LocalGymImportFileGateway implements GymImportFileGateway {
  const LocalGymImportFileGateway({this.maximumBytes = _defaultMaximumBytes});

  /// Stesso tetto del ripristino di backup: oltre questa soglia non è più il
  /// file giusto, è un errore di selezione.
  static const int _defaultMaximumBytes = 32 * 1024 * 1024;

  final int maximumBytes;

  @override
  bool get canBrowse => false;

  @override
  Future<GymImportFile?> browse() async => null;

  @override
  Future<GymImportFile> read(String rawInput) async {
    final value = rawInput.trim();
    if (value.isEmpty) {
      throw const GymImportFileException(
        'Serve il percorso del file oppure il suo contenuto.',
      );
    }

    // Un JSON incollato comincia per graffa: non è un percorso, è già il
    // contenuto. Vale per l'export e per il dump allo stesso modo.
    if (value.startsWith('{')) {
      return GymImportFile(
        name: 'contenuto incollato',
        contents: value,
        sizeBytes: utf8.encode(value).length,
      );
    }

    final file = File(value);
    if (!file.existsSync()) {
      throw GymImportFileException('Non trovo nessun file in «$value».');
    }
    final size = await file.length();
    if (size > maximumBytes) {
      throw GymImportFileException(
        'Il file pesa ${GymImportFile(name: '', contents: '', sizeBytes: size).sizeLabel}: '
        'troppo per essere un export di Gym Tracker.',
      );
    }
    try {
      return GymImportFile(
        name: _basename(value),
        contents: await file.readAsString(),
        sizeBytes: size,
      );
    } on FileSystemException {
      throw GymImportFileException(
        'Non riesco a leggere «${_basename(value)}».',
      );
    }
  }

  static String _basename(String path) {
    final parts = path.split(Platform.pathSeparator);
    final last = parts.isEmpty ? path : parts.last;
    return last.isEmpty ? path : last;
  }
}

/// Chi apre davvero il selettore. È un parametro e non una chiamata diretta
/// perché `FilePicker` passa da un canale nativo che nei test non esiste:
/// iniettandolo, la traduzione «file scelto → [GymImportFile]» si prova per
/// davvero invece di restare l'unico pezzo non coperto.
typedef GymFilePicker = Future<PlatformFile?> Function();

/// Il selettore di sistema.
///
/// Eredita da [LocalGymImportFileGateway] perché il percorso digitato a mano
/// deve continuare a funzionare anche quando il selettore c'è: sul Mac è più
/// veloce, e nei test è l'unica strada.
class SystemGymImportFileGateway extends LocalGymImportFileGateway {
  const SystemGymImportFileGateway({
    super.maximumBytes,
    this.picker = pickGymFileWithSystemPicker,
  });

  final GymFilePicker picker;

  @override
  bool get canBrowse => true;

  @override
  Future<GymImportFile?> browse() async {
    final PlatformFile? picked;
    try {
      picked = await picker();
    } on Object catch (error) {
      // Il selettore può mancare (piattaforma senza plugin) o essere negato:
      // in entrambi i casi Marco deve leggere una frase, non un'eccezione.
      throw GymImportFileException(
        'Non riesco ad aprire il selettore di file: $error',
      );
    }
    if (picked == null) {
      // Chiuso senza scegliere: non è un errore.
      return null;
    }

    final path = picked.path;
    if (path != null) {
      // Con un percorso si passa dalla lettura già collaudata: stesso tetto
      // di dimensione, stessi messaggi d'errore, un solo posto da correggere.
      return read(path);
    }

    // Senza percorso resta il contenuto in memoria. Su Android e iOS non
    // capita (il plugin copia sempre il file in cache), ma se capitasse
    // fermarsi qui sarebbe peggio che leggere i byte che abbiamo già.
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.length > maximumBytes) {
        throw GymImportFileException(
          'Il file pesa '
          '${GymImportFile(name: '', contents: '', sizeBytes: bytes.length).sizeLabel}: '
          'troppo per essere un export di Gym Tracker.',
        );
      }
      return GymImportFile(
        name: picked.name,
        contents: utf8.decode(bytes),
        sizeBytes: bytes.length,
      );
    } on GymImportFileException {
      rethrow;
    } on FormatException {
      throw GymImportFileException(
        '«${picked.name}» non è un file di testo: l\'export di Gym Tracker è '
        'un JSON.',
      );
    } on Object {
      throw GymImportFileException(
        'Non riesco a leggere «${picked.name}»: prova a incollarne il '
        'percorso.',
      );
    }
  }
}

/// Il selettore vero.
///
/// Nessun filtro per estensione di proposito: su Android i JSON arrivano dai
/// Download con tipi MIME diversi da `application/json`, e filtrando si
/// vedrebbero grigi e non selezionabili proprio i file che servono. Che dentro
/// ci sia un export di Gym lo dice poi la lettura, con una frase in italiano.
Future<PlatformFile?> pickGymFileWithSystemPicker() =>
    FilePicker.pickFile(dialogTitle: 'Scegli il file di Gym Tracker');
