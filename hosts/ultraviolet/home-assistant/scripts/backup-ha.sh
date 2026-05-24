#!/usr/bin/env bash
# Home Assistant backup script with optional labeling
# Usage: backup-ha.sh [label]
# Example: backup-ha.sh "bubble-cards-working"

set -euo pipefail

# Configuration
SOURCE_DIR="/var/lib/hass"
BACKUP_BASE="/mnt/backups/home-assistant"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LABEL="${1:-}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Build backup directory name
if [ -n "$LABEL" ]; then
    # Sanitize label (remove special chars, replace spaces with dashes)
    SAFE_LABEL=$(echo "$LABEL" | tr ' ' '-' | tr -cd '[:alnum:]-_')
    BACKUP_NAME="${TIMESTAMP}-${SAFE_LABEL}"
    echo -e "${BLUE}Creating labeled backup: ${BACKUP_NAME}${NC}"
else
    BACKUP_NAME="${TIMESTAMP}"
    echo -e "${YELLOW}Creating automatic backup: ${BACKUP_NAME}${NC}"
fi

BACKUP_PATH="$BACKUP_BASE/$BACKUP_NAME"

# Ensure backup directory exists
if ! mountpoint -q /mnt/backups; then
    echo "Error: /mnt/backups is not mounted"
    exit 1
fi

mkdir -p "$BACKUP_BASE"

# Perform backup
echo "Backing up Home Assistant configuration..."
echo "Source: $SOURCE_DIR"
echo "Destination: $BACKUP_PATH"

# Use rsync for efficient backup with exclusions
# Use -rlptDv instead of -av to avoid ownership preservation (NFS limitation)
rsync -rlptDv --delete \
    --exclude='*.log' \
    --exclude='*.log.*' \
    --exclude='home-assistant_v2.db-*' \
    --exclude='.cloud' \
    --exclude='.storage/core.restore_state' \
    --exclude='deps' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='tts' \
    "$SOURCE_DIR/" "$BACKUP_PATH/"

# Update the 'latest' symlink
ln -sfn "$BACKUP_PATH" "$BACKUP_BASE/latest"

# Create a labeled symlink if this is a manual backup
if [ -n "$LABEL" ]; then
    LABEL_LINK="$BACKUP_BASE/labeled-${SAFE_LABEL}"
    ln -sfn "$BACKUP_PATH" "$LABEL_LINK"
    echo -e "${GREEN}✓ Created labeled backup link: labeled-${SAFE_LABEL}${NC}"
fi

# Clean up old backups (keep last 14 days of automatic backups).
# Automatic backups are exactly YYYYMMDD-HHMMSS; labeled backups have an
# additional -LABEL suffix and are preserved indefinitely.
echo "Cleaning up old automatic backups..."
find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' \
    -mtime +14 -exec rm -rf {} + 2>/dev/null || true

# Show backup summary
BACKUP_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
echo -e "${GREEN}✓ Backup completed successfully${NC}"
echo "  Size: $BACKUP_SIZE"
echo "  Path: $BACKUP_PATH"

# Log backup for monitoring
logger -t home-assistant-backup "Backup completed: $BACKUP_NAME (Size: $BACKUP_SIZE${LABEL:+, Label: $LABEL})"

# If labeled, also save a description file
if [ -n "$LABEL" ]; then
    cat > "$BACKUP_PATH/BACKUP_INFO.txt" <<EOF
Backup Created: $(date)
Label: $LABEL
Hostname: $(hostname)
Home Assistant Path: $SOURCE_DIR

This is a labeled backup checkpoint.
To restore: sudo rsync -av --delete $BACKUP_PATH/ $SOURCE_DIR/
EOF
    echo -e "${BLUE}ℹ Backup info saved to BACKUP_INFO.txt${NC}"
fi

echo ""
echo "Quick reference:"
echo "  Latest backup: $BACKUP_BASE/latest"
if [ -n "$LABEL" ]; then
    echo "  This backup: $BACKUP_BASE/labeled-${SAFE_LABEL}"
fi