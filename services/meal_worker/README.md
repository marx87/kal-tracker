# Meal worker

Segnaposto per il worker personale sul Mac mini. Verrà implementato dopo il diario e la sincronizzazione Supabase.

Vincoli già fissati:

- una foto alla volta;
- processo gestito da `launchd`;
- job reclamati da Supabase senza porte domestiche in ingresso;
- output JSON Schema obbligatorio;
- nessun accesso al repository o a tool di scrittura;
- immagini temporanee eliminate anche dopo errori;
- provider sostituibile fra Codex, Claude e modello locale.
