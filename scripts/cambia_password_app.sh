#!/usr/bin/env bash
# Cambia la password con cui Marco accede a Coach360 (Supabase Auth).
#
# La password si digita qui, a schermo spento, e va direttamente nel database:
# non passa da una chat, non finisce in un log, non resta nella cronologia
# della shell. Alla fine viene riscritta anche in KalTracker-Signing, che
# resta l'unico posto dove è conservata.
#
#     bash scripts/cambia_password_app.sh
#
# Serve solo la password del database, che è già in KalTracker-Signing.

set -euo pipefail

FIRMA="$HOME/Documents/KalTracker-Signing/supabase"
FILE_DB="$FIRMA/db-password.txt"
FILE_APP="$FIRMA/marco-app-password.txt"
EMAIL="marco.mart87@gmail.com"
HOST="postgresql://postgres.kamljzffqwfaluicznti@aws-0-eu-central-1.pooler.supabase.com:5432/postgres"

if [[ ! -f "$FILE_DB" ]]; then
  echo "Non trovo la password del database in $FILE_DB" >&2
  exit 1
fi

echo "Nuova password per $EMAIL"
echo "(non si vede mentre la scrivi; minimo 8 caratteri)"
echo

read -r -s -p "Password:  " NUOVA
echo
read -r -s -p "Ripetila:  " CONFERMA
echo
echo

if [[ "$NUOVA" != "$CONFERMA" ]]; then
  echo "Le due password non coincidono: non ho cambiato niente." >&2
  exit 1
fi

# Supabase ne pretende almeno 6: otto è il minimo che vale la pena difendere,
# visto che questa password protegge tutto lo storico.
if (( ${#NUOVA} < 8 )); then
  echo "Troppo corta: servono almeno 8 caratteri. Non ho cambiato niente." >&2
  exit 1
fi

# La password viaggia come parametro, non dentro il testo della query: così
# non finisce nei log del server e un apostrofo non rompe niente.
#
# `-q` non è pignoleria: senza, psql stampa anche il proprio «UPDATE 1» sullo
# stdout — insieme al risultato, non al posto suo — e il confronto qui sotto
# fallirebbe pur avendo cambiato la password davvero. È successo.
ESITO=$(
  PGPASSWORD="$(tr -d '\n' < "$FILE_DB")" psql "$HOST" \
    -v ON_ERROR_STOP=1 -q -t -A \
    -v email="$EMAIL" -v nuova="$NUOVA" <<'SQL'
update auth.users
set encrypted_password = extensions.crypt(:'nuova', extensions.gen_salt('bf')),
    updated_at = now()
where email = :'email'
returning 'ok';
SQL
)

# Si cerca la riga, non l'uguaglianza secca: se un giorno psql tornasse a
# scrivere qualcosa di suo, la password cambiata resterebbe cambiata invece di
# essere dichiarata fallita.
if ! grep -qx 'ok' <<<"$ESITO"; then
  echo "Il database non ha aggiornato nessun utente. Password invariata." >&2
  echo "Risposta del database: ${ESITO:-(vuota)}" >&2
  exit 1
fi

# Il file è l'unica copia: si riscrive solo dopo che il database ha confermato.
printf '%s' "$NUOVA" > "$FILE_APP"
chmod 600 "$FILE_APP"

echo "Fatto: password cambiata e riscritta in"
echo "  $FILE_APP"
echo
echo "Nell'app: Corpo → impostazioni → Progressi → Sincronizzazione,"
echo "utente $EMAIL."
