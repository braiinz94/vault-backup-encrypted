#!/usr/bin/env bash
# ===============================================================
# vault-restore.sh — Restaure une archive .tar.gz.age
# ===============================================================
# Usage :
#   vault-restore.sh [-k SERVICE | -i FICHIER_IDENTITE | -p] ARCHIVE DESTINATION
#
#   -k  identité lue dans le Trousseau macOS (défaut sur macOS ;
#       ou VAULT_BACKUP_KEYCHAIN_SERVICE, défaut : vault-backup-age).
#       L'identité est passée à age par substitution de processus :
#       elle n'est jamais écrite en clair sur le disque.
#   -i  fichier d'identité age (ou VAULT_BACKUP_IDENTITY_FILE) : Linux,
#       gestionnaire de mots de passe (-i <(op read ...)), tests.
#   -p  archive chiffrée par passphrase (age la demande).
#
# DESTINATION doit être absente ou vide (rien n'est écrasé).
# Si ARCHIVE.sha256 existe, l'empreinte est vérifiée avant déchiffrement.
# ===============================================================
set -euo pipefail

SVC="${VAULT_BACKUP_KEYCHAIN_SERVICE:-vault-backup-age}"
IDENTITY="${VAULT_BACKUP_IDENTITY_FILE:-}"
MODE=""
[ -n "$IDENTITY" ] && MODE="file"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "❌ $*" >&2; exit 1; }

while getopts ":k:i:ph" opt; do
  case "$opt" in
    k) SVC="$OPTARG"; MODE="keychain" ;;
    i) IDENTITY="$OPTARG"; MODE="file" ;;
    p) MODE="pass" ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG : valeur manquante" ;;
    *) die "option inconnue : -$OPTARG (voir -h)" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || { usage >&2; exit 1; }
ARCHIVE="$1"
DEST="$2"
[ -n "$MODE" ] || MODE="keychain"

[ -f "$ARCHIVE" ] || die "archive introuvable : $ARCHIVE"
command -v age >/dev/null 2>&1 || die "'age' absent (https://age-encryption.org)"
if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  die "destination non vide : $DEST (rien n'est écrasé)"
fi

# --- intégrité avant déchiffrement ---
if [ -f "$ARCHIVE.sha256" ]; then
  ARCH_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd -P)"
  if command -v shasum >/dev/null 2>&1; then CHECK=(shasum -a 256 -c); else CHECK=(sha256sum -c); fi
  ( cd "$ARCH_DIR" && "${CHECK[@]}" "$(basename "$ARCHIVE").sha256" >/dev/null ) \
    || die "empreinte SHA-256 invalide : archive corrompue ou modifiée"
  echo "→ Empreinte SHA-256 vérifiée."
fi

# --- identité disponible ? (avant de créer quoi que ce soit) ---
case "$MODE" in
  keychain)
    command -v security >/dev/null 2>&1 || die "'security' absent (pas macOS) : utiliser -i ou -p"
    security find-generic-password -s "$SVC" -a "$USER" >/dev/null 2>&1 \
      || die "identité '$SVC' absente du Trousseau (archive chiffrée par passphrase ? utiliser -p)"
    ;;
  file)
    [ -r "$IDENTITY" ] || die "fichier d'identité illisible : $IDENTITY"
    ;;
esac

umask 077
mkdir -p "$DEST"

# en cas d'échec, rien n'est supprimé automatiquement : on prévient seulement
DONE=0
trap '[ "$DONE" = 1 ] || echo "⚠️  Restauration interrompue : $DEST peut contenir des fichiers partiels, à vérifier ou supprimer." >&2' EXIT

case "$MODE" in
  keychain)
    echo "→ Déchiffrement (identité du Trousseau, jamais sur disque) dans : $DEST"
    age -d -i <(security find-generic-password -s "$SVC" -a "$USER" -w) "$ARCHIVE" \
      | tar -xzf - -C "$DEST"
    ;;
  file)
    echo "→ Déchiffrement (fichier d'identité) dans : $DEST"
    age -d -i "$IDENTITY" "$ARCHIVE" | tar -xzf - -C "$DEST"
    ;;
  pass)
    echo "→ Déchiffrement (passphrase) dans : $DEST"
    age -d "$ARCHIVE" | tar -xzf - -C "$DEST"
    ;;
esac

DONE=1
echo "✅ Restauré dans $DEST"
