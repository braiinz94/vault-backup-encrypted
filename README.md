# vault-backup-encrypted

Sauvegarde chiffrée d'un dossier (coffre de notes Obsidian, dossier de travail…) avec [age](https://age-encryption.org), en trois petits scripts bash. L'archive produite peut être déposée n'importe où (cloud, clé USB, disque externe) : le support ne voit que du chiffré.

*English summary at the end.*

## Ce que fait l'outil

| Script | Rôle |
|---|---|
| `bin/vault-backup.sh` | `tar` → `gzip` → `age` en flux : produit `<dossier>-<date>.tar.gz.age` et son empreinte `.sha256`. Aucun fichier clair intermédiaire. |
| `bin/vault-key-setup.sh` | (macOS, une fois) génère une clé age, range l'identité privée dans le Trousseau macOS et écrit la clé publique dans `~/.config/vault-backup/recipient.txt`. |
| `bin/vault-restore.sh` | vérifie l'empreinte SHA-256, déchiffre et extrait dans un dossier vide. Identité lue dans le Trousseau, dans un fichier, ou passphrase. |

Deux façons de chiffrer :

- **par clé** (`-m key`) : chiffrement pour la clé publique, sans prompt, donc automatisable (cron, launchd). La clé privée n'est nécessaire qu'à la restauration.
- **par passphrase** (`-m pass`) : `age -p` la demande deux fois ; elle n'est ni affichée, ni stockée, ni passée en argument.

Par défaut (`-m auto`), la clé est utilisée si `recipient.txt` existe, sinon la passphrase.

## Installation

```bash
brew install age            # macOS
sudo apt-get install age    # Debian / Ubuntu
```

Puis copier le dossier `bin/` où l'on veut (ou cloner le dépôt).

## Utilisation

```bash
# 1. (facultatif, macOS) créer la clé, une seule fois
bin/vault-key-setup.sh                       # entrée du Trousseau : vault-backup-age
bin/vault-key-setup.sh -k mon-entree         # nom d'entrée au choix

# 2. sauvegarder
bin/vault-backup.sh -s ~/MonCoffre -o /Volumes/USB/sauvegardes
bin/vault-backup.sh -s ~/MonCoffre -o ~/sauvegardes -m key -x raw -x .trash   # avec exclusions

# variables d'environnement équivalentes
VAULT_SOURCE=~/MonCoffre VAULT_BACKUP_DIR=~/sauvegardes bin/vault-backup.sh
```

| Option | Variable | Défaut |
|---|---|---|
| `-s` source | `VAULT_SOURCE` | obligatoire |
| `-o` dossier de sortie | `VAULT_BACKUP_DIR` | obligatoire |
| `-r` fichier de clé publique | `VAULT_BACKUP_RECIPIENT_FILE` | `~/.config/vault-backup/recipient.txt` |
| `-k` entrée du Trousseau | `VAULT_BACKUP_KEYCHAIN_SERVICE` | `vault-backup-age` |
| `-i` fichier d'identité (restauration) | `VAULT_BACKUP_IDENTITY_FILE` | — |

Le fichier de clé publique peut contenir plusieurs clés (une par ligne) : l'archive est alors lisible par chacune, ce qui permet d'ajouter une clé de secours conservée hors ligne.

## Restaurer

```bash
# vérifier l'empreinte après un transfert (dans le dossier de l'archive)
shasum -a 256 -c MonCoffre-2026-01-31_120000.tar.gz.age.sha256

# clé dans le Trousseau macOS (défaut)
bin/vault-restore.sh MonCoffre-2026-01-31_120000.tar.gz.age ~/restauration

# fichier d'identité (Linux, ou gestionnaire de mots de passe sans écrire la clé sur disque)
bin/vault-restore.sh -i <(op read "op://Coffre/age-identity/password") archive.tar.gz.age ~/restauration

# archive chiffrée par passphrase
bin/vault-restore.sh -p archive.tar.gz.age ~/restauration

# sans les scripts, avec age seul
age -d -i identite.txt archive.tar.gz.age | tar -xzf - -C ~/restauration
```

La destination doit être absente ou vide : rien n'est écrasé. Si `<archive>.sha256` est présent à côté de l'archive, l'empreinte est vérifiée avant tout déchiffrement. Si la restauration échoue en cours de route (mauvaise clé, archive tronquée), le script le signale et ne supprime rien : la destination peut contenir des fichiers partiels, à vérifier ou effacer soi-même.

