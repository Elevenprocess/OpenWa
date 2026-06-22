# OpenWA sur le VPS — guide d'exploitation

> Briefing pour l'assistant (Claude Code) qui tourne sur le VPS. Lis ce fichier
> en entier avant toute action. Tout se passe dans le dossier `deploy/` de ce repo.

## 1. À quoi ça sert

OpenWA est la **passerelle WhatsApp** de Velora / ECOI. Le backend ECOI (hébergé
sur Render) l'appelle en HTTP pour **envoyer des messages WhatsApp** (alertes de
débrief, notifications). OpenWA pilote une session WhatsApp Web headless
(Chromium) qui doit tourner **24/7** — c'est pour ça qu'on est sur ce VPS et pas
sur Render.

Sens du trafic : `Backend Render ──HTTPS──► OpenWA (ce VPS) ──► WhatsApp`.

## 2. Architecture du déploiement

```
Internet ──HTTPS :443──► Caddy ──HTTP interne :2785──► openwa-api (Chromium + Node)
```

- **Caddy** (conteneur `openwa-caddy`) : seul exposé sur 80/443. Obtient et
  renouvelle **tout seul** le certificat Let's Encrypt pour `WA_DOMAIN`.
- **openwa-api** (conteneur `openwa-api`) : l'app. **Jamais exposée
  directement**, visible seulement sur le réseau Docker interne (`expose: 2785`).
- La **session WhatsApp + la base SQLite** vivent dans le volume Docker
  persistant `openwa-data`. ⚠️ Ne jamais supprimer ce volume : ça force un
  re-scan du QR (perte de la liaison au téléphone).
- Node 22.12+ est **obligatoire** (paquets ESM) — déjà géré par le `Dockerfile`
  officiel (`node:22-slim` + chromium). Ne pas essayer de lancer en Node 18.

## 3. Pré-requis avant le premier déploiement

1. **DNS** : un enregistrement **A** pour le sous-domaine (ex.
   `wa.electroconceptoi.com`) doit pointer vers l'**IP publique du VPS**.
   Sans ça, Caddy ne pourra pas obtenir le certificat HTTPS.
2. **Docker + docker compose** installés sur le VPS.
3. **Ports 80 et 443** ouverts dans le firewall.

## 4. Déploiement (premier lancement)

```bash
cd deploy
cp .env.example .env
nano .env          # régler WA_DOMAIN (le sous-domaine DNS) + API_MASTER_KEY (clé forte)
                   # générer la clé :  openssl rand -hex 24
docker compose up -d --build
```

`API_MASTER_KEY` est la clé secrète que le backend enverra dans le header
`X-API-Key`. Garde-la, le backend en a besoin (étape 6).

Vérifier que ça tourne :

```bash
docker compose ps           # les 2 conteneurs doivent être "running"
docker compose logs -f caddy --tail=50      # doit montrer le certificat obtenu
docker compose logs -f openwa-api --tail=50
curl -s https://<WA_DOMAIN>/api/sessions -H "X-API-Key: <API_MASTER_KEY>"
```

## 5. Lier le téléphone WhatsApp (scan du QR — une seule fois)

Le script `session-qr.sh` crée/démarre une session et récupère le QR. Il
s'utilise contre l'API distante (depuis le VPS ou depuis un poste) :

```bash
cd deploy
BASE=https://<WA_DOMAIN> KEY=<API_MASTER_KEY> NAME=velora ./session-qr.sh
```

Il écrit `openwa-qr.png` (le QR) qu'il faut **scanner avec WhatsApp sur le
téléphone** (Appareils liés). Le script attend la connexion puis affiche
`✓ CONNECTÉ` avec le numéro lié et les 3 variables à mettre côté backend.

`AUTO_START_SESSIONS=true` fait que la session se **reconnecte toute seule** au
redémarrage du conteneur — pas besoin de rescanner tant que le volume
`openwa-data` est intact.

## 6. Brancher le backend ECOI (Render)

Une fois la session `CONNECTÉ`, mettre ces 3 variables d'environnement côté
backend (Render, projet ECOI_backend) :

```
OPENWA_BASE_URL=https://<WA_DOMAIN>
OPENWA_API_KEY=<API_MASTER_KEY>        # la même que dans deploy/.env
OPENWA_SESSION_ID=<id affiché par session-qr.sh>
```

## 7. Exploitation courante

```bash
cd deploy
docker compose ps                       # état
docker compose logs -f openwa-api       # logs app
docker compose restart openwa-api       # redémarrer l'app (session se reconnecte)
docker compose pull && docker compose up -d --build   # mettre à jour après un git pull
docker compose down                     # arrêter (SANS supprimer les volumes)
```

⚠️ **Ne jamais** faire `docker compose down -v` ni supprimer le volume
`openwa-data` : ça efface la session WhatsApp et la base → re-scan obligatoire.

## 8. Dépannage

- **Pas de HTTPS / certificat** → vérifier que le DNS A pointe bien vers le VPS
  et que 80/443 sont ouverts ; relire `docker compose logs caddy`.
- **Session déconnectée** → `docker compose logs openwa-api` ; si la session est
  morte, relancer `session-qr.sh` et rescanner.
- **401 / 403 sur l'API** → mauvaise `API_MASTER_KEY` (doit être identique entre
  `deploy/.env` et la variable `OPENWA_API_KEY` côté backend).
- **Le conteneur crash au boot avec `ERR_REQUIRE_ESM`** → un Node < 22 est
  utilisé ; rebuild avec le Dockerfile fourni (`docker compose build --no-cache`).

## 9. Ce qu'il ne faut PAS committer / pousser

Le `.gitignore` couvre déjà : `.env` (secrets réels), `node_modules/`, `dist/`,
les volumes/données, les binaires Node locaux (`.node20/`, `.node22/`), et les
artefacts runtime (`*.pid`, `.session_id`, `openwa-qr.png`, `*.log`,
`start-test.out`). Ne force jamais l'ajout de ces fichiers.

Repo : `github.com/Elevenprocess/OpenWa` (branche `main`).
