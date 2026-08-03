# Supabase

La cartella contiene migrazioni versionate; nessuna migrazione è stata ancora applicata al progetto remoto di Marco.

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

Lo schema usa UUID client-side, `row_version`, mutation ID, tombstone e un change log a cursore crescente. Il client dovrà inviare gli update con la `row_version` attesa per rilevare conflitti.

`sync_changes` è anche il ledger permanente delle mutation già applicate: nella V1 non va ripulito. Un retry con lo stesso mutation ID è un no-op; riutilizzare quell'ID per un'altra riga viene rifiutato.
