# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

IDs and responses are illustrative. ZenSched IDs are integers.

Shop: **Gulf Coast Septic**, Tampa, Florida, Eastern time (`-04:00` in September). Two customers (semi septic + quarterly grease), one technician, then invoice.

Access notes (hatch location, gate code) and any pumper / hauler license number stay in SQLite. They are never sent to ZenSched.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Septic & Grease Co, timezone_offset = -05:00,
    default_worker_id = NULL, default_shift_start = 09:00,
    default_shift_minutes = 90, invoice_due_days = 14, invoice_prefix = INV,
    manifest_form_id = NULL, event_window_days = 60
```

## "My business is Gulf Coast Septic in Tampa, Florida, Eastern time."

```
sqlite_execute: UPDATE settings SET value = 'Gulf Coast Septic' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-04:00' WHERE key = 'timezone_offset';
```

> Saved. I'll schedule everything in Eastern time (-04:00). You don't have a Service Manifest form yet; it's free to create and every stop will come back with gallons, tank condition, hatch photos, disposal site, and waste type. No signature — this is an internal stop record, not an official hazardous-waste e-manifest and not a state pumping report. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Service Manifest"
  idempotency_key: "form-service-manifest"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Service manifest", "identifier": "sec_manifest",
   "text": "Fill this in before you leave. Hatch photos help. This is an internal stop record, not an official hazardous-waste e-manifest and not a state pumping report."},
  {"type": "number", "label": "Gallons pulled", "identifier": "gallons", "required": true},
  {"type": "select", "label": "Tank condition", "identifier": "tank_condition", "required": true,
   "options": ["Good", "Fair", "Needs repair", "Inaccessible"]},
  {"type": "photo", "label": "Hatch photos", "identifier": "hatch", "max_images": 3},
  {"type": "textarea", "label": "Disposal site", "identifier": "disposal_site", "required": true},
  {"type": "select", "label": "Waste type", "identifier": "waste_type", "required": true,
   "options": ["Septic", "Grease", "Mixed", "Other"]}
]
```

```
  → form_id: 401, fields: [ ...6 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '401' WHERE key = 'manifest_form_id';
```

> Service Manifest form created. I'll attach it to every tank automatically. There is no signature step.

## "Add Rosa Delgado, rosa@example.com, 813-555-0144, 1842 Palmetto Court, Tampa FL 33609. Semi septic pump $375 starting Monday 2026-09-07 at 9. Hatch behind the shed, gate code 3319, dog in the backyard. 1,000-gallon tank."

```
sqlite_query:   SELECT service_id, price, default_minutes FROM services WHERE code = 'septic_pump';
  → 1, 375.00, 90

sqlite_execute:
  INSERT INTO customers (customer_name, contact_email, contact_phone, service_id, service_rate,
                         service_frequency, next_service_date, preferred_start)
  VALUES ('Rosa Delgado', 'rosa@example.com', '813-555-0144', 1, 375.00,
          'semi', '2026-09-07', '09:00');
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO tanks (customer_id, tank_type, address, city, state, zip, access_notes,
                     capacity_gallons, tank_notes)
  VALUES (1, 'septic', '1842 Palmetto Court', 'Tampa', 'FL', '33609',
          'Hatch behind shed. Gate 3319. Dog in backyard — wait for owner or crate.',
          1000, 'Residential 1,000-gal');
  → lastInsertRowid = 1
```

Agent (first metered call this session, rule 11):

> Creating Rosa's address on ZenSched costs $0.03 for geocoding. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
location_create:
  name: "Rosa Delgado - 1842 Palmetto Court"
  street_address: "1842 Palmetto Court, Tampa, FL 33609"
  checkin_radius_m: 75
  idempotency_key: "loc-tank-1"
  → location_id: 9101, lat: 27.9378, lng: -82.5154, pin_quality: "street"
    billing: { meter: "geocode", units: 1, price: 0.03 }
```

The hatch location and gate code are **not** in `notes`. They live only in `tanks.access_notes`. `checkin_radius_m` on the location is informational; the enforced radius is the policy (see later if Luis misses a punch).

```
event_create:
  location_id: 9101
  title: "Tank service - 1842 Palmetto Court"
  start_date: "2026-09-07"
  end_date:   "2026-11-05"          ← start + 59 days (60-day cap)
  idempotency_key: "event-tank-1-20260907"
  → event_id: 7101

form_assign:
  form_id: 401
  event_id: 7101
  idempotency_key: "assign-service-manifest-7101"
  → status: "assigned", form_id: 401, event_id: 7101, policy_id: 0

