# OTA e distribuzione privata

## Canali

```text
marx87/kal-tracker           repository sorgente privato
marx87/kal-tracker-releases  repository pubblico con soli binari e manifest
```

Il repository release deve essere pubblico: un’app non può incorporare un token GitHub personale per scaricare asset privati.

> L’APK `kal-tracker-debug-apk` prodotto dalla CI serve soltanto per provare l’interfaccia. Usa
> `it.marcomartelli.kaltracker.debug`, può convivere con la release, ma **non può ricevere gli OTA
> di produzione**. Il test reale deve iniziare dall’APK firmato `v0.1.0`.

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

Nel repository pubblico abilitare anche le **release immutabili**, se l’opzione è disponibile. Il
workflow pubblica prima una draft, confronta i digest restituiti da GitHub e la rende pubblica solo
dopo la verifica; l’immutabilità impedisce poi sostituzioni manuali degli asset.

## 1. Generazione locale sicura

La generazione è intenzionalmente separata da GitHub. Lo script:

- richiede una directory assoluta, nuova, persistente ed esterna al repository;
- non sovrascrive file e usa permessi `700` sulla directory e `600` su ogni file;
- non mette password nella riga di comando di `keytool`;
- verifica keystore, fingerprint e una firma Ed25519 di prova;
- non stampa segreti, non legge il login `gh` e non contatta GitHub.

Sul Mac, creare prima soltanto la directory padre:

```bash
mkdir -m 700 /Users/marcomartelli/Documents/KalTracker-Signing

./scripts/bootstrap_android_ota.sh \
  --output-dir /Users/marcomartelli/Documents/KalTracker-Signing/ota-2026-01 \
  --dry-run
```

Controllato il percorso, sostituire `--dry-run` con `--create`. È un’operazione da eseguire una
sola volta. Lo script produce:

```text
kal-tracker-release.jks          chiave permanente di firma Android
ota-ed25519-private.pem          chiave privata per i manifest OTA
ota-ed25519-public.pem           corrispondente chiave pubblica
android-signer-cert.pem          certificato pubblico Android
github-actions-secrets.env       valori sensibili, escluso il PAT GitHub
github-actions-vars.env          chiave OTA pubblica e fingerprint Android
METADATA.txt                     identificativi non segreti del bundle
```

Validare il bundle senza esporne il contenuto:

```bash
./scripts/validate_ota_bundle.sh \
  --bundle-dir /Users/marcomartelli/Documents/KalTracker-Signing/ota-2026-01
```

Prima di configurare GitHub, creare due backup cifrati in supporti distinti e verificare almeno un
ripristino. Perdere il keystore Android impedisce di aggiornare l’app installata; perdere la chiave
Ed25519 impedisce di pubblicare manifest accettati dalle versioni già installate. Nessun file del
bundle va copiato nel repository.

## 2. Configurazione GitHub

Usare l’interfaccia web del repository sorgente per inserire nell’environment `release` i valori di
`github-actions-secrets.env` e `github-actions-vars.env`. Il file dei secret non va eseguito con
`source`, stampato nel terminale o passato a comandi generici.

`RELEASES_REPO_TOKEN` non viene generato dallo script. Creare un fine-grained PAT separato con:

- accesso al solo repository `marx87/kal-tracker-releases`;
- permesso repository `Contents: Read and write`;
- una scadenza annotata e nessun accesso al repository sorgente.

Non copiare il token usato dal login corrente di `gh`. L’environment `release` deve consentire
deployment soltanto dal branch `main`; l’approvazione manuale è consigliata se disponibile per il
piano GitHub usato.

## 3. Preflight remoto in sola lettura

Il preflight controlla repository, visibilità, appartenenza del commit sorgente alla storia di
`main`, workflow, policy dell’environment, presenza dei nomi secret/var e monotonicità della release.
GitHub non permette di rileggere i valori
dei secret: lo script ne può verificare soltanto la presenza. Non può neppure dimostrare lo scope del
PAT memorizzato, che va controllato dalla pagina del token.

Per evitare qualunque uso involontario del login `gh` esistente, lo script richiede un token di
lettura separato in `KAL_PREFLIGHT_GH_TOKEN` e usa una configurazione `gh` temporanea. Inserirlo senza
salvarlo nella cronologia:

