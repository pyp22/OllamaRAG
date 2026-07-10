#!/usr/bin/env bash
# OCR autonome. Moteur PAR DÉFAUT : Tesseract sur les N cœurs CPU.
#
# Sur les scans d'archives anciens, Tesseract bat nettement EasyOCR (séparation
# des mots, accents, moins de confusions de lettres), d'où le défaut CPU. La file
# GPU/EasyOCR (Docling, l'OCR « du projet ») reste disponible en OPT-IN pour qui
# veut le débit GPU, et tourne alors EN MÊME TEMPS que la file CPU :
#   • File CPU  : Tesseract sur les N cœurs (PDF rasterisés par pdftoppm, images
#                 directes). N'occupe pas la VRAM, cohabite avec Ollama. [DÉFAUT]
#   • File GPU  : Docling/EasyOCR CUDA (cf. docling_ocr.py). POST /v1/convert/file,
#                 do_ocr+force_ocr. Concurrence basse car le GPU traite une image à
#                 la fois (au-delà → 504). [OPT-IN : --gpu-jobs N | --only gpu]
# Quand les deux files sont actives, un répartiteur leur partage le corpus →
# CPU, RAM, GPU et VRAM sollicités simultanément.
#
# Traite PDF + images courantes. Accepte fichiers ET répertoires (récursifs).
#
#   ./ocr.sh document.pdf scan.jpg                 # fichiers (CPU/Tesseract = défaut)
#   ./ocr.sh corpus/                                # répertoire récursif (CPU)
#   ./ocr.sh -o sortie/ corpus/                     # .md regroupés dans sortie/
#   ./ocr.sh --only gpu corpus/                     # GPU/EasyOCR seul
#   ./ocr.sh --only cpu+gpu corpus/                 # les deux files EN PARALLÈLE
#   ./ocr.sh --preprocess sharp corpus/             # scans très dégradés (+ unsharp)
#   ./ocr.sh --preprocess none corpus/              # image brute (désactive deskew)
#
# Sortie : <fichier.ext>.md à côté de la source (ou dans -o DIR, noms aplatis).
#
# Réglages (mêmes défauts que docling_ocr.py côté GPU) :
#   DOCLING_URL          (défaut http://localhost:5001)
#   DOCLING_OCR_ENGINE   (défaut easyocr)   DOCLING_OCR_LANG (défaut fr,en)
#   DOCLING_OCR_TIMEOUT  (défaut 900)        TESS_LANG       (défaut fra+eng)
#   OCR_DPI              (défaut 300, rasterisation PDF côté CPU)
#   OCR_PREPROCESS       (défaut deskew ; none|deskew|sharp ; cf. --preprocess)
#
# Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
# Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
DOCLING_URL="${DOCLING_URL:-http://localhost:5001}"; DOCLING_URL="${DOCLING_URL%/}"
OCR_ENGINE="${DOCLING_OCR_ENGINE:-easyocr}"
OCR_LANG="${DOCLING_OCR_LANG:-fr,en}"
OCR_TIMEOUT="${DOCLING_OCR_TIMEOUT:-900}"
TESS_LANG="${TESS_LANG:-fra+eng}"
OCR_DPI="${OCR_DPI:-300}"
# Pré-traitement image (file CPU/Tesseract uniquement) : none | deskew | sharp.
# deskew (défaut) = grayscale + redressement : sûr, corrige des confusions de lettres
# sur scans inclinés (ex. NATIONAT→NATIONAL) sans rien casser. sharp = + unsharp 0x3,
# plus agressif (récupère des titres très dégradés, ex. ERHCTION→ERECTION) mais peut
# abîmer d'autres mots → à réserver aux scans difficiles. Requiert ImageMagick (convert).
PREPROCESS="${OCR_PREPROCESS:-deskew}"

NCPU="$(nproc)"
# File CPU/Tesseract = moteur PAR DÉFAUT. Sur les scans d'archives anciens,
# Tesseract bat nettement EasyOCR : il sépare les mots, gère les accents (ç, è)
# et confond moins les lettres. EasyOCR (conçu pour scènes/photos) colle les mots
# et substitue des caractères sur du texte dense → titres du type
# « EXPOSEGENERAL DES MBTHODES D'BRBCTION » au lieu de « EXPOSE GENERAL… ».
# On garde ~4 cœurs pour le système et la rasterisation. Tesseract est mono-thread
# par page → on lance ~ (cœurs-4) instances en parallèle.
CPU_JOBS=$(( NCPU > 6 ? NCPU - 4 : 2 ))
# File GPU/EasyOCR : OPT-IN via --only gpu / --only cpu+gpu.
# 2 = sweet spot 3080 (cf. docling_ocr.py, au-delà → 504).
GPU_JOBS=2