Côté sauvegarde, un dossier de sortie créé par le script reçoit les droits `700` ; un dossier qui existait déjà (racine d'une clé USB, dossier partagé) garde les siens.

**Tester une restauration** de temps en temps, sur une vraie archive, dans un dossier jetable : une sauvegarde jamais restaurée n'est pas une sauvegarde.

## Menace couverte

- **Fuite ou compromission du support de stockage** (compte cloud, clé USB perdue, disque volé) : le contenu reste confidentiel tant que la clé privée ou la passphrase ne fuit pas (chiffrement age : X25519 ou scrypt, puis ChaCha20-Poly1305).
- **Altération de l'archive** : age authentifie le contenu chiffré, et l'empreinte SHA-256 détecte un transfert corrompu avant le déchiffrement.
- **Perte du poste** : avec une archive hors de la machine et une copie de secours de l'identité, le dossier peut être reconstitué ailleurs.

## Limites

- **Pas de chiffrement de la machine source** : l'outil protège la copie, pas l'original. Utiliser FileVault / LUKS.
- **L'empreinte `.sha256` n'est pas une signature** : un attaquant qui contrôle le stockage peut remplacer archive et empreinte ensemble. age garantit l'intégrité de ce qu'il déchiffre, mais pas que l'archive vient de vous quand le chiffrement est par clé publique (quiconque a la clé publique peut produire une archive). Conserver l'empreinte ailleurs que l'archive si cela compte.
- **Perte de clé = perte des archives.** Garder une copie de l'identité privée hors ligne (gestionnaire de mots de passe, papier). Le script de setup l'affiche à la fin.
- **Lors du setup, l'identité transite une fois en argument** de la commande `security` (visible brièvement dans la liste des processus de sa propre machine).
- **Pas de rotation, d'incrémental ni de déduplication** : chaque sauvegarde est une archive complète. Pour de gros volumes ou un historique long, préférer restic ou borg.
- **Métadonnées visibles** : nom du dossier, date (dans le nom de fichier) et taille approximative de l'archive.
- `vault-key-setup.sh` et la restauration par Trousseau ne fonctionnent que sur macOS ; ailleurs, utiliser `-i` ou `-p`.
- Les tests automatiques couvrent le chiffrement par clé avec un fichier d'identité jetable ; le chemin Trousseau et le mode passphrase (interactif) ne sont pas testés en CI.

## Tests

```bash
bash tests/run-tests.sh
```

Le test crée un faux coffre dans un dossier temporaire (noms avec espaces et accents, fichier vide, fichier binaire, dossier caché), génère une identité age jetable, sauvegarde, restaure ailleurs et compare les empreintes SHA-256 de tous les fichiers. Il vérifie aussi les exclusions, le refus d'une empreinte fausse, d'une mauvaise identité, d'une destination non vide et des erreurs d'usage, le signalement d'une restauration interrompue et la conservation des droits d'un dossier de sortie existant. Il ne touche jamais au Trousseau ni au `HOME` réel. La CI (GitHub Actions) l'exécute sur Ubuntu et macOS, plus `shellcheck`.

---

## English summary

Three small bash scripts to make **client-side encrypted backups** of a folder (e.g. an Obsidian vault) with [age](https://age-encryption.org):

- `bin/vault-backup.sh -s SOURCE -o OUTDIR [-m auto|key|pass] [-x EXCLUDE]...` streams `tar | gzip | age` (no plaintext temp file) and writes a `.sha256` next to the archive.
- `bin/vault-key-setup.sh` (macOS, once) creates an age key, stores the private identity in the macOS Keychain and the public key in `~/.config/vault-backup/recipient.txt`, so backups can run unattended.
- `bin/vault-restore.sh [-k SERVICE | -i IDENTITY | -p] ARCHIVE DEST` checks the SHA-256, decrypts and extracts into an empty directory.

Threat model: protects backup copies stored on untrusted media or cloud accounts. It does not encrypt the source machine, the `.sha256` file is not a signature, and losing the private key or passphrase means losing the archives. Tests (`bash tests/run-tests.sh`) run on Ubuntu and macOS with a throwaway key.

## Licence

Apache-2.0 — voir [LICENSE](LICENSE). © 2026 Mourad Barkaoui.
