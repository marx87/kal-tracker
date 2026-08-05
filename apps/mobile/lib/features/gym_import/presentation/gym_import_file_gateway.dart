import 'dart:convert';
import 'dart:io';

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
/// È un'interfaccia e non una chiamata diretta a `file_picker` perché quel
/// pacchetto NON è fra le dipendenze di questo progetto (vedi `pubspec.yaml`:
/// ci sono `image_picker`, `open_file` e `mobile_scanner`, non lui). Con la
/// dipendenza aggiunta basta scrivere un'implementazione che apra il
/// selettore di sistema e sostituirla nel provider: la schermata non cambia
/// di una riga, perché già oggi chiede a [canBrowse] se il selettore esiste.
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

/// L'implementazione di serie: niente selettore di sistema, si passa dal
/// percorso o dal contenuto incollato. È lo stesso patto della schermata di
/// backup (`readRestoreSource`), quindi è un gesto che Marco conosce già.
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