```bash
read -r -s KAL_PREFLIGHT_GH_TOKEN
printf '\n'
export KAL_PREFLIGHT_GH_TOKEN

./scripts/release_preflight.sh \
  --version 0.1.0 \
  --build-number 1 \
  --expected-source-commit 21e728b

unset KAL_PREFLIGHT_GH_TOKEN
```

Il token di preflight deve poter leggere il repository sorgente privato, i metadata di Actions e
dell’environment, e i metadata del repository pubblico delle release. Lo script esegue soltanto
richieste HTTP `GET`, non mostra valori e non crea o modifica configurazioni.

## 4. Sequenza `v0.1.0` → `v0.2.0`

Il commit baseline verificato è `21e728ba4bb13f6331a7e760dd979db358a8d009`. Prima va portato su
`main` anche il workflow rinforzato di questa fase, mantenendo il baseline nella storia del branch.
Usare quindi un merge normale o un fast-forward: squash e rebase riscriverebbero la storia e
renderebbero impossibile selezionare esattamente il vecchio SHA.

Dopo il merge, verificare senza avviare release:

```bash
git fetch origin
git merge-base --is-ancestor 21e728ba4bb13f6331a7e760dd979db358a8d009 origin/main
```

Nessun merge o push è stato eseguito durante il bootstrap.

Quando il baseline appartiene davvero alla storia di `main`:

1. eseguire il preflight per `0.1.0`, build `1`, commit `21e728b`;
2. aprire GitHub Actions e avviare `Android signed release` dal branch `main`;
3. inserire `version=0.1.0`, `build_number=1`,
   `source_commit=21e728ba4bb13f6331a7e760dd979db358a8d009` e le note;
4. scaricare `v0.1.0-b1` dal repository pubblico e installarlo manualmente;
5. verificare nell’app che il canale sia `personal` e conservare l’APK come recovery.

Il workflow affidabile viene letto dalla testa di `main`, quindi effettua un secondo checkout del
commit sorgente richiesto. Prima di eseguire codice del commit selezionato verifica che quello SHA
sia un antenato di `main`; manifest e `SOURCE.json` registrano sia il commit sorgente sia il commit
del workflow. La `v0.1.0` incorpora già la chiave pubblica OTA e deve essere firmata con il keystore
definitivo.

Dopo aver integrato le nuove funzioni su `main`, ripetere il preflight con il nuovo SHA e pubblicare:

```text
version=0.2.0
build_number=2
source_commit=<nuovo SHA completo di 40 caratteri>
```

Aprendo la `v0.1.0`, il banner deve trovare il manifest `v0.2.0-b2`, verificarlo e proporre
l’installer Android. Android richiede comunque la conferma dell’utente. Non disinstallare la
`v0.1.0` tra i due passaggi; l’APK debug può restare installato perché è un’app separata.

## Garanzie del workflow

Il workflow:

- parte soltanto da `main` e carica i segreti solo negli step di firma;
- usa un token fine-grained soltanto nello step GitHub Release e lascia `GITHUB_TOKEN` in sola lettura;
- fissa checkout, setup Java, Flutter e upload artifact a SHA completi;
- richiede uno SHA completo, compila esattamente quel commit e verifica che sia nella storia di `main`;
- legge la release `latest` senza autenticazione, ne verifica la firma Ed25519 e rifiuta regressioni
  di versione o build sia prima della firma sia immediatamente prima della pubblicazione;
- verifica package, versione e certificato dell’APK;
- firma un manifest che include repository, commit sorgente, commit/ref/run del workflow e repository release;
- genera `SHA256SUMS` con soli nomi relativi e comandi compatibili con macOS/Linux;
- confronta i digest remoti di APK, manifest, checksum e provenienza prima di pubblicare;
- rimuove dal runner keystore e chiavi temporanee.

Un `404` del file manifest non viene mai considerato sufficiente per dichiarare “prima release”:
deve essere l’endpoint API GitHub `/releases/latest` a restituire `404`. Se una release esiste ma il
manifest manca, ha una firma errata o non coincide col tag, il workflow si ferma in modo conservativo.

Il workflow rifiuta release senza keystore, firma OTA, fingerprint o build number validi. Non installare l’APK debug come app principale: ha un application ID separato e non riceve il canale OTA di produzione.
