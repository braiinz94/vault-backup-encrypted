#!/usr/bin/env bash
# Tests de bout en bout : faux coffre → sauvegarde chiffrée → restauration
# ailleurs → comparaison des empreintes SHA-256.
#
# Aucune clé réelle, aucun accès au Trousseau : une identité age jetable
# est générée dans un dossier temporaire, HOME est redirigé vers ce dossier
# et la restauration passe toujours par -i (fichier d'identité).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"
export VAULT_BACKUP_KEYCHAIN_SERVICE="vault-backup-test-inexistant-$$"
unset VAULT_SOURCE VAULT_BACKUP_DIR VAULT_BACKUP_RECIPIENT_FILE VAULT_BACKUP_IDENTITY_FILE

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
ko()   { FAIL=$((FAIL + 1)); echo "  ÉCHEC $1"; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi
}

# manifeste : "<sha256>  <chemin relatif>" pour chaque fichier, trié
manifest() {
  ( cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      sha256_file "$f"
    done )
}

# --- identité de test jetable ---
ID="$WORK/test-identity.txt"
RECIP="$WORK/test-recipient.txt"
age-keygen -o "$ID" >/dev/null 2>&1
age-keygen -y "$ID" > "$RECIP"

# --- faux coffre ---
VAULT="$WORK/src/Mon Coffre"
mkdir -p "$VAULT/notes/sous dossier" "$VAULT/raw" "$VAULT/.obsidian"
printf '# Note\n\nContenu de test.\n' > "$VAULT/notes/note.md"
printf 'accents éàü — et espaces\n' > "$VAULT/notes/sous dossier/fichier avec espaces.md"
: > "$VAULT/notes/vide.md"
head -c 200000 /dev/urandom > "$VAULT/notes/binaire.bin"
printf '{"theme":"dark"}\n' > "$VAULT/.obsidian/app.json"
printf 'brut\n' > "$VAULT/raw/gros-fichier.txt"

echo "Tests vault-backup-encrypted"

# 1. sauvegarde par clé + restauration + empreintes identiques
OUT="$WORK/out1"
if "$BIN/vault-backup.sh" -s "$VAULT" -o "$OUT" -m key -r "$RECIP" >/dev/null; then
  ok "sauvegarde par clé"
else
  ko "sauvegarde par clé"
fi
ARCH="$(find "$OUT" -name '*.tar.gz.age' | head -n 1)"
if [ -n "$ARCH" ] && [ -f "$ARCH.sha256" ]; then ok "archive et empreinte créées"; else ko "archive et empreinte créées"; fi

if head -c 21 "$ARCH" | grep -q 'age-encryption.org/v1'; then
  ok "l'archive est au format age"
else
  ko "l'archive est au format age"
fi
if grep -a -q 'Contenu de test' "$ARCH"; then ko "texte des notes absent de l'archive"; else ok "texte des notes absent de l'archive"; fi

REST="$WORK/restore1"
if "$BIN/vault-restore.sh" -i "$ID" "$ARCH" "$REST" >/dev/null; then ok "restauration"; else ko "restauration"; fi
if [ "$(manifest "$VAULT")" = "$(manifest "$REST/Mon Coffre")" ]; then
  ok "empreintes SHA-256 identiques après restauration ($(manifest "$VAULT" | wc -l | tr -d ' ') fichiers)"
else
  ko "empreintes SHA-256 identiques après restauration"
  diff <(manifest "$VAULT") <(manifest "$REST/Mon Coffre") || true
fi

# 1 bis. identité passée par substitution de processus (cas gestionnaire de mots de passe)
if "$BIN/vault-restore.sh" -i <(cat "$ID") "$ARCH" "$WORK/restore1b" >/dev/null \
   && [ "$(manifest "$VAULT")" = "$(manifest "$WORK/restore1b/Mon Coffre")" ]; then
  ok "restauration avec -i <(…)"
else
  ko "restauration avec -i <(…)"
fi

# 2. exclusions
OUT2="$WORK/out2"
"$BIN/vault-backup.sh" -s "$VAULT" -o "$OUT2" -m key -r "$RECIP" -x raw -x .obsidian/ >/dev/null
ARCH2="$(find "$OUT2" -name '*.tar.gz.age' | head -n 1)"
REST2="$WORK/restore2"
"$BIN/vault-restore.sh" -i "$ID" "$ARCH2" "$REST2" >/dev/null
if [ ! -e "$REST2/Mon Coffre/raw" ] && [ ! -e "$REST2/Mon Coffre/.obsidian" ] \
   && [ -f "$REST2/Mon Coffre/notes/note.md" ]; then
  ok "exclusions (-x) respectées"
else
  ko "exclusions (-x) respectées"
fi

