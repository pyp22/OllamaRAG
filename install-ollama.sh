#!/usr/bin/env bash
# Installation d'Ollama (GPU NVIDIA) en conteneur Docker.
# Brique de base du RAG : génération + embeddings. Indépendant du Wiki.
# Cible : Ubuntu/Debian, GPU NVIDIA (RTX 3080). À lancer depuis ce dossier.
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ─────────────────────────────────────────────────────────────
# 1. Docker + plugin compose
# ─────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker (dépôt officiel)"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  echo "⚠  Reconnecte ta session (ou 'newgrp docker') pour utiliser docker sans sudo."
else
  log "Docker déjà présent : $(docker --version)"
fi

# ─────────────────────────────────────────────────────────────
# 2. NVIDIA Container Toolkit (passe la RTX 3080 aux conteneurs)
# ─────────────────────────────────────────────────────────────
if ! docker info 2>/dev/null | grep -qi nvidia && ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Installation du NVIDIA Container Toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
else
  log "NVIDIA Container Toolkit déjà configuré"
fi

# docker sans sudo dans CE script si le groupe n'est pas encore actif
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

# ─────────────────────────────────────────────────────────────
# 3. Fiabilisation des téléchargements sur lien lent / instable
#    Sur une liaison lente, le pull parallèle de plusieurs images
#    affame chaque connexion → "TLS handshake timeout" et couches
#    qui redémarrent en boucle. On force Docker à télécharger
#    UNE couche à la fois et à réessayer automatiquement.
# ─────────────────────────────────────────────────────────────
log "Réglage du daemon Docker (téléchargements séquentiels + retries)"
DAEMON_JSON="/etc/docker/daemon.json"
sudo install -m 0644 -d "$(dirname "$DAEMON_JSON")"
[ -f "$DAEMON_JSON" ] && sudo cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
# Fusion idempotente : on conserve la conf existante (runtime nvidia, etc.)
sudo python3 - "$DAEMON_JSON" <<'PY'
import json, sys, os
path = sys.argv[1]
try:
    with open(path) as f: cfg = json.load(f)
except (FileNotFoundError, ValueError):
    cfg = {}
cfg["max-concurrent-downloads"] = 1
cfg["max-download-attempts"]   = 10
with open(path, "w") as f: json.dump(cfg, f, indent=4)
print("daemon.json mis à jour :", path)
PY
sudo systemctl restart docker
sleep 3
until $DOCKER info >/dev/null 2>&1; do sleep 2; done

# ─────────────────────────────────────────────────────────────
# 4. Image Ollama (pull séquentiel avec retries)
# ─────────────────────────────────────────────────────────────
pull_retry() {  # $1 = commande de pull, $2 = libellé
  local i
  for i in 1 2 3 4 5 6; do
    if eval "$1"; then return 0; fi
    echo "   ↻ tentative $i échouée pour $2, nouvel essai dans 5s…"; sleep 5
  done
  echo "✗ Échec définitif du pull : $2" >&2; return 1
}

log "Téléchargement de l'image Ollama"
for img in $($DOCKER compose config --images); do
  log "Image : $img"
  pull_retry "$DOCKER pull '$img'" "$img"
done

log "Démarrage d'Ollama"
$DOCKER compose up -d

# ─────────────────────────────────────────────────────────────
# 5. Modèles : génératif FR + embedding multilingue
# ─────────────────────────────────────────────────────────────
log "Attente du démarrage d'Ollama"
until $DOCKER exec ollama ollama list >/dev/null 2>&1; do sleep 2; done

log "Téléchargement du modèle génératif (qwen2.5:7b)"
pull_retry "$DOCKER exec ollama ollama pull qwen2.5:7b" "qwen2.5:7b"
log "Téléchargement du modèle d'embedding (bge-m3)"
pull_retry "$DOCKER exec ollama ollama pull bge-m3" "bge-m3"

# Variante « plein GPU » pour le RAG : num_gpu=99 + num_ctx=8192 figés. Tient
# entièrement sur la RTX 3080 (offload 29/29, ~111 tok/s) ; c'est le RAG_MODEL.
log "Création du modèle RAG plein-GPU (qwen2.5:7b-rag)"
$DOCKER exec -i ollama ollama create qwen2.5:7b-rag -f - <<'MODELFILE'
FROM qwen2.5:7b
PARAMETER num_gpu 99
PARAMETER num_ctx 8192
# Qwen2.5 (entraîné majoritairement en chinois) bascule en chinois sans consigne
# de langue explicite, surtout en RAG sur requête courte. On impose le français.
SYSTEM """Tu es un assistant francophone. Tu réponds TOUJOURS en français, quelle que soit la langue des documents ou du contexte fournis, sauf si l'utilisateur demande explicitement une autre langue."""
MODELFILE

log "Ollama prêt : http://localhost:11434"
echo "  Modèles : $($DOCKER exec ollama ollama list | awk 'NR>1{print $1}' | paste -sd' ')"
echo "  Étape suivante : lancer la stack RAG (Open WebUI + Docling) avec docker compose up -d"
