#!/usr/bin/env bash
# Pilotage du service Docling (extraction + OCR GPU) de la stack ollamarag.
# Usage : ./docling.sh [start|stop|restart|logs|status]   (défaut : start)
#
# Les trois services (ollama, open-webui, docling) partagent le même
# docker-compose.yml ; ce script n'agit QUE sur « docling ».
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-07-01
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

SERVICE="docling"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

# Nom du projet compose courant (déduit du dossier, comme le fait Docker).
PROJECT="$($DOCKER compose config --format json 2>/dev/null \
  | grep -o '"name":[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"

# Supprime tout conteneur ARRÊTÉ qui squatte le container_name voulu par notre
# service mais qui appartient à un AUTRE projet compose (orphelin d'un stack
# supprimé). On ne touche jamais à un conteneur actif ni au projet courant.
clean_orphan_name() {
  local id proj state
  id="$($DOCKER ps -aq --filter "name=^/${SERVICE}$")"
  [ -n "$id" ] || return 0
  proj="$($DOCKER inspect "$id" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null)"
  state="$($DOCKER inspect "$id" --format '{{ .State.Running }}' 2>/dev/null)"
  if [ "$proj" != "$PROJECT" ] && [ "$state" = "false" ]; then
    echo "Nettoyage : conteneur orphelin « $SERVICE » (projet « ${proj:-aucun} », arrêté) supprimé."
    $DOCKER rm "$id" >/dev/null
  fi
}

case "${1:-start}" in
  start)
    clean_orphan_name
    $DOCKER compose up -d "$SERVICE"
    echo "Docling démarré : http://localhost:5001"
    ;;
  stop)
    $DOCKER compose stop "$SERVICE"
    echo "Docling arrêté."
    ;;
  restart)
    # compose stop + start : relance le conteneur existant sans le recréer
    # (rapide, conserve l'état). Pour reprendre une modif de docker-compose.yml
    # (env, volumes, image), faire « stop » puis « start ».
    $DOCKER compose stop "$SERVICE"
    $DOCKER compose start "$SERVICE"
    echo "Docling redémarré : http://localhost:5001"
    ;;
  logs)
    $DOCKER compose logs -f "$SERVICE"
    ;;
  status)
    $DOCKER compose ps "$SERVICE"
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
