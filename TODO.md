# OllamaRAG, liste des choses à faire

Auteur  : Pierre-Yves PARANTHOEN <nuxsfm@gmail.com>
Créé le : 2026-06-24
Licence : CC BY-NC-SA 4.0, https://creativecommons.org/licenses/by-nc-sa/4.0/

Pense-bête des décisions et tâches en attente sur le projet. Cocher une fois
fait, déplacer dans « Fait » avec la date.

## À décider / à faire

- [ ] **Garder la session graphique ou non.** Le bureau (Xorg + gnome +
  navigateur) occupe ~1,9 Go de VRAM sur les 10 Go de la RTX 3080. En l'enlevant
  (machine headless, accès SSH), on récupère ces ~1,9 Go pour la génération, ce
  qui rapprocherait le 14b d'un chargement full-GPU. Décision actuelle : on
  garde le bureau. À trancher, et le cas échéant figer le choix : soit dans la
  conf Docker / le service (pas de réservation GPU pour rien), soit au niveau du
  système (cible multi-user.target sans serveur graphique). Voir la section
  « Exploiter le maximum du GPU » du README et gpu-mode.sh.

- [ ] **Empêcher Windows de recréer les fichiers parasites dans le corpus.**
  Thumbs.db, pspbrwse.jbf, desktop.ini réapparaissent dès qu'on navigue dans le
  corpus depuis un poste Windows. import-corpus.py les ignore déjà
  silencieusement (fait, voir plus bas), mais ils reviennent sur le disque.
  Option à mettre en place : ajouter une directive `veto files` (et
  `delete veto files = yes`) dans corpus.smb.conf pour que le partage Samba ne
  les crée carrément plus. À décider et appliquer.

- [ ] **Reconnaissance de l'écriture cursive (manuscrite) — HTR.** L'OCR actuel
  (Docling + EasyOCR, `DOCLING_PIPELINE_OCR_ENGINE=easyocr`) lit le texte
  IMPRIMÉ/dactylographié mais PAS l'écriture cursive : EasyOCR est de l'OCR, pas
  de l'HTR (Handwritten Text Recognition). Les archives Pleumeur-Bodou 1962-1965
  contiennent des notes et comptes rendus manuscrits qui passent mal voire pas
  du tout. Pistes 100 % local à évaluer sur une vraie page manuscrite du corpus :
    - VLM déjà installé (`llava:7b`, ou Qwen-VL) : souvent correct sur du
      manuscrit récent, sans entraînement. À benchmarker en premier (gratuit).
    - TrOCR (microsoft/trocr-*-handwritten) : HTR Hugging Face, surtout anglais.
    - Kraken / eScriptorium : HTR pensé pour les archives, entraînable sur
      l'écriture du fonds (le plus robuste mais demande du travail).
  Action : tester EasyOCR vs un VLM sur la même page manuscrite, comparer le
  rendu, puis décider quoi intégrer (et où, dans la pipeline d'import).

## Fait

- [x] **2026-06-24 — Parasites Windows ignorés à l'import.** import-corpus.py
  saute désormais SILENCIEUSEMENT Thumbs.db, desktop.ini, .DS_Store et les .jbf
  (pspbrwse.jbf), au lieu de les signaler comme « format non géré ». Les 25
  fichiers parasites déjà présents dans corpus/ ont aussi été supprimés.