sqlite_execute:
  UPDATE tanks SET zensched_location_id = 9101, zensched_event_id = 7101, event_valid_until = '2026-11-05'
  WHERE tank_id = 1;
```

> Added Rosa Delgado, 1842 Palmetto Court. Semi septic pump at $375, next stop Monday Sep 7 at 9:00. The hatch location and gate code are saved on your computer only; give them to Luis directly. Her ZenSched event runs through Nov 5; I'll renew it automatically when scheduling gets that far.

## "Add a quarterly grease trap for Harbor Diner, Maya Chen, maya@harbordiner.example, 813-555-0190, 410 Bayshore Blvd, Tampa FL 33606, Tuesday 2026-09-08 at 11, $225. Trap is by the dumpster; restaurant opens at 10."

Same pattern. The agent does not re-ask about the $0.03 (owner already approved geocoding this session). Frequency is `quarterly`.

```
sqlite_query:   SELECT service_id, default_minutes FROM services WHERE code = 'grease_pump';
  → 2, 60

sqlite_execute:
  INSERT INTO customers (customer_name, contact_email, contact_phone, service_id, service_rate,
                         service_frequency, next_service_date, preferred_start)
  VALUES ('Harbor Diner', 'maya@harbordiner.example', '813-555-0190', 2, 225.00,
          'quarterly', '2026-09-08', '11:00');
  → lastInsertRowid = 2

sqlite_execute:
  INSERT INTO tanks (customer_id, tank_type, address, city, state, zip, access_notes, tank_notes)
  VALUES (2, 'grease', '410 Bayshore Blvd', 'Tampa', 'FL', '33606',
          'Trap by dumpster. Restaurant opens 10 — park in the rear.',
          'Kitchen interceptor; contact Maya Chen');
  → lastInsertRowid = 2

location_create:
  name: "Harbor Diner - 410 Bayshore Blvd"
  street_address: "410 Bayshore Blvd, Tampa, FL 33606"
  checkin_radius_m: 75
  idempotency_key: "loc-tank-2"
  → location_id: 9102

event_create:
  location_id: 9102
  title: "Tank service - 410 Bayshore Blvd"
  start_date: "2026-09-08"
  end_date:   "2026-11-06"
  idempotency_key: "event-tank-2-20260908"
  → event_id: 7102

form_assign: form_id 401, event_id 7102, idempotency_key "assign-service-manifest-7102"

sqlite_execute:
  UPDATE tanks SET zensched_location_id = 9102, zensched_event_id = 7102, event_valid_until = '2026-11-06'
  WHERE tank_id = 2;
```

> Added Harbor Diner, 410 Bayshore Blvd. Quarterly grease trap at $225, Tuesday Sep 8 at 11:00. Dumpster / rear-lot note is local only. This Service Manifest is not an official e-manifest; keep whatever the plant wants on their ticket.

## "Invite Luis Ortega, luis@example.com, and make him the default."

> Inviting a technician costs $0.25. OK?

Owner: *"yes"*

```
worker_invite:
  email: "luis@example.com"
  first_name: "Luis"
  last_name: "Ortega"
  idempotency_key: "worker-luis@example.com"
  → worker_id: 601, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO technicians (technician_name, email, zensched_worker_id)
  VALUES ('Luis Ortega', 'luis@example.com', 601);
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '601' WHERE key = 'default_worker_id';
```

> Invited Luis. He'll get an email with the app link and an activation code. He's the default tech now. Remember to give him Rosa's hatch / gate and the Harbor Diner dumpster note; I keep those off ZenSched on purpose.

Optional, if the owner wants a wider circle for rural tanks or restaurant rear lots:

```
policy_get: policy_id 0
policy_update:
  policy_id: 0
  settings_json: '{"geofence_enabled": true, "require_on_site": true, "checkin_radius_m": 150}'
```

The radius is on the **policy**, not on either location.

## "Schedule this week for Luis."

```
sqlite_query: SELECT * FROM customers_due;
  → 2026-09-07 | Rosa Delgado | semi | $375 | septic_pump | 90 min
               | tank 1 septic | evt 7101 | event_needs_roll 0 | worker 601 Luis
               | start_iso 2026-09-07T09:00:00-04:00 | end_iso 2026-09-07T10:30:00-04:00
               | shift-tank-1-20260907
    2026-09-08 | Harbor Diner | quarterly | $225 | grease_pump | 60 min
               | tank 2 grease | evt 7102 | event_needs_roll 0 | worker 601 Luis
               | start_iso 2026-09-08T11:00:00-04:00 | end_iso 2026-09-08T12:00:00-04:00
               | shift-tank-2-20260908
  (2 rows)

