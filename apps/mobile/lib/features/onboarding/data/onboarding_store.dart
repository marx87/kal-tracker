import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Quello che l'app ricorda del primo avvio.
///
/// Due informazioni, non una: *quando* la domanda è stata fatta, e se il
/// ricordo si è potuto leggere. La seconda sembra pedante e invece decide il
/// comportamento — un file mancante significa «non ho ancora chiesto», un
/// archivio irraggiungibile significa «non ho dove segnarlo», e sono due cose
/// opposte. Confonderle vorrebbe dire riproporre il benvenuto a ogni avvio a
/// chi lo ha già saltato.
@immutable
class OnboardingMemory {
  const OnboardingMemory({required this.readable, this.askedAt});

  /// Non ho mai chiesto niente, ma so dove segnarlo.
  static const fresh = OnboardingMemory(readable: true);

  /// Non so nemmeno dove segnarlo: meglio non chiedere.
  static const unreadable = OnboardingMemory(readable: false);

  final bool readable;

  /// Quando la domanda è stata posta — compilata o saltata, non fa
  /// differenza: è stata fatta.
  final DateTime? askedAt;

  @override
  bool operator ==(Object other) =>
      other is OnboardingMemory &&
      other.readable == readable &&
      other.askedAt == askedAt;

  @override
  int get hashCode => Object.hash(readable, askedAt);
}

/// Ricordo del primo avvio.
///
/// Vive in un file JSON accanto al database e non in una tabella perché non è
/// un dato di Marco, è un dato dell'installazione. Sincronizzarlo sarebbe
/// perfino dannoso: un telefono nuovo deve poter chiedere l'altezza anche se
/// sul vecchio la domanda era stata saltata.
abstract class OnboardingStore {
  Future<OnboardingMemory> read();

  Future<void> markAsked(DateTime moment);
}

/// Store su file JSON nella directory di supporto dell'app.
///
/// Stessa regola degli altri store su file: letture indulgenti, scritture
/// best-effort, mai un crash. Un file rovinato vale come «mai chiesto» — il
/// benvenuto ricompare una volta, e la prima risposta lo rimette a posto.
class FileOnboardingStore implements OnboardingStore {
  FileOnboardingStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'coach360-onboarding.json';

  /// Versione del documento: se un domani ci finisse dentro dell'altro, un
  /// file vecchio deve restare leggibile invece di far ricomparire il
  /// benvenuto a chi ha già risposto.
  static const int documentVersion = 1;

  final Future<Directory> Function() _directory;

  @override
  Future<OnboardingMemory> read() async {
    final File file;
    try {
      file = await _file();
    } on Object {
      // Qui fallisce `path_provider`: non c'è archivio, non c'è domanda.
      return OnboardingMemory.unreadable;
    }
    try {
      if (!file.existsSync()) {
        return OnboardingMemory.fresh;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return OnboardingMemory.fresh;
      }
      final raw = decoded['askedAt'];
      if (raw is! String) {
        return OnboardingMemory.fresh;
      }
      return OnboardingMemory(
        readable: true,
        askedAt: DateTime.tryParse(raw)?.toUtc(),
      );
    } on Object {
      // Il file c'è ma è illeggibile: la cartella però esiste, quindi la
      // risposta si potrà riscrivere.
      return OnboardingMemory.fresh;
    }
  }

  @override
  Future<void> markAsked(DateTime moment) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'version': documentVersion,
          'askedAt': moment.toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } on Object {
      // Best effort: se non si scrive, il benvenuto tornerà al prossimo
      // avvio. Meglio una domanda ripetuta che un'app che non parte.
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

/// Store in memoria, per i test e per chi vuole provare la schermata senza
/// toccare il disco.
class InMemoryOnboardingStore implements OnboardingStore {
  InMemoryOnboardingStore({this.askedAt, this.readable = true});

  final bool readable;

  /// Pubblico e mutabile: i test lo leggono per verificare che «lo faccio
  /// dopo» abbia davvero lasciato un segno.
  DateTime? askedAt;

  @override
  Future<OnboardingMemory> read() async =>
      OnboardingMemory(readable: readable, askedAt: askedAt);

  @override
  Future<void> markAsked(DateTime moment) async => askedAt = moment.toUtc();
}
