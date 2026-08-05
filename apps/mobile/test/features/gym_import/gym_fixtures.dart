import 'dart:convert';
import 'dart:io';

/// Le due sorgenti del travaso, derivate da quelle vere con
/// `scripts/anonymize_gym_fixtures.py`.
///
/// I conteggi — 29 sessioni, 308 esercizi, 14 schede, 628 serie — e i casi
/// limite (la sessione rimasta aperta 536 ore, le nove sessioni orfane, le
/// catene di superserie) non si inventano con un campione finto, quindi le
/// fixture conservano struttura, date, identificatori e ogni anomalia reale.
///
/// Sono invece sostituiti i valori personali — peso corporeo, circonferenze,
/// carichi sollevati, note libere e gli UID Firebase — perché questo
/// repository è pubblico e quelli sono dati sanitari di una persona
/// identificabile. I file veri restano fuori dal repository.
const String exportPath =
    'test/features/gym_import/fixtures/'
    'gym-tracker-export.json';

const String dumpPath =
    'test/features/gym_import/fixtures/'
    'gym-firestore-dump.json';

/// L'utente vero: gli altri due UID del dump hanno solo schede di esempio.
const String fixtureFirestoreUserId = 'utente-di-prova-23d1a34a71aa324ed317';

Map<String, Object?> loadGymExport() => _readJson(exportPath);

Map<String, Object?> loadFirestoreDump() => _readJson(dumpPath);

/// Rilegge e riparsa a ogni chiamata: i test che sporcano il JSON per provare
/// i casi rotti non devono contaminare quelli che vengono dopo.
Map<String, Object?> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
