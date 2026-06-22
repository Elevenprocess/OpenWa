#!/usr/bin/env bash
#
# start-test.sh — Démarre la passerelle OpenWA, crée/réutilise une session
# WhatsApp et affiche le QR à scanner. Une fois CONNECTED, affiche les
# variables à recopier dans ECOI_backend/.env.
#
# Usage :
#   ./start-test.sh                 # démarre tout + QR
#   API_MASTER_KEY=xxx ./start-test.sh
#   SESSION_NAME=velora ./start-test.sh
#   ./start-test.sh stop            # arrête la passerelle
#
set -euo pipefail

# ── Config (surchargée par l'environnement) ────────────────────────────────
cd "$(dirname "${BASH_SOURCE[0]}")"
OWA_DIR="$(pwd)"

# OpenWA exige Node 22.12+ (paquets `archiver`/`file-type` en ESM chargés via
# require — autorisé seulement depuis Node 22.12). Si un Node 22 portable a été
# installé localement dans .node22/, on le préfère au Node système (souvent v18).
if [ -x "${OWA_DIR}/.node22/bin/node" ]; then
  export PATH="${OWA_DIR}/.node22/bin:${PATH}"
fi
PORT="${PORT:-2785}"
BASE="http://localhost:${PORT}"
API_KEY="${API_MASTER_KEY:-mon-test-velora-2026}"
SESSION_NAME="${SESSION_NAME:-velora}"
LOG_FILE="${OWA_DIR}/openwa.log"
PID_FILE="${OWA_DIR}/openwa.pid"
QR_PNG="${OWA_DIR}/openwa-qr.png"

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_b(){ printf '\033[1;36m%s\033[0m\n' "$*"; }

api(){ # api <method> <path> [json-body]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$m" "${BASE}${p}" -H "X-API-Key: ${API_KEY}" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$m" "${BASE}${p}" -H "X-API-Key: ${API_KEY}"
  fi
}

# ── stop ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "stop" ]; then
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" && rm -f "$PID_FILE"
    c_g "✓ Passerelle OpenWA arrêtée."
  else
    c_y "Aucune passerelle en cours (pas de $PID_FILE actif)."
  fi
  exit 0
fi

# ── 1. .env ────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  c_y "→ Pas de .env, création depuis .env.minimal…"
  cp .env.minimal .env
  {
    echo ""
    echo "# ajouté par start-test.sh"
    echo "API_MASTER_KEY=${API_KEY}"
    echo "AUTO_START_SESSIONS=true"
  } >> .env
  c_g "✓ .env créé (API_MASTER_KEY=${API_KEY})"
else
  c_g "✓ .env déjà présent (laissé tel quel)"
  # On récupère la clé réellement configurée pour parler à l'API
  if grep -q '^API_MASTER_KEY=' .env; then
    API_KEY="$(grep '^API_MASTER_KEY=' .env | head -1 | cut -d= -f2-)"
    c_y "  (utilise API_MASTER_KEY du .env existant)"
  fi
fi

# ── 2. dépendances ─────────────────────────────────────────────────────────
if [ ! -d node_modules ]; then
  c_y "→ node_modules absent, installation (peut prendre quelques minutes)…"
  npm install
fi

# ── 3. démarrage passerelle (si pas déjà up) ───────────────────────────────
if curl -fsS "${BASE}/api/sessions" -H "X-API-Key: ${API_KEY}" >/dev/null 2>&1; then
  c_g "✓ Passerelle déjà en ligne sur ${BASE}"
else
  c_y "→ Démarrage de la passerelle OpenWA…"
  [ -f dist/main.js ] || npm run build
  nohup node dist/main.js > "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  c_y "  PID $(cat "$PID_FILE") — logs : $LOG_FILE"

  printf '  Attente du démarrage'
  for i in $(seq 1 60); do
    if curl -fsS "${BASE}/api/sessions" -H "X-API-Key: ${API_KEY}" >/dev/null 2>&1; then
      echo ""; c_g "✓ Passerelle en ligne sur ${BASE}"; break
    fi
    printf '.'; sleep 2
    if [ "$i" = 60 ]; then
      echo ""; c_r "✗ La passerelle n'a pas démarré à temps. Voir : tail -f $LOG_FILE"; exit 1
    fi
  done
fi

