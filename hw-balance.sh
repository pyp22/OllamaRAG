#!/usr/bin/env bash
# hw-balance.sh : répartiteur de charge matérielle de la stack OllamaRAG.
#
# La RTX 3080 (10 Go) est la ressource RARE ; le CPU i9-12900K (24 threads) et
# la RAM (62 Go) sont ABONDANTS. Le déséquilibre par défaut : docling réserve
# ~3,3 Go de VRAM en PERMANENCE (DOCLING_DEVICE=cuda), même sans OCR en cours,
# ce qui prive Ollama du KV cache → « cudaMalloc out of memory ».
#
# Ce script arbitre le GPU en fonction de la charge RÉELLE, plutôt que de figer
# un réglage. Deux profils, plus un mode automatique :
#
#   query   → INTERROGATION (Open WebUI). Le GPU va ENTIÈREMENT à Ollama ;
#             docling bascule sur CPU (le 12900K encaisse l'OCR occasionnel).
#             Ollama : NUM_PARALLEL calé sur la VRAM libre.
#   import  → IMPORT/OCR de corpus. docling reprend le GPU SI Ollama en laisse
#             assez ; sinon reste sur CPU. OCR rapide quand la place existe.
#   auto    → décide query/import selon ce qui tourne (défaut).
#   status  → montre la répartition VRAM/CPU/RAM du moment.
#
# Aucun réglage magique ne « partage » 10 Go entre deux processus qui réservent
# chacun leur VRAM : l'équilibrage consiste à donner le GPU à qui en a besoin
# MAINTENANT et à router le reste vers CPU/RAM abondants.
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Créé le : 2026-07-01
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

cd "$(dirname "$0")"

# Seuil (Mo) de VRAM libre en dessous duquel docling NE prend PAS le GPU même en
# import : il faut laisser à Ollama de quoi charger poids + KV cache.
DOCLING_GPU_MIN_FREE_MB="${DOCLING_GPU_MIN_FREE_MB:-6000}"

DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

