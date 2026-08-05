# Architettura

```text
Flutter UI
   ↓
Repository applicativi
   ↓
Drift / SQLite + outbox
   ↓ sincronizzazione da collegare
Supabase Auth + Postgres + Storage

Supabase meal_analysis_jobs
   ↓ RPC con lease e identità dedicata
servizio personale launchd sul Mac mini
   ↓ adapter sostituibile
Codex CLI / futuro Claude o modello locale
```

## Regole

- La UI non legge o scrive direttamente Supabase.
- Ogni modifica viene prima salvata localmente insieme alla relativa operazione di outbox.
- Lo storico alimentare conserva gli snapshot dei nutrienti usati al momento della registrazione.
- I modelli di pasto (`meal_templates` e le loro voci `meal_template_items`) conservano gli stessi snapshot delle ricette: applicare un modello crea nuove voci di diario, mai un riferimento al modello, così una modifica successiva non riscrive il passato.
- I tag delle ricette sono una sola lista CSV di etichette minuscole: `fit_recipes.tags` in locale, `recipes.tags` su Supabase.
- Le voci figlie di modelli e ricette si sostituiscono in blocco: la posizione è unica soltanto fra le righe vive, i tombstone conservano la loro.
- Le cancellazioni applicative sono tombstone, non eliminazioni fisiche immediate.
- Il giorno alimentare è calcolato in `Europe/Rome`, indipendentemente dal fuso del dispositivo.
- L’AI propone alimenti e quantità; il motore deterministico calcola i nutrienti dopo la conferma.
- Il worker non conserva `service_role`: usa un utente Auth dedicato, RPC limitate e legge soltanto la foto del job preso in lease.
- Le foto sono immutabili, verificate per percorso, dimensione, SHA-256, MIME e firma reale del formato prima dell'analisi.
- Se il Mac è spento, il job resta in coda e tutte le funzioni manuali continuano a funzionare.
- Gym Tracker viene **assorbito** (decisione del 5 agosto 2026): il suo storico entra una volta sola da export JSON, gli allenamenti diventano tabelle Drift come tutto il resto e Firebase si spegne. Non esiste nessuna replica continua.
- Della bilancia si conserva l'**impedenza grezza**: percentuali e masse sono calcolate con una formula nostra versionata, così un miglioramento della formula ricalcola lo storico invece di spezzarlo.
- La composizione corporea si confronta solo a **medie mobili di 7 giorni**: la BIA è troppo rumorosa per il giorno-su-giorno.