# ── 4. session (réutilise si elle existe, sinon crée) ──────────────────────
SESSIONS_JSON="$(api GET /api/sessions || echo '{}')"
SESSION_ID="$(echo "$SESSIONS_JSON" | jq -r --arg n "$SESSION_NAME" \
  '.data[]? | select(.name==$n) | .id' | head -1)"

if [ -z "${SESSION_ID:-}" ] || [ "$SESSION_ID" = "null" ]; then
  c_y "→ Création de la session \"${SESSION_NAME}\"…"
  CREATE_JSON="$(api POST /api/sessions "{\"name\":\"${SESSION_NAME}\"}")"
  SESSION_ID="$(echo "$CREATE_JSON" | jq -r '.data.id')"
  c_g "✓ Session créée : ${SESSION_ID}"
else
  c_g "✓ Session existante réutilisée : ${SESSION_ID}"
fi

# ── 5. statut + QR ─────────────────────────────────────────────────────────
show_qr(){
  local qr_json code image
  qr_json="$(api GET "/api/sessions/${SESSION_ID}/qr" 2>/dev/null || echo '{}')"
  code="$(echo "$qr_json" | jq -r '.data.code // empty')"
  image="$(echo "$qr_json" | jq -r '.data.image // empty')"
  [ -z "$code" ] && [ -z "$image" ] && return 1

  # a) PNG (toujours, ouvrable d'un double-clic)
  if [ -n "$image" ]; then
    echo "${image#data:image/png;base64,}" | base64 -d > "$QR_PNG" 2>/dev/null \
      && c_b "📷 QR enregistré : $QR_PNG  (ouvre-le et scanne-le)"
  fi
  # b) terminal (bonus si qrcode-terminal dispo dans node_modules)
  if [ -n "$code" ]; then
    node -e 'try{require("qrcode-terminal").generate(process.argv[1],{small:true})}catch(e){process.exit(3)}' \
      "$code" 2>/dev/null || true
  fi
  return 0
}

c_b ""
c_b "════════════════ SCAN DU QR ════════════════"
c_y "Sur ton téléphone : WhatsApp ▸ Réglages ▸ Appareils connectés ▸ Connecter un appareil"
echo ""

STATUS=""
for i in $(seq 1 60); do            # ~5 min max (60 × 5 s)
  STATUS="$(api GET "/api/sessions/${SESSION_ID}" 2>/dev/null | jq -r '.data.status // "UNKNOWN"')"
  case "$STATUS" in
    CONNECTED)
      c_g "✓ Connecté ! Session WhatsApp active."
      break ;;
    SCAN_QR|INITIALIZING|CONNECTING)
      # (ré)affiche le QR tant qu'on n'est pas connecté (il expire ~ toutes les 20 s)
      if [ "$STATUS" = "SCAN_QR" ]; then show_qr || true; fi
      printf '  [%s] en attente de scan…\r' "$STATUS" ;;
    *)
      printf '  [%s]…\r' "$STATUS" ;;
  esac
  sleep 5
done

echo ""
if [ "$STATUS" != "CONNECTED" ]; then
  c_r "✗ Pas connecté (dernier statut : ${STATUS}). Relance le script pour réafficher le QR."
  exit 1
fi

# ── 6. variables à recopier dans le backend ────────────────────────────────
PHONE="$(api GET "/api/sessions/${SESSION_ID}" 2>/dev/null | jq -r '.data.phoneNumber // "?"')"
c_b ""
c_b "════════ À RECOPIER DANS ECOI_backend/.env ════════"
cat <<EOF
OPENWA_BASE_URL=${BASE}
OPENWA_API_KEY=${API_KEY}
OPENWA_SESSION_ID=${SESSION_ID}
WHATSAPP_ALERTS_ENABLED=true
WHATSAPP_DRY_RUN=false
WHATSAPP_DEFAULT_COUNTRY_CODE=33
FRONTEND_URL=https://crm.electroconceptoi.com
EOF
c_g ""
c_g "✓ Numéro expéditeur lié : ${PHONE}"
c_y "→ Redémarre le backend, puis teste :"
echo "  curl -X POST http://localhost:3000/whatsapp/test \\"
echo "    -H 'Authorization: Bearer <token_admin>' -H 'Content-Type: application/json' \\"
echo "    -d '{\"phone\":\"<ton_06>\",\"text\":\"Test Velora ✅\"}'"
echo ""
c_y "Pour arrêter la passerelle :  ./start-test.sh stop"
