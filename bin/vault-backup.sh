#!/usr/bin/env bash
# ===============================================================
# vault-backup.sh — Sauvegarde CHIFFRÉE d'un dossier (coffre de notes, etc.)
# ===============================================================
# Produit une archive .tar.gz.age (ciphertext) déposable n'importe où :
# cloud, clé USB, disque externe.
#
#   - Chiffrement CÔTÉ CLIENT (age) : le stockage ne voit QUE du chiffré.
#   - Passphrase jamais stockée, jamais loguée, jamais passée en argument.
#   - Aucun fichier clair intermédiaire (tar → age en pipe).
#   - Empreinte SHA-256 de l'archive écrite à côté (<archive>.sha256).
#
# Usage :
#   vault-backup.sh -s SOURCE -o DOSSIER_SORTIE [-m auto|key|pass]
#                   [-r FICHIER_RECIPIENT] [-x MOTIF]...
#
#   -s  dossier à sauvegarder                   (ou VAULT_SOURCE)
#   -o  dossier où écrire l'archive             (ou VAULT_BACKUP_DIR)
#   -m  auto (défaut) : clé si un recipient existe, sinon passphrase
#       key  : chiffre pour la clé publique age, sans prompt (automatisable)
#       pass : passphrase interactive (age -p)
#   -r  fichier contenant la clé publique age  (ou VAULT_BACKUP_RECIPIENT_FILE,
#       défaut : ~/.config/vault-backup/recipient.txt, créé par vault-key-setup.sh)
#   -x  chemin à exclure, relatif à SOURCE (répétable), ex. -x raw -x .trash
#
# Restauration : voir vault-restore.sh
# ===============================================================
set -euo pipefail

SOURCE="${VAULT_SOURCE:-}"
OUT_DIR="${VAULT_BACKUP_DIR:-}"
METHOD="auto"
RECIP_FILE="${VAULT_BACKUP_RECIPIENT_FILE:-$HOME/.config/vault-backup/recipient.txt}"
EXCLUDES=()

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "❌ $*" >&2; exit 1; }

while getopts ":s:o:m:r:x:h" opt; do
  case "$opt" in
    s) SOURCE="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    m) METHOD="$OPTARG" ;;
    r) RECIP_FILE="$OPTARG" ;;
    x) EXCLUDES+=("$OPTARG") ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG : valeur manquante" ;;
    *) die "option inconnue : -$OPTARG (voir -h)" ;;
  esac
done

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi
}

# --- pré-checks ---
[ -n "$SOURCE" ]  || die "dossier source manquant (-s ou VAULT_SOURCE)"
[ -n "$OUT_DIR" ] || die "dossier de sortie manquant (-o ou VAULT_BACKUP_DIR)"
[ -d "$SOURCE" ]  || die "source introuvable : $SOURCE"
command -v age >/dev/null 2>&1 || die "'age' non installé (https://age-encryption.org)"

SOURCE="$(cd "$SOURCE" && pwd -P)"
PARENT="$(dirname "$SOURCE")"
BASE="$(basename "$SOURCE")"

# chemin absolu canonique, même si le dossier n'existe pas encore
canon_path() {
  local p="$1" rest=""
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ]; do
    rest="/$(basename "$p")$rest"
    p="$(dirname "$p")"
  done
  printf '%s%s\n' "$(cd "$p" && pwd -P)" "$rest"
}
case "$(canon_path "$OUT_DIR")/" in
  "$SOURCE"/*) die "le dossier de sortie ne doit pas être dans la source" ;;
esac
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

USE_KEY=0
case "$METHOD" in
  key)  USE_KEY=1 ;;
  auto) [ -f "$RECIP_FILE" ] && USE_KEY=1 ;;
  pass) ;;
  *) die "méthode inconnue : $METHOD (attendu : auto | key | pass)" ;;
esac

TAR_ARGS=()
for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
  x="${x#./}"; x="${x%/}"
  TAR_ARGS+=("--exclude=$BASE/$x")
done

STAMP="$(date +%Y-%m-%d_%H%M%S)"
NAME="${BASE}-${STAMP}.tar.gz.age"
OUT="$OUT_DIR/$NAME"
[ -e "$OUT" ] && die "l'archive existe déjà : $OUT"

echo "──────────────────────────────────────────────"
echo "  Sauvegarde chiffrée"
echo "  Source : $SOURCE"
echo "  Sortie : $OUT"
[ "${#EXCLUDES[@]}" -gt 0 ] && echo "  Exclus : ${EXCLUDES[*]}"
echo "──────────────────────────────────────────────"

umask 077
if [ "$USE_KEY" = 1 ]; then
  [ -f "$RECIP_FILE" ] || die "recipient introuvable ($RECIP_FILE). Lance d'abord vault-key-setup.sh"
  echo "→ Chiffrement par CLÉ publique ($RECIP_FILE) — sans passphrase, automatisable."
  tar ${TAR_ARGS[@]+"${TAR_ARGS[@]}"} -czf - -C "$PARENT" "$BASE" | age -R "$RECIP_FILE" -o "$OUT"
else
  echo "→ Chiffrement par PASSPHRASE (age la demande 2×). Ni affichée, ni stockée, ni loguée."
  echo "  ⚠️  Sans elle, l'archive est irrécupérable. Garde-la hors du stockage de l'archive."
  tar ${TAR_ARGS[@]+"${TAR_ARGS[@]}"} -czf - -C "$PARENT" "$BASE" | age -p -o "$OUT"
fi
chmod 600 "$OUT"

# empreinte d'intégrité, nom relatif pour pouvoir vérifier après transfert
( cd "$OUT_DIR" && sha256_file "$NAME" > "$NAME.sha256" )

echo
echo "✅ Archive chiffrée : $OUT"
echo "   Taille    : $(du -h "$OUT" | cut -f1)"
echo "   Empreinte : $OUT.sha256"
echo
echo "🔎 Vérifier l'intégrité après transfert (dans le dossier de l'archive) :"
echo "     shasum -a 256 -c '$NAME.sha256'"
echo "♻️  Restaurer : vault-restore.sh '$OUT' <dossier_vide>"
