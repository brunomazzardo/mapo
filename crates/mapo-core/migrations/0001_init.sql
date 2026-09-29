CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE workspaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    ord INTEGER NOT NULL,
    agent_command TEXT
);

CREATE TABLE tabs (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    labeled INTEGER NOT NULL,
    kind TEXT NOT NULL,
    ord INTEGER NOT NULL,
    cwd TEXT NOT NULL,
    launch_cwd TEXT NOT NULL,
    launch_command TEXT,
    agent_command TEXT,
    UNIQUE (workspace_id, name)
);

CREATE TABLE layouts (
    workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
    json TEXT NOT NULL
);
