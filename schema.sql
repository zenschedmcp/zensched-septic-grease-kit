-- ZenSched Septic & Grease Local Database Schema
-- SQLite database for CRM, tank cadence, pump-manifest summaries,
-- and billing.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my septic-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 septic-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- NOT AN OFFICIAL E-MANIFEST. pump_log is the owner's local extract from the
-- Service Manifest (date, tank, gallons, waste type, disposal site, condition,
-- tech). It is not a hazardous-waste e-manifest (EPA e-Manifest / RCRA), not
-- a state pumping report, and not a hauler trip ticket. Licensed pumpers still
-- keep whatever their state and disposal facility require, on their own forms.
--
-- PRIVACY: tanks.access_notes (hatch location, gate, dog, alarm) and
-- technicians.license_no (pumper / hauler number) live ONLY in this file on
-- your computer. They are never sent to ZenSched. SKILL.md forbids the agent
-- from putting them in any ZenSched notes field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, default tech, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Septic & Grease Co');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_worker_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_shift_start', '09:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_shift_minutes', '90');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '14');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('manifest_form_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('event_window_days', '60');

-- Services: your price list. Seeded with common pumper items; edit prices freely.
-- jobs.service_id is what was actually done (a semi septic account can still
-- get a one-off emergency pump).
CREATE TABLE IF NOT EXISTS services (
  service_id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE,                        -- short handle: 'septic_pump'
  service_name TEXT NOT NULL,                       -- shown on invoices
  default_minutes INTEGER NOT NULL,                 -- shift length on ZenSched
  price REAL NOT NULL,                              -- default per-visit dollars
  is_active INTEGER DEFAULT 1,
  notes TEXT
);

INSERT OR IGNORE INTO services (code, service_name, default_minutes, price) VALUES ('septic_pump', 'Septic tank pump-out', 90, 375.00);
INSERT OR IGNORE INTO services (code, service_name, default_minutes, price) VALUES ('grease_pump', 'Grease trap pump-out', 60, 225.00);
INSERT OR IGNORE INTO services (code, service_name, default_minutes, price) VALUES ('septic_inspect', 'Septic inspection', 45, 150.00);
INSERT OR IGNORE INTO services (code, service_name, default_minutes, price) VALUES ('emergency', 'Emergency pump-out', 120, 550.00);

-- Customers: contact, default service, per-visit rate, and tank cadence.
-- next_service_date is advanced by trigger when a job is recorded.
-- Frequency quarterly / semi / on-demand only.
CREATE TABLE IF NOT EXISTS customers (
  customer_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_name TEXT NOT NULL,
  contact_email TEXT,
  contact_phone TEXT,
  service_id INTEGER,                               -- default recurring service
  service_rate REAL NOT NULL,                       -- price per visit (may differ from the list)
  service_frequency TEXT NOT NULL
    CHECK (service_frequency IN ('quarterly', 'semi', 'on-demand')),
  next_service_date TEXT,                           -- ISO date: '2026-09-07'
  last_service_date TEXT,                           -- set automatically when a job is recorded
  preferred_start TEXT                              -- 'HH:MM' 24-hour local; NULL = settings.default_shift_start
    CHECK (preferred_start IS NULL OR preferred_start GLOB '[0-2][0-9]:[0-5][0-9]'),
  zensched_worker_id INTEGER,                       -- preferred tech; NULL = settings.default_worker_id
  billing_notes TEXT,                               -- 'pays by check', 'invoice monthly', ...
  is_active INTEGER DEFAULT 1,                      -- 0 = paused / cancelled
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (service_id) REFERENCES services(service_id)
);

-- Tanks: the places. One septic or grease tank per row, with ZenSched refs.
-- One ZenSched LOCATION per tank, created once and kept forever.
-- One ZenSched EVENT per tank per rolling window of at most 60 days
-- (ZenSched caps event length). zensched_event_id is the CURRENT event and
-- event_valid_until is its last valid date. When a visit date is later than
-- event_valid_until, the agent creates a new event and updates both columns.
CREATE TABLE IF NOT EXISTS tanks (
  tank_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  tank_type TEXT NOT NULL
    CHECK (tank_type IN ('septic', 'grease')),
  address TEXT NOT NULL,
  address_line2 TEXT,
  city TEXT,
  state TEXT,
  zip TEXT,
  access_notes TEXT,                                -- LOCAL ONLY: hatch location, gate, dog, alarm
  capacity_gallons INTEGER,                         -- nameplate / estimated size
  tank_notes TEXT,                                  -- age, baffles, last known issues
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  zensched_event_id INTEGER,                        -- from event_create (current <=60-day window)
  event_valid_until TEXT,                           -- ISO date: last day the current event covers
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE
);

-- Technicians: your roster. zensched_worker_id comes from worker_invite.
-- license_no is LOCAL ONLY (pumper / hauler number) and never sent to ZenSched.
CREATE TABLE IF NOT EXISTS technicians (
  technician_id INTEGER PRIMARY KEY AUTOINCREMENT,
  technician_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  license_no TEXT,                                  -- LOCAL ONLY
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Jobs: one row per COMPLETED visit, linked to the ZenSched shift and the
-- Service Manifest form submission. This is the billing record plus a small
-- summary of the manifest so the pump_log view is a local query.
-- tank_condition / waste_type are CHECK-constrained to the form's option labels.
CREATE TABLE IF NOT EXISTS jobs (
  job_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  tank_id INTEGER NOT NULL,
  service_id INTEGER NOT NULL,
  technician_id INTEGER,                            -- local roster row (trigger fills from worker id)
  completed_date TEXT NOT NULL,                     -- ISO date: '2026-09-07'
  amount REAL NOT NULL,
  zensched_shift_id INTEGER UNIQUE,                 -- prevents recording the same shift twice
  zensched_event_id INTEGER,
  zensched_worker_id INTEGER,
  actual_in TEXT,                                   -- from shift_status / timesheet_export
  actual_out TEXT,
  duration_minutes INTEGER,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  report_dc_id INTEGER,                             -- Service Manifest submission_id
  gallons REAL,                                     -- number from the form
  tank_condition TEXT CHECK (tank_condition IS NULL OR tank_condition IN ('Good', 'Fair', 'Needs repair', 'Inaccessible')),
  disposal_site TEXT,                               -- as the tech wrote it
  waste_type TEXT CHECK (waste_type IS NULL OR waste_type IN ('Septic', 'Grease', 'Mixed', 'Other')),
  notes TEXT,
  photo_urls TEXT,                                  -- JSON array of hatch photo URLs
  invoiced INTEGER DEFAULT 0,                       -- 1 = included in an invoice
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE,
  FOREIGN KEY (tank_id) REFERENCES tanks(tank_id) ON DELETE CASCADE,
  FOREIGN KEY (service_id) REFERENCES services(service_id),
  FOREIGN KEY (technician_id) REFERENCES technicians(technician_id) ON DELETE SET NULL
);

-- Invoices: billing records.
-- invoice_number is filled in automatically by a trigger if left NULL.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- human-readable: 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,                           -- 1 = paid, 0 = unpaid
  paid_date TEXT,
  sent_date TEXT,                                   -- when you actually emailed/texted it
  line_items TEXT,                                  -- JSON array of job references
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_customers_next_service ON customers(next_service_date, is_active);
CREATE INDEX IF NOT EXISTS idx_customers_service ON customers(service_id);
CREATE INDEX IF NOT EXISTS idx_tanks_customer ON tanks(customer_id);
CREATE INDEX IF NOT EXISTS idx_tanks_zensched_location ON tanks(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_tanks_zensched_event ON tanks(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_technicians_worker ON technicians(zensched_worker_id);
CREATE INDEX IF NOT EXISTS idx_jobs_customer ON jobs(customer_id, completed_date);
CREATE INDEX IF NOT EXISTS idx_jobs_invoiced ON jobs(invoiced);
CREATE INDEX IF NOT EXISTS idx_invoices_customer ON invoices(customer_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid);

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_customer_timestamp
AFTER UPDATE ON customers
BEGIN
  UPDATE customers SET updated_at = datetime('now') WHERE customer_id = NEW.customer_id;
END;

CREATE TRIGGER IF NOT EXISTS update_tank_timestamp
AFTER UPDATE ON tanks
BEGIN
  UPDATE tanks SET updated_at = datetime('now') WHERE tank_id = NEW.tank_id;
END;

CREATE TRIGGER IF NOT EXISTS update_technician_timestamp
AFTER UPDATE ON technicians
BEGIN
  UPDATE technicians SET updated_at = datetime('now') WHERE technician_id = NEW.technician_id;
END;

-- Fill technician_id from the roster when the agent only has the ZenSched worker id.
CREATE TRIGGER IF NOT EXISTS fill_job_technician
AFTER INSERT ON jobs
WHEN NEW.technician_id IS NULL AND NEW.zensched_worker_id IS NOT NULL
BEGIN
  UPDATE jobs
  SET technician_id = (SELECT technician_id FROM technicians WHERE zensched_worker_id = NEW.zensched_worker_id)
  WHERE job_id = NEW.job_id;
END;

-- Recording a completed job automatically advances the customer's cadence.
-- quarterly is +90 days (not +3 months). semi is +180 days (not +6 months).
-- on-demand clears the next date.
-- The agent should NOT hand-maintain next_service_date after this.
-- A one-off recorded on a recurring customer also moves the cadence; if the
-- owner wants the regular stop kept, set next_service_date back explicitly.
CREATE TRIGGER IF NOT EXISTS advance_service_date_on_job
AFTER INSERT ON jobs
BEGIN
  UPDATE customers
  SET last_service_date = NEW.completed_date,
      next_service_date = CASE service_frequency
        WHEN 'quarterly' THEN date(NEW.completed_date, '+90 days')
        WHEN 'semi'      THEN date(NEW.completed_date, '+180 days')
        ELSE NULL                                    -- on-demand: no automatic next visit
      END
  WHERE customer_id = NEW.customer_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Who is due in the next 7 days (today + 6). The agent's weekly scheduling
-- query. One row = one shift_create call. Columns ending in _iso are ready
-- to pass as shift_create start/end; idempotency_key is ready too.
-- event_needs_roll = 1 means create a new ZenSched event first (see SKILL.md).
-- access_notes is included so the agent can tell the owner to pass it to the
-- tech; it must never go into a ZenSched field.
CREATE VIEW IF NOT EXISTS customers_due AS
SELECT
  c.customer_id,
  c.customer_name,
  c.contact_email,
  c.contact_phone,
  c.service_rate,
  c.service_frequency,
  c.next_service_date,
  COALESCE(c.preferred_start, (SELECT value FROM settings WHERE key = 'default_shift_start')) AS start_time,
  sv.service_id,
  sv.code                                    AS service_code,
  sv.service_name,
  COALESCE(sv.default_minutes, CAST((SELECT value FROM settings WHERE key = 'default_shift_minutes') AS INTEGER)) AS default_minutes,
  t.tank_id,
  t.tank_type,
  t.address,
  t.city,
  t.state,
  t.zip,
  t.capacity_gallons,
  t.tank_notes,
  t.access_notes,
  t.zensched_location_id,
  t.zensched_event_id,
  t.event_valid_until,
  CASE WHEN t.event_valid_until IS NULL OR t.event_valid_until < c.next_service_date THEN 1 ELSE 0 END AS event_needs_roll,
  COALESCE(c.zensched_worker_id, (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_worker_id')) AS worker_id,
  (SELECT tech.technician_name FROM technicians tech
    WHERE tech.zensched_worker_id = COALESCE(c.zensched_worker_id,
           (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_worker_id'))) AS technician_name,
  c.next_service_date || 'T'
    || COALESCE(c.preferred_start, (SELECT value FROM settings WHERE key = 'default_shift_start'))
    || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset') AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(
      c.next_service_date || ' '
      || COALESCE(c.preferred_start, (SELECT value FROM settings WHERE key = 'default_shift_start'))
      || ':00',
      '+' || COALESCE(sv.default_minutes, CAST((SELECT value FROM settings WHERE key = 'default_shift_minutes') AS INTEGER)) || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset') AS end_iso,
  'shift-tank-' || t.tank_id || '-' || strftime('%Y%m%d', c.next_service_date) AS idempotency_key
FROM customers c
JOIN tanks t ON t.customer_id = c.customer_id AND t.is_active = 1
LEFT JOIN services sv ON sv.service_id = c.service_id
WHERE c.is_active = 1
  AND c.next_service_date IS NOT NULL
  AND c.next_service_date <= date('now', '+7 days')
ORDER BY c.next_service_date, COALESCE(c.preferred_start, (SELECT value FROM settings WHERE key = 'default_shift_start')), c.customer_name;

-- Tanks whose current ZenSched event expires within 14 days (or has none)
-- and that belong to an active customer. Roll these proactively.
CREATE VIEW IF NOT EXISTS events_expiring AS
SELECT
  t.tank_id,
  c.customer_name,
  t.tank_type,
  t.address,
  t.zensched_location_id,
  t.zensched_event_id,
  t.event_valid_until
FROM tanks t
JOIN customers c ON c.customer_id = t.customer_id AND c.is_active = 1
WHERE t.is_active = 1
  AND (t.event_valid_until IS NULL OR t.event_valid_until <= date('now', '+14 days'))
ORDER BY t.event_valid_until;

-- Completed work that has not been invoiced yet, grouped by customer.
CREATE VIEW IF NOT EXISTS jobs_to_invoice AS
SELECT
  c.customer_id,
  c.customer_name,
  c.contact_email,
  c.billing_notes,
  COUNT(j.job_id)       AS job_count,
  SUM(j.amount)         AS total_amount,
  MIN(j.completed_date) AS first_job_date,
  MAX(j.completed_date) AS last_job_date
FROM jobs j
JOIN customers c ON c.customer_id = j.customer_id
WHERE j.invoiced = 0
GROUP BY c.customer_id
ORDER BY c.customer_name;

-- Unpaid invoices, oldest first.
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  c.customer_name,
  c.contact_email,
  i.invoice_date,
  i.due_date,
  i.total_amount,
  i.sent_date,
  CASE WHEN i.due_date < date('now') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN customers c ON c.customer_id = i.customer_id
WHERE i.paid = 0
ORDER BY i.due_date;

-- Owner's local pump-log extract: one row per pumped visit. This is the
-- owner's copy, not a hazardous-waste e-manifest and not a state pumping
-- report. Visits with no gallons (inspect-only / inaccessible) are omitted.
CREATE VIEW IF NOT EXISTS pump_log AS
SELECT
  j.job_id,
  j.completed_date                               AS pump_date,
  t.address                                      AS tank_address,
  t.city,
  t.state,
  t.tank_type,
  c.customer_name,
  j.gallons,
  j.waste_type,
  j.disposal_site,
  j.tank_condition,
  COALESCE(tech.technician_name, 'tech ' || j.zensched_worker_id) AS technician,
  j.notes,
  j.zensched_shift_id,
  j.report_dc_id
FROM jobs j
JOIN tanks t ON t.tank_id = j.tank_id
JOIN customers c ON c.customer_id = j.customer_id
LEFT JOIN technicians tech ON tech.technician_id = j.technician_id
WHERE j.gallons IS NOT NULL
  AND j.gallons > 0
ORDER BY j.completed_date DESC, c.customer_name;
