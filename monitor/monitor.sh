#!/usr/bin/env bash
# Lance le dashboard de monitoring temps réel de la stack ollamarag.
# Sert une page web (histogrammes GPU/CPU/RAM + état des conteneurs) qui se
# rafraîchit toute seule. Zéro dépendance hors Python 3 (stdlib) et nvidia-smi.
#
# Usage : ./monitor.sh [start|stop|status] [--host H] [--port P]
#         ./monitor.sh                   # défaut : start sur 0.0.0.0:8770 (LAN)
#         ./monitor.sh --port 9000       # autre port
#         ./monitor.sh --host 127.0.0.1  # restreindre à la machine locale
#
# ⚠ Par défaut le dashboard est OUVERT AU RÉSEAU LOCAL (0.0.0.0), sans auth ni
#   HTTPS. À réserver à un LAN de confiance ; sinon --host 127.0.0.1.
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-07-01
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

PIDFILE="/tmp/ollamarag-monitor.pid"
# Ouvert au LAN par défaut (0.0.0.0), comme Ollama et Open WebUI. Pour
# restreindre à la machine locale : --host 127.0.0.1 (ou MONITOR_HOST=127.0.0.1).
HOST="${MONITOR_HOST:-0.0.0.0}"
PORT="${MONITOR_PORT:-8770}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Sous-commande (défaut : start) + options.
CMD="start"
case "${1:-}" in
  start|stop|status) CMD="$1"; shift ;;
  -h|--help) usage 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host requiert une valeur}"; shift 2 ;;
    --port) PORT="${2:?--port requiert une valeur}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done

running_pid() {  # affiche le PID si le serveur tourne, sinon rien
  [ -f "$PIDFILE" ] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
  return 1
}

case "$CMD" in
  start)
    if pid="$(running_pid)"; then
      echo "Déjà démarré (PID $pid) : http://${HOST}:${PORT}"
      exit 0
    fi
    command -v python3 >/dev/null 2>&1 || { echo "python3 requis." >&2; exit 1; }
    MONITOR_HOST="$HOST" MONITOR_PORT="$PORT" \
      nohup python3 server.py --host "$HOST" --port "$PORT" \
        >/tmp/ollamarag-monitor.log 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    if pid="$(running_pid)"; then
      echo "Monitoring démarré (PID $pid) : http://${HOST}:${PORT}"
      echo "Logs : /tmp/ollamarag-monitor.log"
    else
      echo "Échec du démarrage — voir /tmp/ollamarag-monitor.log" >&2
      exit 1
    fi
    ;;
  stop)
    if pid="$(running_pid)"; then
      kill "$pid" && echo "Monitoring arrêté (PID $pid)."
      rm -f "$PIDFILE"
    else
      echo "Non démarré."
      rm -f "$PIDFILE"
    fi
    ;;
  status)
    if pid="$(running_pid)"; then
      echo "Actif (PID $pid) : http://${HOST}:${PORT}"
    else
      echo "Arrêté."
      exit 1
    fi
    ;;
esac
