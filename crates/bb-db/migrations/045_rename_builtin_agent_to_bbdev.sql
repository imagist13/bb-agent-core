-- Surface the built-in in-process engine as `bbdev` in the UI. Migration 001
-- seeded the upstream label; rename it in place so existing installs pick up
-- the product name without touching the historical migration.
UPDATE agent_metadata
SET name = 'bbdev',
    updated_at = unixepoch('now', 'subsec') * 1000
WHERE id = '632f31d2'
  AND agent_source = 'internal';