EXTS_REGEX='\.(pdf|png|jpg|jpeg|tif|tiff|bmp|webp|gif)$'
OUT_DIR=""; PRINT=0; FORCE_OCR="true"
# Sélection des moteurs (défaut : CPU seul). --only la redéfinit.
WANT_CPU=1; WANT_GPU=0

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
err()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
info() { printf '\033[36m• %s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*" >&2; }

# ── Arguments ─────────────────────────────────────────────────────────────
FILES_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)   OUT_DIR="${2:?-o requiert un répertoire}"; shift 2 ;;
    --gpu-jobs)    GPU_JOBS="${2:?}"; shift 2 ;;
    --cpu-jobs)    CPU_JOBS="${2:?}"; shift 2 ;;
    --only)        # cpu | gpu | cpu+gpu (séparateur +, ordre libre)
                   sel="${2:?cpu|gpu|cpu+gpu}"; WANT_CPU=0; WANT_GPU=0
                   IFS='+,' read -ra _parts <<< "$sel"
                   for p in "${_parts[@]}"; do case "$p" in
                     cpu) WANT_CPU=1 ;; gpu) WANT_GPU=1 ;;
                     *) err "--only : valeur inconnue '$p' (attendu cpu|gpu|cpu+gpu)"; usage 1 ;;
                   esac; done
                   [ "$WANT_CPU" -eq 1 ] || [ "$WANT_GPU" -eq 1 ] || { err "--only vide"; usage 1; }
                   shift 2 ;;
    --preprocess)  PREPROCESS="${2:?none|deskew|sharp}"
                   case "$PREPROCESS" in none|deskew|sharp) ;;
                     *) err "--preprocess : valeur inconnue '$PREPROCESS' (attendu none|deskew|sharp)"; usage 1 ;;
                   esac; shift 2 ;;
    -p|--print)    PRINT=1; shift ;;
    --no-force)    FORCE_OCR="false"; shift ;;
    -h|--help)     usage 0 ;;
    --)            shift; while [ $# -gt 0 ]; do FILES_ARGS+=("$1"); shift; done ;;
    -*)            err "option inconnue : $1"; usage 1 ;;
    *)             FILES_ARGS+=("$1"); shift ;;
  esac