# 3. mode auto : utilise la clé si le recipient par défaut existe
mkdir -p "$HOME/.config/vault-backup"
cp "$RECIP" "$HOME/.config/vault-backup/recipient.txt"
OUT3="$WORK/out3"
if VAULT_SOURCE="$VAULT" VAULT_BACKUP_DIR="$OUT3" "$BIN/vault-backup.sh" </dev/null >/dev/null 2>&1; then
  ARCH3="$(find "$OUT3" -name '*.tar.gz.age' | head -n 1)"
  if VAULT_BACKUP_IDENTITY_FILE="$ID" "$BIN/vault-restore.sh" "$ARCH3" "$WORK/restore3" >/dev/null; then
    ok "mode auto + variables d'environnement"
  else
    ko "mode auto + variables d'environnement (restauration)"
  fi
else
  ko "mode auto + variables d'environnement (sauvegarde)"
fi
rm -f "$HOME/.config/vault-backup/recipient.txt"

# 4. archive altérée → refus avant déchiffrement
TAMPER="$WORK/tamper"
mkdir -p "$TAMPER"
cp "$ARCH" "$ARCH.sha256" "$TAMPER/"
T="$TAMPER/$(basename "$ARCH")"
# archive intacte mais empreinte différente : seul le contrôle SHA-256 peut refuser
printf '%064d  %s\n' 0 "$(basename "$ARCH")" > "$T.sha256"
if "$BIN/vault-restore.sh" -i "$ID" "$T" "$WORK/restore4" >/dev/null 2>&1; then
  ko "empreinte non concordante refusée"
else
  ok "empreinte non concordante refusée"
fi
if [ ! -e "$WORK/restore4" ] || [ -z "$(ls -A "$WORK/restore4")" ]; then
  ok "rien d'extrait quand l'empreinte est fausse"
else
  ko "rien d'extrait quand l'empreinte est fausse"
fi

# 5. mauvaise identité → échec
ID2="$WORK/autre-identity.txt"
age-keygen -o "$ID2" >/dev/null 2>&1
if "$BIN/vault-restore.sh" -i "$ID2" "$ARCH" "$WORK/restore5" >/dev/null 2>&1; then
  ko "mauvaise identité refusée"
else
  ok "mauvaise identité refusée"
fi

ERR="$("$BIN/vault-restore.sh" -i "$ID2" "$ARCH" "$WORK/restore5b" 2>&1 >/dev/null || true)"
if printf '%s' "$ERR" | grep -q 'Restauration interrompue'; then
  ok "échec de restauration signalé"
else
  ko "échec de restauration signalé"
fi

# 5 bis. identité illisible → aucun dossier créé
if ! "$BIN/vault-restore.sh" -i "$WORK/absente.txt" "$ARCH" "$WORK/restore5c" >/dev/null 2>&1 \
   && [ ! -e "$WORK/restore5c" ]; then
  ok "identité illisible : rien créé"
else
  ko "identité illisible : rien créé"
fi

# 5 ter. dossier de sortie existant : ses droits ne sont pas modifiés
OUT6="$WORK/out-existant"
mkdir -p "$OUT6"; chmod 755 "$OUT6"
"$BIN/vault-backup.sh" -s "$VAULT" -o "$OUT6" -m key -r "$RECIP" >/dev/null
if [ -n "$(find "$OUT6" -maxdepth 0 -perm 755)" ]; then
  ok "droits d'un dossier de sortie existant conservés"
else
  ko "droits d'un dossier de sortie existant conservés"
fi

# 6. destination non vide → refus
if "$BIN/vault-restore.sh" -i "$ID" "$ARCH" "$REST" >/dev/null 2>&1; then
  ko "destination non vide refusée"
else
  ok "destination non vide refusée"
fi

# 7. erreurs d'usage
if "$BIN/vault-backup.sh" -s "$WORK/nexiste-pas" -o "$WORK/o7" -m key -r "$RECIP" >/dev/null 2>&1; then
  ko "source absente refusée"
else
  ok "source absente refusée"
fi
if "$BIN/vault-backup.sh" -s "$VAULT" -o "$VAULT/backups" -m key -r "$RECIP" >/dev/null 2>&1; then
  ko "sortie dans la source refusée"
else
  ok "sortie dans la source refusée"
fi
if "$BIN/vault-backup.sh" -s "$VAULT" -o "$WORK/o8" -m key -r "$WORK/absent.txt" >/dev/null 2>&1; then
  ko "mode clé sans recipient refusé"
else
  ok "mode clé sans recipient refusé"
fi
if "$BIN/vault-backup.sh" -s "$VAULT" -o "$WORK/o9" -m inconnu >/dev/null 2>&1; then
  ko "méthode inconnue refusée"
else
  ok "méthode inconnue refusée"
fi

# 8. la source n'a pas été modifiée par les sauvegardes
if [ -z "$(find "$VAULT" -name '*.age' -print)" ] && [ ! -e "$VAULT/backups" ]; then ok "source intacte"; else ko "source intacte"; fi

echo
echo "Résultat : $PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
