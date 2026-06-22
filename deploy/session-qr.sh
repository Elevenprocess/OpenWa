#!/usr/bin/env bash
#
# session-qr.sh — Crée/démarre une session WhatsApp sur une instance OpenWA
# distante et enregistre le QR à scanner (openwa-qr.png).
#
# À lancer depuis TON poste (pas forcément le VPS), une seule fois :
#   BASE=https://wa.electroconceptoi.com KEY=<API_MASTER_KEY> ./session-qr.sh
#
set -euo pipefail
BASE="${BASE:?export BASE=https://wa.exemple.com}"
KEY="${KEY:?export KEY=<API_MASTER_KEY>}"
NAME="${NAME:-velora}"

api(){ curl -fsS -H "X-API-Key: $KEY" -H "Content-Type: application/json" "$@"; }

echo "→ Session « $NAME » sur $BASE"
SID="$(api "$BASE/api/sessions" | jq -r --arg n "$NAME" '(.data//.)[]? | select(.name==$n) | .id' | head -1)"
if [ -z "${SID:-}" ] || [ "$SID" = "null" ]; then
  SID="$(api -X POST "$BASE/api/sessions" -d "{\"name\":\"$NAME\"}" | jq -r '.data.id // .id')"
  echo "  session créée : $SID"
else
  echo "  session existante : $SID"
fi

api -X POST "$BASE/api/sessions/$SID/start" >/dev/null || true

echo "→ Attente du QR / connexion (scanne dès qu'openwa-qr.png apparaît)…"
for i in $(seq 1 90); do
  ST="$(api "$BASE/api/sessions/$SID" | jq -r '.status // .data.status')"
  case "$ST" in
    ready|CONNECTED)
      PHONE="$(api "$BASE/api/sessions/$SID" | jq -r '.phone // .data.phone')"
      echo "✓ CONNECTÉ — numéro lié : $PHONE"
      echo ""
      echo "À mettre dans ECOI_backend (Render) :"
      echo "  OPENWA_BASE_URL=$BASE"
      echo "  OPENWA_API_KEY=$KEY"
      echo "  OPENWA_SESSION_ID=$SID"
      exit 0 ;;
    qr_ready)
      api "$BASE/api/sessions/$SID/qr" \
        | jq -r 'if .data then .data else . end | .qrCode' \
        | sed 's/^data:image\/png;base64,//' | base64 -d > openwa-qr.png 2>/dev/null \
        && echo "  [QR rafraîchi] ouvre openwa-qr.png — statut=$ST" ;;
    *) echo "  statut=$ST…" ;;
  esac
  sleep 5
done
echo "✗ Pas connecté à temps. Relance le script."
exit 1