done
[ ${#FILES_ARGS[@]} -gt 0 ] || { err "aucun fichier ni répertoire fourni"; usage 1; }

# ── Détection des moteurs disponibles ─────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
have curl || { err "curl requis"; exit 1; }

GPU_OK=0; CPU_OK=0
# On ne probe chaque moteur que s'il est demandé (WANT_*, défini par --only ; défaut CPU).
if [ "$WANT_CPU" -eq 1 ]; then
  if have tesseract; then CPU_OK=1
  else err "tesseract absent → file CPU désactivée (sudo apt install tesseract-ocr tesseract-ocr-fra)."; fi
fi
if [ "$WANT_GPU" -eq 1 ]; then
  if curl -fsS --max-time 5 "$DOCLING_URL/health" >/dev/null 2>&1; then GPU_OK=1
  else err "Docling injoignable sur $DOCLING_URL → file GPU désactivée (./start-ollama.sh up)."; fi
fi
[ "$CPU_OK" -eq 1 ] || CPU_JOBS=0
[ "$GPU_OK" -eq 1 ] || GPU_JOBS=0
[ "$GPU_OK" -eq 1 ] || [ "$CPU_OK" -eq 1 ] || { err "aucun moteur OCR disponible."; exit 1; }

# Preprocessing (file CPU) : si demandé mais ImageMagick absent → on prévient et on
# retombe sur l'image brute (prep_img gère le fallback, ici on l'annonce une fois).
if [ "$CPU_JOBS" -gt 0 ] && [ "$PREPROCESS" != "none" ] && ! have convert; then
  err "ImageMagick (convert) absent → --preprocess ignoré (sudo apt install imagemagick). Image brute."
  PREPROCESS="none"
fi

GPU_DESC=$([ "$GPU_JOBS" -gt 0 ] && echo "${GPU_JOBS} (easyocr/cuda)" || echo "off (--only gpu | --only cpu+gpu)")
PP_DESC=$([ "$PREPROCESS" = "none" ] && echo "" || echo ", prep=${PREPROCESS}")
CPU_DESC=$([ "$CPU_JOBS" -gt 0 ] && echo "${CPU_JOBS} (tesseract ${TESS_LANG}${PP_DESC})" || echo "off")
info "Hardware : ${NCPU} cœurs CPU | file CPU=${CPU_DESC} | file GPU=${GPU_DESC}"

[ -n "$OUT_DIR" ] && mkdir -p "$OUT_DIR"

# ── Collecte des fichiers (développe les répertoires) ─────────────────────
COLLECT="$(mktemp)"; trap 'rm -f "$COLLECT"' EXIT
for arg in "${FILES_ARGS[@]}"; do
  if [ -d "$arg" ]; then
    find "$arg" -type f -regextype posix-extended -iregex ".*$EXTS_REGEX" -print0 >> "$COLLECT"
  elif [ -f "$arg" ]; then
    printf '%s' "$arg" | grep -Eiq "$EXTS_REGEX" && printf '%s\0' "$arg" >> "$COLLECT" \
      || err "format non géré, ignoré : $arg"
  else err "introuvable, ignoré : $arg"; fi
done
# Écarte les fichiers vides (0 octet) : aucun OCR n'en sortira, et un upload
# vide vers Docling risque un 504. On reconstruit la liste sans eux.
if [ -s "$COLLECT" ]; then
  FILTERED="$(mktemp)"
  while IFS= read -r -d '' f; do
    if [ -s "$f" ]; then printf '%s\0' "$f" >> "$FILTERED"
    else err "fichier vide (0 octet), ignoré : $f"; fi
  done < "$COLLECT"
  mv "$FILTERED" "$COLLECT"
fi
TOTAL=$(tr -cd '\0' < "$COLLECT" | wc -c)
[ "$TOTAL" -gt 0 ] || { err "aucun fichier OCR-isable."; exit 1; }
info "$TOTAL fichier(s) à traiter."

# ── Chemin de sortie .md ──────────────────────────────────────────────────
out_path_for() {
  local src="$1"
  if [ -z "$OUT_DIR" ]; then printf '%s.md' "$src"; return; fi
  local flat="${src#./}"; flat="${flat//\//_}"
  local cand="$OUT_DIR/${flat}.md" n=1
  while [ -e "$cand" ]; do cand="$OUT_DIR/${flat}.$n.md"; n=$((n+1)); done
  printf '%s' "$cand"
}

# ── Moteur GPU : Docling/EasyOCR CUDA (l'OCR du projet) ────────────────────
ocr_gpu() {
  local src="$1" resp
  resp="$(curl -fsS --max-time "$OCR_TIMEOUT" \
    -F "files=@${src}" -F "do_ocr=true" -F "force_ocr=${FORCE_OCR}" \
    -F "ocr_engine=${OCR_ENGINE}" -F "ocr_lang=${OCR_LANG}" \
    -F "image_export_mode=placeholder" -F "to_formats=md" \
    "$DOCLING_URL/v1/convert/file" 2>/dev/null)" || return 1
  if have jq; then
    printf '%s' "$resp" | jq -r '.document.md_content // .document.text_content // empty'
  else
    printf '%s' "$resp" | python3 -c \
      'import sys,json;d=json.load(sys.stdin).get("document",{})or{};print(d.get("md_content")or d.get("text_content")or"")' 2>/dev/null
  fi
}

# Pré-traitement image avant Tesseract (file CPU). Écrit l'image traitée dans
# "$2" et renvoie ce chemin ; si PREPROCESS=none ou ImageMagick absent, renvoie
# l'image d'origine inchangée. deskew = Gray+redressement (sûr) ; sharp = + unsharp.
prep_img() {
  local in="$1" out="$2"
  [ "$PREPROCESS" = "none" ] && { printf '%s' "$in"; return; }
  have convert || { printf '%s' "$in"; return; }   # fallback silencieux : image brute
  local ops="-colorspace Gray -deskew 40%"
  [ "$PREPROCESS" = "sharp" ] && ops="$ops -unsharp 0x3"
  if convert "$in" $ops "$out" 2>/dev/null; then printf '%s' "$out"
  else printf '%s' "$in"; fi                        # si convert échoue : image brute
}

# ── Moteur CPU : Tesseract (PDF rasterisé par pdftoppm, image directe) ─────
ocr_cpu() {
  local src="$1" ext tmp page img txt all=""
  ext="$(printf '%s' "${src##*.}" | tr 'A-Z' 'a-z')"
  if [ "$ext" = "pdf" ]; then
    have pdftoppm || { err "pdftoppm absent (poppler-utils) : $src"; return 1; }
    tmp="$(mktemp -d)"
    # Rasterise toutes les pages à OCR_DPI, puis (option) pré-traite, puis Tesseract.
    pdftoppm -r "$OCR_DPI" -png "$src" "$tmp/p" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    for page in "$tmp"/p*.png; do
      [ -e "$page" ] || continue
      img="$(prep_img "$page" "$tmp/prep.png")"
      txt="$(tesseract "$img" stdout -l "$TESS_LANG" 2>/dev/null)" || true
      all+="$txt"$'\n\n'
    done
    rm -rf "$tmp"
    printf '%s' "$all"
  else
    tmp="$(mktemp -d)"
    img="$(prep_img "$src" "$tmp/prep.png")"
    txt="$(tesseract "$img" stdout -l "$TESS_LANG" 2>/dev/null)" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    printf '%s' "$txt"
  fi
}

# ── Traitement d'un fichier par une file donnée ───────────────────────────
process() {
  local engine="$1" src="$2" dst txt n d
  dst="$(out_path_for "$src")"
  SECONDS=0   # chrono propre à ce fichier (chaque process = sous-shell xargs isolé)
  if [ "$engine" = "gpu" ]; then txt="$(ocr_gpu "$src")" || { err "[GPU] échec : $src"; return 1; }
  else                           txt="$(ocr_cpu "$src")" || { err "[CPU] échec : $src"; return 1; }; fi
  n=${#txt}
  [ "$n" -gt 0 ] || { err "[${engine^^}] aucun texte : $src"; return 1; }
  printf '%s\n' "$txt" > "$dst"
  d=$(printf '%dm%02ds' $((SECONDS/60)) $((SECONDS%60)))
  ok "[${engine^^}] $src → $dst  (${n} car., ${d})"
  [ "$PRINT" -eq 1 ] && { printf '\n===== %s (%s) =====\n%s\n' "$src" "$engine" "$txt"; }
  return 0
}
export -f process ocr_gpu ocr_cpu out_path_for prep_img err ok have
export DOCLING_URL OCR_ENGINE OCR_LANG OCR_TIMEOUT FORCE_OCR TESS_LANG OCR_DPI OUT_DIR PRINT PREPROCESS

# ── Répartiteur : deux files xargs concurrentes, partage round-robin ──────
# Les fichiers d'index PAIR partent sur le GPU, IMPAIR sur le CPU (si les deux
# files sont actives). Les deux xargs tournent EN MÊME TEMPS en arrière-plan.
GPU_LIST="$(mktemp)"; CPU_LIST="$(mktemp)"
trap 'rm -f "$COLLECT" "$GPU_LIST" "$CPU_LIST"' EXIT

i=0
while IFS= read -r -d '' f; do
  if   [ "$GPU_JOBS" -gt 0 ] && [ "$CPU_JOBS" -gt 0 ]; then
    # Pondère : le GPU est plus rapide → il prend ~2/3 des fichiers.
    if [ $(( i % 3 )) -eq 0 ]; then printf '%s\0' "$f" >> "$CPU_LIST"
    else                            printf '%s\0' "$f" >> "$GPU_LIST"; fi
  elif [ "$GPU_JOBS" -gt 0 ]; then  printf '%s\0' "$f" >> "$GPU_LIST"
  else                              printf '%s\0' "$f" >> "$CPU_LIST"; fi
  i=$((i+1))
done < "$COLLECT"

RC_FILE="$(mktemp)"; echo 0 > "$RC_FILE"
run_queue() {  # $1=engine  $2=list  $3=jobs
  local engine="$1" list="$2" jobs="$3"
  [ "$jobs" -gt 0 ] || return 0
  [ -s "$list" ] || return 0
  xargs -0 -P "$jobs" -I{} bash -c 'process "$0" "$@"' "$engine" {} < "$list" \
    || echo 1 > "$RC_FILE"
}

info "Lancement des files en parallèle…"
SECONDS=0                       # chrono : temps de traitement (hors collecte)
PIDS=()
run_queue gpu "$GPU_LIST" "$GPU_JOBS" & PIDS+=($!)
run_queue cpu "$CPU_LIST" "$CPU_JOBS" & PIDS+=($!)
for p in "${PIDS[@]}"; do wait "$p" || true; done

RC=$(cat "$RC_FILE"); rm -f "$RC_FILE"

# Bilan : durée selon les moteurs effectivement actifs (le choix des options).
ELAPSED=$SECONDS
DUR=$(printf '%dm%02ds' $((ELAPSED/60)) $((ELAPSED%60)))
ENGINES=""
[ "$CPU_JOBS" -gt 0 ] && ENGINES="CPU/tesseract×${CPU_JOBS}"
[ "$GPU_JOBS" -gt 0 ] && ENGINES="${ENGINES:+$ENGINES + }GPU/easyocr×${GPU_JOBS}"
echo
info "Temps : ${DUR} pour ${TOTAL} fichier(s), moteurs : ${ENGINES}"
[ "$RC" -eq 0 ] && ok "Terminé." || err "Terminé avec des erreurs."
exit "$RC"
