#!/usr/bin/env bash
# Bar graph « puissance de calcul vs hardware disponible » pour la stack RAG.
# Histogramme VERTICAL ASCII des 4 métriques clés : GPU (calcul), VRAM, CPU, RAM
# — colonnes côte à côte, axe 0-100 %, couleurs vert/jaune/rouge selon la charge.
# Hardware ciblé : RTX 3080 (10 Go) + i9-12900K (24 threads) + 62 Go RAM.
#
# Usage : ./hw-stats.sh            instantané unique
#         ./hw-stats.sh --watch    rafraîchi toutes les 2 s (Ctrl-C pour quitter)
#         ./hw-stats.sh -w 5       rafraîchi toutes les 5 s
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
set -uo pipefail

# ── Couleurs ──────────────────────────────────────────────────────────────
B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYA=$'\033[1;36m'

HEIGHT=12          # hauteur de l'histogramme en lignes
COLW=10            # largeur d'une colonne (caractères)

# Couleur selon le pourcentage.
col_for() {
  local p=$1
  if   [ "$p" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 70 ]; then printf '%s' "$YEL"
  else printf '%s' "$GRN"; fi
}

# Dessine l'histogramme vertical.
# Args : suites de "label:pct" (le détail texte est passé séparément via DETAIL[]).
draw_hist() {
  local -n PCT=$1 LBL=$2 DET=$3
  local n=${#PCT[@]} row i p bartop color
  local block_full='████████' block_half='▄▄▄▄▄▄▄▄'

  # Lignes de l'histogramme, du haut (100 %) vers le bas (0 %).
  for (( row=HEIGHT; row>=1; row-- )); do
    # Graduation de l'axe Y à gauche.
    local ymark=$(( row * 100 / HEIGHT ))
    printf "%s%3d%%%s │" "$DIM" "$ymark" "$R"
    for (( i=0; i<n; i++ )); do
      p=${PCT[$i]}
      # hauteur de la barre i, en lignes
      bartop=$(( p * HEIGHT / 100 ))
      color=$(col_for "$p")
      if [ "$bartop" -ge "$row" ]; then
        printf "  %s%s%s" "$color" "$block_full" "$R"
      else
        printf "  %s%s%s" "$DIM" "········" "$R"
      fi
    done
    echo
  done

  # Axe X.
  printf "     └"
  for (( i=0; i<n; i++ )); do printf "─%s" "──────────"; done
  echo
  # Pourcentages sous chaque colonne.
  printf "      "
  for (( i=0; i<n; i++ )); do
    color=$(col_for "${PCT[$i]}")
    printf "  %s%6d%%%s " "$color" "${PCT[$i]}" "$R"
  done
  echo
  # Labels.
  printf "      "
  for (( i=0; i<n; i++ )); do printf "  %s%-8s%s" "$B" "${LBL[$i]}" "$R"; done
  echo
  # Détail (valeurs absolues), tronqué à 8 car. pour préserver l'alignement.
  printf "      "
  for (( i=0; i<n; i++ )); do printf "  %s%-8.8s%s" "$DIM" "${DET[$i]}" "$R"; done
  echo
}

show() {
  local cpu_model cores ram_total
  cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
  cores=$(nproc)
  ram_total=$(free -h | awk '/^Mem:/{print $2}')

  echo "${B}${CYA}━━━ Puissance de calcul vs hardware ━━━${R}   ${DIM}$(date '+%H:%M:%S')${R}"
  echo "${DIM}$cpu_model · ${cores} threads · $ram_total RAM · RTX 3080 10 Go${R}"
  echo

  # ── Collecte des 4 métriques ────────────────────────────────────────────────
  local gpu_util=0 vram_pct=0 cpu_use=0 ram_pct=0
  local gpu_det="n/a" vram_det="n/a" cpu_det="n/a" ram_det="n/a"
  local gtemp="" gpow=""

  if command -v nvidia-smi >/dev/null 2>&1; then
    local g name util memu memt temp pdraw plim
    g=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit \
        --format=csv,noheader,nounits 2>/dev/null)
    IFS=',' read -r util memu memt temp pdraw plim <<<"$g"
    gpu_util=$(echo "$util" | xargs)
    memu=$(echo "$memu" | xargs); memt=$(echo "$memt" | xargs)
    vram_pct=$(( memu * 100 / memt ))
    gpu_det="${gpu_util}% load"
    vram_det="${memu}M"
    gtemp=$(echo "$temp" | xargs); gpow=$(echo "$pdraw" | xargs | cut -d. -f1)
  fi

  local cpu_idle
  cpu_idle=$(top -bn1 | awk '/%Cpu|Cpu\(s\)/{for(i=1;i<=NF;i++) if($i ~ /id/){gsub(/[^0-9.]/,"",$i); print $i}}' | head -1)
  cpu_use=$(awk "BEGIN{printf \"%d\", 100 - ${cpu_idle:-100}}")
  local load1; load1=$(awk '{print $1}' /proc/loadavg)
  cpu_det="L${load1}"      # load average 1 min (tronqué à la largeur de colonne)

  local mem_total mem_used
  read -r mem_total mem_used <<<"$(free -m | awk '/^Mem:/{print $2" "$3}')"
  ram_pct=$(( mem_used * 100 / mem_total ))
  ram_det="${mem_used}M"

  # ── Histogramme ─────────────────────────────────────────────────────────────
  local pcts=("$gpu_util" "$vram_pct" "$cpu_use" "$ram_pct")
  local lbls=("GPU" "VRAM" "CPU" "RAM")
  local dets=("$gpu_det" "$vram_det" "$cpu_det" "$ram_det")
  draw_hist pcts lbls dets

  # ── Ligne de contexte GPU ───────────────────────────────────────────────────
  if [ -n "$gtemp" ]; then
    echo
    echo "${DIM}GPU : ${gtemp}°C · ${gpow} W${R}"
    local proc
    proc=$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>/dev/null | head -1)
    [ -n "$proc" ] && echo "${DIM}calcul GPU : ${proc}${R}" \
                   || echo "${DIM}(aucun modèle chargé sur le GPU)${R}"
  fi
}

# ── Mode watch ou instantané ─────────────────────────────────────────────────
case "${1:-}" in
  -w|--watch)
    interval="${2:-2}"
    trap 'tput cnorm 2>/dev/null; echo; exit 0' INT
    tput civis 2>/dev/null
    while true; do
      clear; show
      echo; echo "${DIM}rafraîchi toutes les ${interval}s — Ctrl-C pour quitter${R}"
      sleep "$interval"
    done
    ;;
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -10
    ;;
  *)
    show
    ;;
esac
