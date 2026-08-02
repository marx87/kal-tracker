# Supabase

La cartella contiene tre migrazioni versionate; nessuna è stata ancora applicata al progetto remoto di Marco.

- `001`: profilo, obiettivi, alimenti, pasti, outbox remota e RLS;
- `002`: acqua, peso, ricette, workout esterni, foto e job di analisi;
- `003`: identità automation, claim/lease e RPC del worker a privilegi minimi.

Le tre migrazioni sono state applicate insieme su PostgreSQL temporaneo e il flusso enqueue/claim è stato verificato. Prima dell'uso reale resta obbligatorio ripetere i test su un progetto Supabase di prova, incluse RLS e Storage con due utenti distinti.

## Scelta raccomandata

Creare un progetto Supabase dedicato nello stesso account. Se si usa il progetto dell’altra app, aggiungere `kal_tracker` agli **Exposed schemas** e mantenere policy, bucket e migrazioni separati.

## Applicazione

Dopo l’installazione della Supabase CLI:

```bash
supabase login
supabase link --project-ref PROJECT_REF
supabase db push
```

Prima del collegamento remoto:

- disabilitare la registrazione pubblica non necessaria;
- creare soltanto l’account Marco;
- verificare le policy RLS con due utenti di test;
- non copiare mai la `service_role` nell’app Flutter.

Controlli locali non distruttivi:

```bash
supabase/tests/meal_worker_rpc_static_test.sh
```

Il worker usa un secondo utente Supabase Auth associato a Marco tramite `automation_bindings`; sul Mac conserva soltanto credenziali di quell'utente nel Portachiavi. Il protocollo completo è in [`docs/MEAL_WORKER_PROTOCOL.md`](../docs/MEAL_WORKER_PROTOCOL.md).

Lo schema usa UUID client-side, `row_version`, mutation ID, tombstone e un change log a cursore crescente. Il client dovrà inviare gli update con la `row_version` attesa per rilevare conflitti.

`sync_changes` è anche il ledger permanente delle mutation già applicate: nella V1 non va ripulito. Un retry con lo stesso mutation ID è un no-op; riutilizzare quell'ID per un'altra riga viene rifiutato.

Il worker fotografico usa un'identità Auth dedicata e soltanto RPC a scope
limitato, mai la `service_role` sul Mac. Provisioning, lease e transizioni sono
descritti in [MEAL_WORKER_PROTOCOL.md](../docs/MEAL_WORKER_PROTOCOL.md).