shift_create:
  event_id: 7101
  worker_id: 601
  start: "2026-09-07T09:00:00-04:00"
  end:   "2026-09-07T10:30:00-04:00"
  idempotency_key: "shift-tank-1-20260907"
  → shift_id: 88011, status: "scheduled", forms_installed: [401]

shift_create:
  event_id: 7102
  worker_id: 601
  start: "2026-09-08T11:00:00-04:00"
  end:   "2026-09-08T12:00:00-04:00"
  idempotency_key: "shift-tank-2-20260908"
  → shift_id: 88012, status: "scheduled", forms_installed: [401]
```

> Scheduled 2 stops for Luis this week:
> - Mon 9/7  9:00–10:30  Rosa Delgado, 1842 Palmetto Ct — septic pump
> - Tue 9/8 11:00–12:00  Harbor Diner, 410 Bayshore Blvd — grease trap
>
> Luis has been notified in the app and both stops have the Service Manifest attached. Each stop is about $0.35 once he punches in and out and you read the photo manifest ($0.10 + $0.10 + $0.15). Pass him the hatch / gate and the dumpster note yourself.

Nothing is written to SQLite here. If the owner asks "schedule this week" again, the identical idempotency keys make ZenSched return the same two shifts instead of creating duplicates.

## Luis does the work

Monday 8:58, at 1842 Palmetto Court, in the ZenSched app: **Check in** (GPS: 18 m from the pin, verified, $0.10). Finds the hatch behind the shed, pumps. Opens **Service Manifest**: Gallons = 1250; Tank condition = Good; two hatch photos; Disposal site = "Hillsborough County WW plant, ticket 4412"; Waste type = Septic. Submits (no signature). **Check out** 10:22 ($0.10).

Tuesday 10:55, 410 Bayshore Blvd rear lot: check in at the dumpster. Pumps the interceptor. Service Manifest: Gallons = 280; Tank condition = Fair; three hatch photos; Disposal site = "Hillsborough County WW plant, ticket 4418"; Waste type = Grease. Check out 11:48.

## "Record this week's jobs."

```
shift_list:
  date_from: "2026-09-07"
  date_to:   "2026-09-13"
  status:    "checked_out"
  → shifts: [
      { shift_id: 88011, event_id: 7101, worker_id: 601, date: "2026-09-07", start: "09:00", end: "10:30", status: "checked_out" },
      { shift_id: 88012, event_id: 7102, worker_id: 601, date: "2026-09-08", start: "11:00", end: "12:00", status: "checked_out" }
    ], count: 2

sqlite_query: SELECT zensched_shift_id FROM jobs WHERE zensched_shift_id IN (88011, 88012);
  → (none; not yet recorded)

sqlite_query: SELECT t.tank_id, t.customer_id, c.service_id, c.service_rate
              FROM tanks t JOIN customers c USING (customer_id)
              WHERE t.zensched_event_id = 7101;
  → 1, 1, 1, 375.00
```

Agent (metered read, rule 11):

> There are 2 manifests to pull, both with photos, so about $0.30 ($0.15 each). I'll read them once and keep the summaries locally. That's the last piece of the ~$0.35/stop meter (punches already billed when Luis checked in and out). OK?

Owner: *"go"*

```
form_export:
  form_id: 401
  since: "2026-09-07"
  until: "2026-09-13"
  format: "json"
  → row_count: 2, rows: [
      { submission_id: 4401, worker_id: 601, event_id: 7101, submitted_at: "2026-09-07 10:18:12",
        data: { gallons: 1250, tank_condition: "good",
                disposal_site: "Hillsborough County WW plant, ticket 4412",
                waste_type: "septic" },
        media: [ { cdn_url: "https://cdn.zensched.com/m/.../d1.jpg" },
                 { cdn_url: "https://cdn.zensched.com/m/.../d2.jpg" } ] },
      { submission_id: 4402, worker_id: 601, event_id: 7102, submitted_at: "2026-09-08 11:44:40",
        data: { gallons: 280, tank_condition: "fair",
                disposal_site: "Hillsborough County WW plant, ticket 4418",
                waste_type: "grease" },
        media: [ { cdn_url: "https://cdn.zensched.com/m/.../c1.jpg" },
                 { cdn_url: "https://cdn.zensched.com/m/.../c2.jpg" },
                 { cdn_url: "https://cdn.zensched.com/m/.../c3.jpg" } ] }
    ]
    billing: { meter: "form_media", units: 2, price: 0.30 }

