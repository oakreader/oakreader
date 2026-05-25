#!/usr/bin/env bash
# import-backup.sh — Import user data from a backup DB into a fresh OakReader DB.
#
# Usage:
#   ./scripts/import-backup.sh <backup.sqlite> <fresh.sqlite>
#
# The fresh DB must have been created by launching the app (v1-initial schema
# with system data seeded). This script ATTACHes the backup, deletes the
# freshly-seeded system properties (so old random UUIDs are preserved), and
# copies all user data in FK-safe order.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <backup.sqlite> <fresh.sqlite>"
    exit 1
fi

BACKUP="$1"
FRESH="$2"

if [[ ! -f "$BACKUP" ]]; then
    echo "Error: backup file not found: $BACKUP"
    exit 1
fi

if [[ ! -f "$FRESH" ]]; then
    echo "Error: fresh database not found: $FRESH"
    exit 1
fi

echo "=== OakReader Data Import ==="
echo "Backup: $BACKUP"
echo "Target: $FRESH"
echo ""

sqlite3 "$FRESH" <<'SQL'
PRAGMA foreign_keys = OFF;

ATTACH DATABASE '${BACKUP}' AS backup;
SQL

# We need to pass the backup path into the SQL. Use a heredoc with variable expansion.
sqlite3 "$FRESH" "ATTACH DATABASE '$BACKUP' AS backup;" ".exit" 2>/dev/null

sqlite3 "$FRESH" <<ENDSQL
PRAGMA foreign_keys = OFF;
ATTACH DATABASE '$BACKUP' AS backup;

-- ── 1. Items ──
INSERT OR IGNORE INTO main.items SELECT * FROM backup.items;
SELECT 'items: ' || changes();

-- ── 2. Attachments ──
INSERT OR IGNORE INTO main.attachments SELECT * FROM backup.attachments;
SELECT 'attachments: ' || changes();

-- ── 3. User collections (non-system) ──
INSERT OR IGNORE INTO main.collections SELECT * FROM backup.collections WHERE is_system = 0;
SELECT 'user collections: ' || changes();

-- ── 4. Collection items ──
INSERT OR IGNORE INTO main.collection_items SELECT * FROM backup.collection_items;
SELECT 'collection_items: ' || changes();

-- ── 5. Properties — delete fresh-seeded system properties, then import ALL from backup ──
DELETE FROM main.item_property_values;
DELETE FROM main.property_options;
DELETE FROM main.properties;

INSERT OR IGNORE INTO main.properties SELECT * FROM backup.properties;
SELECT 'properties: ' || changes();

INSERT OR IGNORE INTO main.property_options SELECT * FROM backup.property_options;
SELECT 'property_options: ' || changes();

-- ── 6. Item property values ──
INSERT OR IGNORE INTO main.item_property_values SELECT * FROM backup.item_property_values;
SELECT 'item_property_values: ' || changes();

-- ── 7. Conversations ──
INSERT OR IGNORE INTO main.conversations SELECT * FROM backup.conversations;
SELECT 'conversations: ' || changes();

-- ── 8. Notes ──
INSERT OR IGNORE INTO main.notes SELECT * FROM backup.notes;
SELECT 'notes: ' || changes();

-- ── 9. Citations ──
INSERT OR IGNORE INTO main.citations SELECT * FROM backup.citations;
SELECT 'citations: ' || changes();

-- ── 10. Annotations ──
INSERT OR IGNORE INTO main.annotations SELECT * FROM backup.annotations;
SELECT 'annotations: ' || changes();

-- ── 11. Item relations ──
INSERT OR IGNORE INTO main.item_relations SELECT * FROM backup.item_relations;
SELECT 'item_relations: ' || changes();

-- ── 12. Quiz cards ──
INSERT OR IGNORE INTO main.quiz_cards SELECT * FROM backup.quiz_cards;
SELECT 'quiz_cards: ' || changes();

-- ── 13. Quiz review log ──
INSERT OR IGNORE INTO main.quiz_review_log SELECT * FROM backup.quiz_review_log;
SELECT 'quiz_review_log: ' || changes();

-- ── Verify FK integrity ──
SELECT 'FK violations: ' || COUNT(*) FROM pragma_foreign_key_check;

DETACH DATABASE backup;
ENDSQL

echo ""
echo "=== Import complete ==="
