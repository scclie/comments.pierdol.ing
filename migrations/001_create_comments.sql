CREATE TABLE IF NOT EXISTS comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id TEXT NOT NULL,
    parent_id UUID REFERENCES comments(id) ON DELETE SET NULL,
    nickname TEXT NOT NULL,
    site TEXT,
    content TEXT NOT NULL,
    html TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    honeypot TEXT DEFAULT ''
);

CREATE INDEX idx_comments_thread_status ON comments(thread_id, status);
CREATE INDEX idx_comments_created_at ON comments(created_at);
