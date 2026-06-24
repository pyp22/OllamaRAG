#!/usr/bin/env bash
# Bar graph autonome de l'utilisation des ressources GPU + CPU.
# Histogramme vertical ASCII : GPU (calcul), VRAM, CPU (calcul), RAM.
# Aucune dépendance hors nvidia-smi (GPU) et les outils système de base.
#
# Usage : ./gpu-cpu-bar.sh            instantané unique
#         ./gpu-cpu-bar.sh --watch    rafraîchi toutes les 2 s (Ctrl-C pour quitter)
#         ./gpu-cpu-bar.sh -w 5       rafraîchi toutes les 5 s
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-06-18
# Licence : CC BY-NC-SA 4.0 — https://creativecommons.org/licenses/by-nc-sa/4.0/
set -uo pipefail

B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYA=$'\033[1;36m'

HEIGHT=12          # hauteur de l'histogramme (lignes)

col_for() {
  local p=$1
  if   [ "$p" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 70 ]; then printf '%s' "$YEL"
  else printf '%s' "$GRN"; fi
}

# Histogramme vertical. Args (par nom) : tableaux PCT, LBL, DET.
draw_hist() {
  local -n PCT=$1 LBL=$2 DET=$3
  local n=${#PCT[@]} row i p bartop color
  local full='████████'

  for (( row=HEIGHT; row>=1; row-- )); do
    printf "%s%3d%%%s │" "$DIM" "$(( row * 100 / HEIGHT ))" "$R"
    for (( i=0; i<n; i++ )); do
      p=${PCT[$i]}; bartop=$(( p * HEIGHT / 100 )); color=$(col_for "$p")
      if [ "$bartop" -ge "$row" ]; then printf "  %s%s%s" "$color" "$full" "$R"
      else printf "  %s········%s" "$DIM" "$R"; fi
    done
    echo
  done

  printf "     └"; for (( i=0; i<n; i++ )); do printf "───────────"; done; echo
  printf "      "; for (( i=0; i<n; i++ )); do printf "  %s%6d%%%s " "$(col_for "${PCT[$i]}")" "${PCT[$i]}" "$R"; done; echo
  printf "      "; for (( i=0; i<n; i++ )); do printf "  %s%-8s%s" "$B" "${LBL[$i]}" "$R"; done; echo
  printf "      "; for (( i=0; i<n; i++ )); do printf "  %s%-8.8s%s" "$DIM" "${DET[$i]}" "$R"; done; echo
}

show() {
  echo "${B}${CYA}━━━ Ressources GPU + CPU ━━━${R}   ${DIM}$(date '+%H:%M:%S')${R}"

  # ── GPU ──────────────────────────────────────────────────────────────────
  local gpu_util=0 vram_pct=0 gpu_det="n/a" vram_det="n/a" gtemp="" gpow="" gname=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    local g util memu memt temp pdraw
    g=$(nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null)
    IFS=',' read -r gname util memu memt temp pdraw <<<"$g"
    gname=$(echo "$gname" | xargs); gpu_util=$(echo "$util" | xargs)
    memu=$(echo "$memu" | xargs); memt=$(echo "$memt" | xargs)
    vram_pct=$(( memu * 100 / memt ))
    gpu_det="${gpu_util}%"; vram_det="${memu}M"
    gtemp=$(echo "$temp" | xargs); gpow=$(echo "$pdraw" | xargs | cut -d. -f1)
  fi

  # ── CPU + RAM ────────────────────────────────────────────────────────────
  local cpu_idle cpu_use load1 mem_total mem_used ram_pct
  cpu_idle=$(top -bn1 | awk '/%Cpu|Cpu\(s\)/{for(i=1;i<=NF;i++) if($i ~ /id/){gsub(/[^0-9.]/,"",$i); print $i}}' | head -1)
  cpu_use=$(awk "BEGIN{printf \"%d\", 100 - ${cpu_idle:-100}}")
  load1=$(awk '{print $1}' /proc/loadavg)
  read -r mem_total mem_used <<<"$(free -m | awk '/^Mem:/{print $2" "$3}')"
  ram_pct=$(( mem_used * 100 / mem_total ))

  local pcts=("$gpu_util" "$vram_pct" "$cpu_use" "$ram_pct")
  local lbls=("GPU" "VRAM" "CPU" "RAM")
  local dets=("$gpu_det" "$vram_det" "L${load1}" "${mem_used}M")
  echo "${DIM}${gname:-GPU inconnu} · $(nproc) threads CPU${R}"
  echo
  draw_hist pcts lbls dets

  [ -n "$gtemp" ] && { echo; echo "${DIM}GPU : ${gtemp}°C · ${gpow} W${R}"; }
}

case "${1:-}" in
  -w|--watch)
    interval="${2:-2}"
    trap 'tput cnorm 2>/dev/null; echo; exit 0' INT
    tput civis 2>/dev/null
    while true; do clear; show; echo; echo "${DIM}rafraîchi ${interval}s — Ctrl-C${R}"; sleep "$interval"; done
    ;;
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -9 ;;
  *)
    show ;;
esac
