#!/usr/bin/env bash
# Démarrage / arrêt d'Ollama (conteneur GPU).
# Usage : ./start-ollama.sh [start|stop|restart|logs|status]   (défaut : start)
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

# Nom du projet compose courant (déduit du dossier, comme le fait Docker).
PROJECT="$($DOCKER compose config --format json 2>/dev/null \
  | grep -o '"name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"

# Supprime tout conteneur ARRÊTÉ qui squatte un container_name voulu par notre
# stack mais qui appartient à un AUTRE projet compose (orphelin d'un stack
# supprimé). On ne touche jamais à un conteneur actif ni au projet courant.
clean_orphan_names() {
  local names name id proj state
  names="$($DOCKER compose config --format json 2>/dev/null \
    | grep -o '"container_name":[[:space:]]*"[^"]*"' \
    | sed 's/.*"\([^"]*\)"$/\1/')"
  for name in $names; do
    id="$($DOCKER ps -aq --filter "name=^/${name}$")"
    [ -n "$id" ] || continue
    proj="$($DOCKER inspect "$id" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null)"
    state="$($DOCKER inspect "$id" --format '{{ .State.Running }}' 2>/dev/null)"
    if [ "$proj" != "$PROJECT" ] && [ "$state" = "false" ]; then
      echo "Nettoyage : conteneur orphelin « $name » (projet « ${proj:-aucun} », arrêté) supprimé."
      $DOCKER rm "$id" >/dev/null
    fi
  done
}

case "${1:-start}" in
  start)
    clean_orphan_names
    $DOCKER compose up -d
    echo "Ollama démarré : http://localhost:11434"
    # Équilibrage matériel : la RTX 3080 (10 Go) est la ressource rare. Par
    # défaut docling réserve ~3,3 Go de VRAM en permanence (DEVICE=cuda) et prive
    # Ollama de son KV cache → OOM. hw-balance applique le profil INTERROGATION
    # (GPU → Ollama, docling → CPU) une fois la stack up. Bascule vers l'OCR GPU
    # à l'import via « ./hw-balance.sh import » (ou « auto »).
    if [ -x ./hw-balance.sh ]; then
      ./hw-balance.sh query || echo "hw-balance : équilibrage ignoré (voir ./hw-balance.sh status)."
    fi
    ;;
  stop)
    $DOCKER compose down
    echo "Ollama arrêté (volume des modèles conservé)."
    ;;
  restart)
    # compose stop + start : relance les conteneurs existants sans les recréer
    # (rapide, conserve l'état). Pour reprendre une modif de docker-compose.yml
    # (env, volumes, image), faire « stop » puis « start ».
    $DOCKER compose stop
    $DOCKER compose start
    echo "Ollama redémarré : http://localhost:11434"
    ;;
  logs)
    $DOCKER compose logs -f ollama
    ;;
  status)
    $DOCKER compose ps
    ;;
  -h|--help)
    echo "Usage : $0 [start|stop|restart|logs|status]"
    exit 0
    ;;
  *)
    echo "Usage : $0 [start|stop|restart|logs|status]" >&2
    exit 1
    ;;
esac
