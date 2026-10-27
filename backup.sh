#!/usr/bin/env bash
# Back up the self-hosted stack to an off-site restic repository.
# Run as root (sudo ./backup.sh) so every file in data/ is readable.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
STACK_DIR="$(pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

# Load RESTIC_REPOSITORY, RESTIC_PASSWORD and storage credentials
set -a
source ./backup.env
set +a

echo "=== Backup started: $(date -Is) ==="

# Stop the stack so the SQLite databases are consistent.
# The trap restarts it even if the backup fails part-way.
docker compose stop
trap 'echo "Restarting stack"; docker compose start' EXIT

restic backup \
  "$STACK_DIR/data" \
  "$STACK_DIR/homepage" \
  "$STACK_DIR/.env" \
  "$STACK_DIR/backup.env" \
  "$STACK_DIR/docker-compose.yml" \
  "$STACK_DIR/backup.sh" \
  "$STACK_DIR/README.md" \
  --tag selfhost

# Backup done: restart now rather than waiting for retention/pruning
trap - EXIT
docker compose start

# Retention: 7 daily, 4 weekly, 6 monthly snapshots
restic forget --tag selfhost \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
  --prune

echo "=== Backup finished: $(date -Is) ==="
