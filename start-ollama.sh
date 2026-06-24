#!/usr/bin/env bash
# Démarrage / arrêt d'Ollama (conteneur GPU).
# Usage : ./start-ollama.sh [up|down|logs|status]   (défaut : up)
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

case "${1:-up}" in
  up)
    $DOCKER compose up -d
    echo "Ollama démarré : http://localhost:11434"
    ;;
  down)
    $DOCKER compose down
    echo "Ollama arrêté (volume des modèles conservé)."
    ;;
  logs)
    $DOCKER compose logs -f ollama
    ;;
  status)
    $DOCKER compose ps
    ;;
  *)
    echo "Usage : $0 [up|down|logs|status]" >&2
    exit 1
    ;;
esac
