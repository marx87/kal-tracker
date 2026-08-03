# OTA e distribuzione privata

## Canali

```text
marx87/kal-tracker           repository sorgente privato
marx87/kal-tracker-releases  repository pubblico con soli binari e manifest
```

Il repository release deve essere pubblico: un’app non può incorporare un token GitHub personale per scaricare asset privati.

## Android

La prima installazione avviene scaricando manualmente l’APK firmato da GitHub Releases. Dalla seconda versione:

1. l’app scarica `kal-tracker-update.json` dalla Release più recente;
2. verifica la firma Ed25519 con la chiave pubblica incorporata;
3. controlla application ID, canale e build number;
4. scarica l’APK esclusivamente dal repository consentito;
5. verifica dimensione e SHA-256;
6. apre l’installer Android.

Android richiede comunque una conferma dell’utente e, la prima volta, l’autorizzazione “Installa app sconosciute”. Gli aggiornamenti devono essere firmati sempre dallo stesso keystore.

## iOS

GitHub può conservare un IPA, ma un’app iOS normale non può scaricarlo e sostituire autonomamente se stessa. Le opzioni sono:

- build Ad Hoc firmata per gli UDID registrati;
- TestFlight con Apple Developer Program;
- reinstallazione periodica con Personal Team, la meno pratica.

Il futuro banner iOS aprirà il canale scelto, senza simulare un aggiornamento silenzioso.

## Segreti GitHub dell’environment `release`

```text
ANDROID_KEYSTORE_BASE64
ANDROID_KEY_ALIAS
ANDROID_STORE_PASSWORD
ANDROID_KEY_PASSWORD
OTA_ED25519_PRIVATE_KEY_BASE64
RELEASES_REPO_TOKEN
```

Variabili pubbliche:

```text
OTA_PUBLIC_KEY_BASE64
ANDROID_SIGNER_SHA256
SUPABASE_URL                 facoltativa finché la sync non è attiva
SUPABASE_PUBLISHABLE_KEY     facoltativa, mai service_role
```

Il token del repository release deve avere accesso soltanto a `marx87/kal-tracker-releases`. La chiave privata OTA e il keystore APK sono chiavi diverse e devono avere backup cifrati separati.

## Prima release

1. Generare un keystore release dedicato e conservarne due backup cifrati.
2. Generare una coppia Ed25519 separata per il manifest.
3. Configurare environment, segreti e variabili GitHub.
4. Proteggere l’environment `release` con approvazione manuale.
5. Avviare `Android signed release` da GitHub Actions.
6. Installare l’APK iniziale manualmente e verificare il fingerprint.

Il workflow:

- parte soltanto da `main` e carica i segreti solo negli step di firma;
- rifiuta regressioni di versione e build number;
- verifica package, versione e certificato dell’APK;
- firma un manifest che include repository e commit sorgente;
- confronta i digest remoti di APK, manifest, checksum e provenienza prima di pubblicare;
- rimuove dal runner keystore e chiavi temporanee.

Il workflow rifiuta release senza keystore, firma OTA, fingerprint o build number validi. Non installare l’APK debug come app principale: ha un application ID separato e non riceve il canale OTA di produzione.
