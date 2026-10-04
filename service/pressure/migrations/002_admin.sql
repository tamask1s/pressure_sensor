BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS account_roles(
    account TEXT PRIMARY KEY REFERENCES accounts ON DELETE CASCADE,
    role TEXT NOT NULL CHECK(role='admin'),
    granted_at REAL NOT NULL
);
-- Keep the audit trail even after an account is deleted. Never store import JSON.
CREATE TABLE IF NOT EXISTS admin_audit(
    id INTEGER PRIMARY KEY,
    at REAL NOT NULL,
    actor TEXT NOT NULL,
    action TEXT NOT NULL,
    device_ids TEXT NOT NULL,
    outcome TEXT NOT NULL,
    request_id TEXT,
    target_account TEXT
);
PRAGMA user_version=2;
COMMIT;
