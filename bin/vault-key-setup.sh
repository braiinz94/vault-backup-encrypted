#!/usr/bin/env bash
# ===============================================================
# vault-key-setup.sh — Génère une clé age et range l'identité privée
#                      dans le Trousseau macOS (Keychain)
# ===============================================================
# Setup unique, à lancer soi-même, une seule fois (macOS uniquement).
# Résultat : sauvegardes chiffrées SANS passphrase (clé publique age),
# donc automatisables (cron/launchd) ; la clé privée reste dans le
# Trousseau (protégé par la session et FileVault), jamais sur disque.
#
# Usage :
#   vault-key-setup.sh [-k SERVICE] [-r FICHIER_RECIPIENT]
#
#   -k  nom de l'entrée du Trousseau (ou VAULT_BACKUP_KEYCHAIN_SERVICE,
#       défaut : vault-backup-age)
#   -r  où écrire la clé publique  (ou VAULT_BACKUP_RECIPIENT_FILE,
#       défaut : ~/.config/vault-backup/recipient.txt)
#
# Refuse d'écraser une clé existante.
# ===============================================================
set -euo pipefail

SVC="${VAULT_BACKUP_KEYCHAIN_SERVICE:-vault-backup-age}"
RECIP_FILE="${VAULT_BACKUP_RECIPIENT_FILE:-$HOME/.config/vault-backup/recipient.txt}"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "❌ $*" >&2; exit 1; }

while getopts ":k:r:h" opt; do
  case "$opt" in
    k) SVC="$OPTARG" ;;
    r) RECIP_FILE="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG : valeur manquante" ;;
    *) die "option inconnue : -$OPTARG (voir -h)" ;;
  esac
done

command -v security >/dev/null 2>&1 || die "commande 'security' absente : ce script est réservé à macOS"
command -v age-keygen >/dev/null 2>&1 || die "age-keygen absent (https://age-encryption.org)"

# --- pas d'écrasement ---
if security find-generic-password -s "$SVC" -a "$USER" >/dev/null 2>&1; then
  echo "⚠️  Entrée '$SVC' déjà présente dans le Trousseau — AUCUN écrasement effectué."
  [ -f "$RECIP_FILE" ] && echo "   Clé publique existante : $RECIP_FILE"
  echo "   (Supprimer l'entrée DÉTRUIT l'accès aux archives existantes : à ne faire qu'en connaissance de cause.)"
  exit 0
fi
[ -e "$RECIP_FILE" ] && die "$RECIP_FILE existe déjà sans entrée '$SVC' au Trousseau : vérifier avant de continuer"

umask 077
RECIP_DIR="$(dirname "$RECIP_FILE")"
mkdir -p "$RECIP_DIR"; chmod 700 "$RECIP_DIR"

TMPDIR_KEY="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_KEY"' EXIT
TMPKEY="$TMPDIR_KEY/identity.txt"
age-keygen -o "$TMPKEY" >/dev/null 2>&1

age-keygen -y "$TMPKEY" > "$RECIP_FILE"; chmod 600 "$RECIP_FILE"

# --- identité privée -> Trousseau ---
# On ne garde que la ligne AGE-SECRET-KEY (une seule ligne : relue telle
# quelle par 'security -w'). NB : la valeur transite une fois en argument
# de 'security' (visible très brièvement dans ps, sur sa propre machine).
KEYDATA="$(grep '^AGE-SECRET-KEY-' "$TMPKEY")"
security add-generic-password -a "$USER" -s "$SVC" -w "$KEYDATA" \
  -D "age identity" -j "Identité age des sauvegardes chiffrées" >/dev/null
unset KEYDATA

echo "✅ Clé age créée."
echo "   • Identité privée  → Trousseau (service '$SVC', compte '$USER')"
echo "   • Clé publique     → $RECIP_FILE"
echo
echo "🛟  Copie de secours OBLIGATOIRE de l'identité (Trousseau perdu = archives illisibles) :"
echo "      security find-generic-password -s '$SVC' -a \"\$USER\" -w"
echo "    → à copier une fois dans un gestionnaire de mots de passe ou sur papier, hors ligne."
echo
echo "Ensuite : vault-backup.sh -s <dossier> -o <sortie> -m key"
