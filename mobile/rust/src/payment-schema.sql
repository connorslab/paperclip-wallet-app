-- Mobile-only write-ahead receipt. No quote or spending approval is persisted.
CREATE TABLE IF NOT EXISTS paperclip_payment_attempt (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	owner TEXT NOT NULL,
	body TEXT NOT NULL
);