have() { command -v "$1" >/dev/null 2>&1; }
info() { printf '\033[36m• %s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ── Mesures hardware temps réel ────────────────────────────────────────────
vram_free_mb()  { nvidia-smi --query-gpu=memory.free  --format=csv,noheader,nounits 2>/dev/null | head -1; }
vram_total_mb() { nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1; }
vram_used_mb()  { nvidia-smi --query-gpu=memory.used  --format=csv,noheader,nounits 2>/dev/null | head -1; }
ncpu()          { nproc; }
ram_free_mb()   { free -m | awk '/^Mem:/{print $7}'; }

container_up() { $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
# VRAM réellement consommée par docling (0 s'il est sur CPU ou éteint).
# On ne somme QUE les process GPU dont le PID (hôte) appartient au conteneur
# docling, sinon on compterait la VRAM d'Ollama (même GPU) comme docling.
docling_vram_mb() {
  container_up docling || { echo 0; return 0; }
  # PID hôte de tous les process du conteneur docling.
  local pids
  pids="$($DOCKER top docling -eo pid 2>/dev/null | awk 'NR>1{print $1}')"
  [ -n "$pids" ] || { echo 0; return 0; }
  # Ensemble « |123|456| » pour une correspondance exacte de PID.
  local set="|"; local p; for p in $pids; do set="${set}${p}|"; done
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' -v set="$set" 'BEGIN{s=0}
        index(set,"|"$1"|")>0 {s+=$2}
        END{print s+0}'
}

# ── Réglage Ollama selon la VRAM libre HORS docling ────────────────────────
# En interrogation solo, NUM_PARALLEL=1 : un seul slot → KV cache non dupliqué.
# On ne descend au-dessous que si la place manque vraiment.
apply_ollama() {
  local parallel="$1"
  container_up ollama || { warn "ollama non démarré, réglage Ollama ignoré."; return 0; }
  # Réglages passés en variables d'env : on recrée le seul service ollama pour
  # les appliquer (idempotent si déjà à la bonne valeur).
  OLLAMA_NUM_PARALLEL="$parallel" \
    $DOCKER compose up -d --no-deps ollama >/dev/null 2>&1 \
    && ok "Ollama : NUM_PARALLEL=$parallel (KV cache dimensionné pour la VRAM libre)." \
    || warn "Ollama : impossible d'appliquer NUM_PARALLEL=$parallel."
}

# ── Bascule docling GPU ⇄ CPU (variable d'env → recreate sans rebuild) ──────
set_docling_device() {
  local dev="$1"   # cuda | cpu
  container_up docling || { warn "docling non démarré."; return 0; }
  DOCLING_DEVICE="$dev" $DOCKER compose up -d --no-deps docling >/dev/null 2>&1 \
    && ok "docling : DEVICE=$dev." \
    || warn "docling : bascule DEVICE=$dev impossible."
}

# ── Profils ────────────────────────────────────────────────────────────────
profile_query() {
  info "Profil INTERROGATION : GPU → Ollama, docling → CPU (12900K)."
  set_docling_device cpu
  apply_ollama 1
  status
}

profile_import() {
  info "Profil IMPORT/OCR : docling prend le GPU si la place existe."
  # On mesure la VRAM libre APRÈS avoir mis docling au repos, pour décider.
  local free; free="$(vram_free_mb)"; free="${free:-0}"
  # VRAM que docling libérerait s'il est déjà sur GPU (pour raisonner « à froid »).
  local dv; dv="$(docling_vram_mb)"; dv="${dv:-0}"
  local free_wo_docling=$(( free + dv ))
  if [ "$free_wo_docling" -ge "$DOCLING_GPU_MIN_FREE_MB" ]; then
    ok "VRAM libre hors docling ≈ ${free_wo_docling} Mo ≥ ${DOCLING_GPU_MIN_FREE_MB} → docling sur GPU."
    set_docling_device cuda
  else
    warn "VRAM libre hors docling ≈ ${free_wo_docling} Mo < ${DOCLING_GPU_MIN_FREE_MB} → docling reste sur CPU (Ollama prioritaire)."
    set_docling_device cpu
  fi
  # Pendant l'import on n'interroge pas en parallèle massif : 1 slot suffit et
  # laisse la VRAM à docling. (L'utilisateur peut relancer « query » après.)
  apply_ollama 1
  status
}

profile_auto() {
  # Heuristique : si docling OCRise réellement (process torch/tesseract actif),
  # on est en import → profil import ; sinon interrogation → query.
  if container_up docling && \
     $DOCKER exec docling sh -c 'ps -e 2>/dev/null | grep -qiE "tesseract|easyocr|ocr"' 2>/dev/null; then
    info "Auto : OCR détecté → profil IMPORT."
    profile_import
  else
    info "Auto : pas d'OCR en cours → profil INTERROGATION."
    profile_query
  fi
}

# ── État de la répartition matérielle ──────────────────────────────────────
status() {
  local vt vf vu dv np
  vt="$(vram_total_mb)"; vf="$(vram_free_mb)"; vu="$(vram_used_mb)"
  dv="$(docling_vram_mb)"
  echo
  printf '\033[1m── Répartition matérielle ──────────────────────────\033[0m\n' >&2
  printf '  GPU  RTX 3080 : %s Mo total  |  %s utilisés  |  %s libres\n' "$vt" "$vu" "$vf" >&2
  printf '                  dont docling : %s Mo %s\n' "$dv" "$([ "${dv:-0}" -gt 0 ] && echo '(sur GPU)' || echo '(sur CPU / éteint)')" >&2
  printf '  CPU  i9-12900K : %s threads\n' "$(ncpu)" >&2
  printf '  RAM           : %s Mo libres\n' "$(ram_free_mb)" >&2
  if container_up ollama; then
    np="$($DOCKER exec ollama printenv OLLAMA_NUM_PARALLEL 2>/dev/null || echo '?')"
    printf '  Ollama        : NUM_PARALLEL=%s\n' "$np" >&2
  fi
  echo >&2
}

# ── Dispatch ───────────────────────────────────────────────────────────────
case "${1:-auto}" in
  query|interrogation) profile_query ;;
  import|ocr)          profile_import ;;
  auto)                profile_auto ;;
  status)              status ;;
  -h|--help)           usage 0 ;;
  *)                   err "commande inconnue : ${1:-}"; usage 1 ;;
esac
