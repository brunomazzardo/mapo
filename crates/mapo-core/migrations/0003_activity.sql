-- The activity log (R-CTL-6, PLAN T3.2): mutating requests from agents and the automation surface.
CREATE TABLE activity (
    id TEXT PRIMARY KEY,
    at INTEGER NOT NULL,
    json TEXT NOT NULL
);
CREATE INDEX activity_at ON activity (at);