shift_status: shift_id 88011
  → status "checked_out", actual_in "2026-09-07T08:58:10-04:00", actual_out "2026-09-07T10:22:05-04:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 18 },
               { type: "out", gps_verified: true, distance_from_site_m: 12 } ]
(free)

sqlite_execute:
  INSERT INTO jobs (customer_id, tank_id, service_id, completed_date, amount,
                    zensched_shift_id, zensched_event_id, zensched_worker_id,
                    actual_in, actual_out, duration_minutes, gps_verified, report_dc_id,
                    gallons, tank_condition, disposal_site, waste_type, photo_urls)
  VALUES (1, 1, 1, '2026-09-07', 375.00,
          88011, 7101, 601,
          '2026-09-07T08:58:10-04:00', '2026-09-07T10:22:05-04:00', 84, 1, 4401,
          1250, 'Good', 'Hillsborough County WW plant, ticket 4412', 'Septic',
          '["https://cdn.zensched.com/m/.../d1.jpg","https://cdn.zensched.com/m/.../d2.jpg"]');
  -- trigger: customers.next_service_date for Rosa → 2027-03-06 (+180 days)
  -- trigger: jobs.technician_id → 1 (Luis)

sqlite_execute:
  INSERT INTO jobs (customer_id, tank_id, service_id, completed_date, amount,
                    zensched_shift_id, zensched_event_id, zensched_worker_id,
                    actual_in, actual_out, duration_minutes, gps_verified, report_dc_id,
                    gallons, tank_condition, disposal_site, waste_type, photo_urls)
  VALUES (2, 2, 2, '2026-09-08', 225.00,
          88012, 7102, 601,
          '2026-09-08T10:55:02-04:00', '2026-09-08T11:48:18-04:00', 53, 1, 4402,
          280, 'Fair', 'Hillsborough County WW plant, ticket 4418', 'Grease',
          '["https://cdn.zensched.com/m/.../c1.jpg","https://cdn.zensched.com/m/.../c2.jpg","https://cdn.zensched.com/m/.../c3.jpg"]');
  -- trigger: customers.next_service_date for Harbor Diner → 2026-12-07 (+90 days from Sep 8)
```

> Recorded 2 jobs, both GPS-verified.
>
> Delgado septic: 1,250 gal, Good, Hillsborough County WW plant. Next due Mar 6 (semi, +180 days).
>
> Harbor Diner grease: 280 gal, Fair, same plant. Next due Dec 7. This is your copy from the Service Manifest, not an official e-manifest.

## "Pump log for last week."

```
sqlite_query: SELECT * FROM pump_log WHERE pump_date BETWEEN '2026-09-07' AND '2026-09-13';
  → 2026-09-08 | 410 Bayshore Blvd | Harbor Diner | grease | 280 | Grease
    | Hillsborough County WW plant, ticket 4418 | Fair | Luis Ortega
    2026-09-07 | 1842 Palmetto Court | Rosa Delgado | septic | 1250 | Septic
    | Hillsborough County WW plant, ticket 4412 | Good | Luis Ortega
```

> Your copy from the Service Manifest — not an official e-manifest:
>
> | Date | Tank | Gallons | Waste | Disposal | Condition | Tech |
> |---|---|---|---|---|---|---|
> | Sep 7 | 1842 Palmetto Court | 1,250 | Septic | Hillsborough County WW plant, ticket 4412 | Good | Luis Ortega |
> | Sep 8 | 410 Bayshore Blvd | 280 | Grease | Hillsborough County WW plant, ticket 4418 | Fair | Luis Ortega |
>
> Keep whatever the plant or the county wants on their ticket separately.

## "Draft invoices for everyone with uninvoiced work."

```
sqlite_query: SELECT * FROM jobs_to_invoice;
  → Harbor Diner | 1 job | 225.00 | 2026-09-08 .. 2026-09-08
    Rosa Delgado | 1 job | 375.00 | 2026-09-07 .. 2026-09-07

