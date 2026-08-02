# Architettura

```text
Flutter UI
   ↓
Repository applicativi
   ↓
Drift / SQLite + outbox
   ↓ sincronizzazione futura
Supabase Auth + Postgres + Storage

Supabase meal_analysis_jobs
   ↓
worker personale sul Mac mini
   ↓
Codex / Claude / modello locale
```

## Regole

- La UI non legge o scrive direttamente Supabase.
- Ogni modifica viene prima salvata localmente insieme alla relativa operazione di outbox.
- Lo storico alimentare conserva gli snapshot dei nutrienti usati al momento della registrazione.
- Le cancellazioni applicative sono tombstone, non eliminazioni fisiche immediate.
- Il giorno alimentare è calcolato in `Europe/Rome`, indipendentemente dal fuso del dispositivo.
- L’AI propone alimenti e quantità; il motore deterministico calcola i nutrienti dopo la conferma.
- Gym Tracker resta autorevole per gli allenamenti e verrà replicato in sola lettura verso Supabase.