sqlite_execute:
  INSERT INTO invoices (customer_id, invoice_date, due_date, total_amount, line_items)
  SELECT j.customer_id, date('now'),
         date('now', '+' || (SELECT value FROM settings WHERE key = 'invoice_due_days') || ' days'),
         SUM(j.amount),
         json_group_array(json_object('job_id', j.job_id, 'date', j.completed_date, 'service', s.service_name,
                                      'amount', j.amount, 'shift_id', j.zensched_shift_id, 'gallons', j.gallons))
  FROM jobs j JOIN services s ON s.service_id = j.service_id
  WHERE j.invoiced = 0 AND j.customer_id = 1 GROUP BY j.customer_id;

sqlite_execute: UPDATE jobs SET invoiced = 1 WHERE invoiced = 0 AND customer_id = 1;
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | 2026-09-08 | 2026-09-22 | 375.00     (number assigned by trigger)

(same three statements for customer 2 → INV-2026-0002, 225.00)
```

The agent then writes the invoices out as text:

> Here are your two invoices. Paste each into an email or text.
>
> ```
> Gulf Coast Septic
> Invoice INV-2026-0001
> To: Rosa Delgado (rosa@example.com)
> Date: Sep 8, 2026    Due: Sep 22, 2026
>
>   Sep 7    Septic tank pump-out, 1842 Palmetto Court, 1,250 gal    $375.00
>
> Total due: $375.00
> Visit GPS-verified at the tank.
> ```
>
> ```
> Gulf Coast Septic
> Invoice INV-2026-0002
> To: Harbor Diner (maya@harbordiner.example)
> Date: Sep 8, 2026    Due: Sep 22, 2026
>
>   Sep 8    Grease trap pump-out, 410 Bayshore Blvd, 280 gal       $225.00
>
> Total due: $225.00
> Visit GPS-verified at the tank.
> ```
>
> Say "sent" when they're out and I'll note the date.

## "Sent. Rosa already paid."

```
sqlite_execute: UPDATE invoices SET sent_date = date('now') WHERE invoice_number IN ('INV-2026-0001', 'INV-2026-0002');
sqlite_execute: UPDATE invoices SET paid = 1, paid_date = date('now') WHERE invoice_number = 'INV-2026-0001';
```

> Marked both sent and INV-2026-0001 paid. Harbor Diner's $225 (INV-2026-0002) is outstanding, due Sep 22.

## Eight weeks later: "Schedule this week."

Neither account is due yet (Delgado next Mar 6, Harbor Diner next Dec 7). If the owner added an emergency, or a tank's event is about to expire while a stop is coming up:

```
sqlite_query: SELECT * FROM events_expiring;
  → tank 1 | Rosa Delgado | septic | event_valid_until 2026-11-05
```

When a later stop does land past that window:

```
event_create:
  location_id: 9101
  title: "Tank service - 1842 Palmetto Court"
  start_date: "2027-03-06"
  end_date:   "2027-05-04"
  idempotency_key: "event-tank-1-20270306"
  → event_id: 7201

form_assign: form_id 401, event_id 7201, idempotency_key "assign-service-manifest-7201"
sqlite_execute: UPDATE tanks SET zensched_event_id = 7201, event_valid_until = '2027-05-04' WHERE tank_id = 1;

shift_create: event_id 7201, worker_id 601, start "2027-03-06T09:00:00-04:00",
              end "2027-03-06T10:30:00-04:00", idempotency_key "shift-tank-1-20270306"
```

> Scheduled Delgado for Sat Mar 6 9:00. Her ZenSched event from September had expired, so I renewed it through May 4. Harbor Diner is not due until December.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Rosa's contact, $375 semi cadence, Harbor Diner $225 quarterly, prices | SQLite | CRM; ZenSched does not model rates or recurrence |
| Hatch location, gate code, pumper / hauler license | SQLite **only** | Privacy; never sent to ZenSched |
| Each tank's GPS location | ZenSched (integer ID in `tanks`) | Needed for geofenced check-in |
| Each tank's current ≤60-day event and its end date | ZenSched (integer ID + `event_valid_until` in `tanks`) | Shifts hang off events; renewed by the agent |
| The Service Manifest form | ZenSched (ID in `settings`) | Installed on the tech's phone per shift |
| Luis, his invite, his app | ZenSched (integer ID in `technicians`) | Workforce and notifications |
| The week's two shifts | ZenSched only | Live schedule; never copied |
| GPS punches, actual times | ZenSched only | Verified record; queried via `shift_status` / `timesheet_export` |
| Two manifests with hatch photos | ZenSched (originals); summary + photo URLs in `jobs` | Read once (metered), then pump log / invoices from SQLite |
| Two `jobs` rows referencing shift and submission IDs | SQLite | Billing + pump-log extract |
| Two invoices, one paid | SQLite | Billing |
