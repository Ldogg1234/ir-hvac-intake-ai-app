# IMR HVAC — Project Blueprint

## 1. System Overview
Two-app system powered by a shared Firebase backend (Firestore, Cloud Functions, Auth).

### Admin App (Ops Group)
**Users:** Nicole, Rob, and other office/operations staff.
**Purpose:** Manage every lead from intake to invoice.
**Features:**
- Lead Intake form (web form → Cloud Function → AlloyDB + Firestore + Calendar + Drive)
- Dashboard: view/filter/search all leads across every status
- Tech Assignment: assign a technician to a lead (updates Calendar + QBO Estimate)
- QBO Project & Estimate management (create, view, edit)
- Edit Property Address, PO Number, Client Contact info (→ bidirectional QBO sync)
- Status progression controls (advance a lead through the state machine)

### Tech App (Field Crew)
**Users:** Field technicians (identified by their @immediateresponsehvac.ca email).
**Purpose:** View assigned jobs, clock in on-site, and submit AI-generated reports.
**Features:**
- Assigned Job List: only jobs where `technician_email == currentUser.email`
- Geofenced Clock-in: verify tech is within radius of `property_address` before allowing clock-in
- AI Report Generation: speech-to-text notes → Vertex AI → professional PDF report
- Photo capture and attachment to job record
- Job status updates (In-Progress → Report-Submitted)

## 2. Status State Machine
Every lead follows this linear flow. Only forward transitions are allowed.

```
Intake → Scheduled → In-Progress → Report-Submitted → Invoiced
```

**Intake** — Set by System when lead is submitted via web form.
**Scheduled** — Set by Admin when tech is assigned and calendar event is confirmed.
**In-Progress** — Set by Tech when they clock in at job site (geofence verified).
**Report-Submitted** — Set by Tech when they submit the completed AI report.
**Invoiced** — Set by Admin when Estimate is converted to Invoice in QBO.

Firestore field: `leads/{leadId}.status` (string, one of: `intake`, `scheduled`, `in-progress`, `report-submitted`, `invoiced`).

## 3. Access Control Rules

### Source of Truth
Firestore is the master for all lead data. Changes in Firestore push to QBO, never the reverse.

### Admin App (Ops Group)
- Can read ALL leads regardless of status or assignment
- Can WRITE/EDIT: `property_address`, `po_number`, `client_name`, `client_cell`, `client_email`, `status`, `technician_email`
- Can advance status forward through the state machine
- Edits to address/contact fields trigger bidirectional QBO sync (Cloud Function)

### Tech App (Field Crew)
- Can ONLY read leads where `technician_email == request.auth.token.email`
- Can WRITE: `status` (only `in-progress` and `report-submitted` transitions), `clock_in_at`, `clock_out_at`, `report_id`
- CANNOT edit: `property_address`, `po_number`, `client_name`, `client_cell`, `client_email`
- CANNOT see unassigned or other techs' jobs

### Firestore Security Rules (enforced)
- Company domain (`@immediateresponsehvac.ca`) required for all access
- `leads` collection: read allowed for domain users; writes only via Admin SDK (Cloud Functions)
- `qbo_tokens` collection: no client access (Admin SDK only)

## 4. QBO Field Mapping (Web Form → QBO)
- **Customer:** `client_name` → DisplayName, `client_cell` → PrimaryPhone, `client_email` → PrimaryEmailAddr
- **Project:** `[property_address] - [client_name]` → DisplayName (sub-customer, Job=true)
- **Estimate Description:** `scope_details` → Line Item Description
- **Estimate P.O. Number:** `po_number` → PONumber
- **Estimate ShipAddr:** `property_address` → ShipAddr.Line1
- **Custom Field 1 (Job Type):** `job_categories` joined by ` | `
- **Custom Field 2 (Claim Type):** `claim_type`
- **Custom Field 3 (Project Manager):** `pm_full_name`
- **Custom Field 4 (Technician):** Updated via Calendar attendee sync

## 5. Technical Specs
- **Firebase Project:** `immediate-response-ai-b18b8`
- **QBO Company ID:** 9130 3494 4104 6016
- **Database:** Firestore (lead data, QBO IDs, OAuth tokens) + AlloyDB (PM directory)
- **Functions:** 2nd Gen Firebase Cloud Functions (Node.js/TypeScript)
- **Service Accounts:**
	- `hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com` — Cloud Functions SA
	- `gmail-automation-sa@immediate-response-ai.iam.gserviceaccount.com` — Gmail Domain-Wide Delegation SA
- **Calendar Impersonation:** `admin@immediateresponsehvac.ca` (Domain-Wide Delegation)
- **Gmail Impersonation:** `nicole@immediateresponsehvac.ca` (Domain-Wide Delegation, scope: `https://mail.google.com/`)
- **Hosting:** Firebase Hosting — `main` target (web form), `app` target (Flutter web build)
- **Deep Linking:** Root `/job/:leadId` routes to report draft.
- **Timezone:** `America/Edmonton` (Mountain Time)
- **AlloyDB:** Private IP `10.29.0.2`, port 5432, SSL required, VPC Connector `hvac-connector`

### Secrets (Firebase Secret Manager)
- `ALLOYDB_PASSWORD` — AlloyDB user password
- `GMAIL_SERVICE_ACCOUNT_KEY` — Full JSON key for gmail-automation-sa (Domain-Wide Delegation)
- `QBO_CLIENT_ID` — QuickBooks OAuth client ID (Production keys)
- `QBO_CLIENT_SECRET` — QuickBooks OAuth client secret
- `QBO_REALM_ID` — QuickBooks company realm ID

### Environment Variables
- `ALLOYDB_CONNECTION_NAME`, `ALLOYDB_DB_NAME`, `ALLOYDB_USER`
- `GCP_PROJECT_ID`
- `GOOGLE_DRIVE_PARENT_FOLDER_ID` — Root Drive folder for all lead folders
- `GHOST_CALENDAR_ID` — `c_82f31464fae8eeb8fd1cee1af6675655ffc9456594b656b049cc061323199f35@group.calendar.google.com`
- `GOOGLE_MAPS_API_KEY`, `CLOCK_IN_BASE_URL`

## 6. UI/UX Implementation Details

### Admin Dashboard (`/admin`)
- **Tabs**: "New Leads" (Intake) and "Review" (Submitted Reports).
- **Scheduling Modal**: 
	- Technician Dropdown (mapped to Ops Group).
	- Date/Time Pickers.
	- Trigger: "CONFIRM ASSIGNMENT" calls `assignTech` (Sets status to `scheduled`).
- **Insurance Approval Dashboard**:
	- **Nicole's Review**: View side-by-side technical metrics, photos, and System Status badge.
	- **Edit Justifications**: Editable AI-generated Technical Justifications (TSSA/CSA-cited, no fluff).
	- **Approve & Send**: Trigger calls `generatePdfReport` → saves PDF to `reports/approved/`, emails Ops with PDF attached, flags QBO time for export.

### Tech Home — "Daily Bible" (`/tech`)
- **Next Job Card**: Dynamic states based on "Drive vs Labor" logic:
	- **Status: Scheduled** → Button: `START NAVIGATION` (Calls `techStartNavigation`, transitions to `in-progress`, starts QBO Drive Time).
	- **Status: In-Progress (Driving)** → Button: `I'VE ARRIVED (CLOCK IN)` (Calls `techClockIn`, stops Drive Time, starts Labor Time).
	- **Status: In-Progress (At Site)** → Button: `CONTINUE TO REPORT` (Navigates to Report Draft).
- **Upcoming Jobs**: Vertical list of future assignments for the week.

### Report Draft Screen
- **STT Interface**: Large record button for capturing site notes.
- **AI Generation**: Transforms raw notes into professional summaries using Gemini.
- **Media Warehouse**: Multi-file uploader (Photos/Videos) categorized by Brand/Model.
- **Health Audit Visuals**: Real-time gauge charts for Gas Pressure, Static Pressure, and Temp Rise.
- **Evidence Mapping**: Side-by-side layout pairing inspection photos with AI visual analysis.
- **Submission**: Button calls `techSubmitReport` (stops Labor Time, transitions to `report-submitted`).

## 7. QBO OAuth Flow
- **Tokens stored in:** `Firestore → qbo_tokens/primary` (`access_token`, `refresh_token`, `expires_in`, `updated_at`)
- **Auto-refresh:** `getAccessToken()` checks `updated_at + expires_in`. If expired, calls `oauthClient.refresh()` and writes new tokens back.
- **Consent flow:** `GET /qboAuth` → redirects to Intuit → callback at `GET /qboAuthCallback` → calls `exchangeCodeForTokens()` → stores tokens.
- **Production keys required** — Development keys only work in sandbox. The redirect URI must match exactly in the Intuit Developer Portal Production settings.
- **Known issues fixed:**
	1. Development keys stored instead of Production keys
	2. Windows PowerShell `echo` injects `\r\n` into Secret Manager values (visible as `%0D%0A` in URL-encoded redirect)
	3. Missing IAM roles: `roles/datastore.user` (Firestore) and `roles/iam.serviceAccountTokenCreator` (Eventarc)

## 8. QBO Time Tracking (Drive Time / Labor Time)
Three billable activity types, each backed by a QBO `TimeActivity` record linked to the project:

### Activity Types
- **Drive Time** — Created when tech starts navigation (`techStartNavigation`). `BillableStatus: Billable`. Stopped when tech clocks in at site.
- **Labor Time** — Created when tech arrives on site (`techClockIn`). `BillableStatus: Billable`. Stopped when tech submits report.
- **Non-Billable Drive** — Created when a drive is cancelled/rescheduled (`cancelDrive`). `BillableStatus: NotBillable`. Company-absorbed cost for wasted trip.

### QBO TimeActivity Lifecycle
1. `createTimeActivity()` — Creates activity with `startTime`, `Hours: 0`, `Minutes: 0`. Linked to project via `CustomerRef`.
2. `updateTimeActivity()` — Sets `EndTime`, computes `Hours`/`Minutes` from `startTime → endTime` delta.
3. Each activity type auto-creates its QBO Service Item via `findOrCreateNamedServiceItem()` if it doesn't exist.

### Firestore Fields (on `leads/{leadId}`)
- `drive_time_activity_id`, `drive_time_activity_sync_token` — QBO Drive Time record
- `labor_time_activity_id`, `labor_time_activity_sync_token` — QBO Labor Time record
- `drive_start_time`, `drive_end_time` — ISO timestamps for drive phase
- `labor_start_time`, `labor_end_time` — ISO timestamps for labor phase

### QBO Export Flag
- `qbo_export_status: 'ready'` — Set at PDF generation so Louise sees entries in her Monday queue
- `qbo_export_flagged_at` — Timestamp of when the flag was set

## 9. Server-Side Timer (Survives App Close)
The Flutter app can be closed and reopened without losing the running clock.

### How It Works
- `leads/{leadId}.active_timer` — Object: `{ type: 'drive' | 'labor', started_at: ISO_string }`
- Set when `techStartNavigation` (type: `drive`) or `techClockIn` (type: `labor`) is called
- Cleared (`FieldValue.delete()`) when `techSubmitReport` or `cancelDrive` is called
- `getTimerState` callable — App calls on startup. Returns `timerType`, `startedAt`, `elapsedSeconds`, and lead context. App resumes the clock display from `elapsedSeconds`.

## 10. Geofence & Location Services
- **Geocoding:** Google Maps Geocoding API (`geocodeAddress()`) converts property address → lat/lng
- **Proximity:** Haversine formula (`haversineDistance()`) computes great-circle distance between tech GPS and property coords
- **Threshold:** 200 metres (`config.googleMaps.proximityThresholdMetres`). Tech must be within 200m to clock in.
- **Clock-in URL:** Generated per-lead (`generateClockInUrl()`), embedded in Drive folder. Opens a web page that reads GPS and calls `verifySiteProximity()` on the backend.
- **Enforcement:** `handleTechClockIn()` rejects with error if `distanceMetres > 200`.

## 11. Google Drive Folder Structure
Created per-lead by `createLeadFolderStructure()`. Folder name: `[PM Name or Client Name]_[Property Address]`

```
[PM/Client Name]_[Property Address]/
├── Inspection Photos/
├── Post Job Photos/
├── Videos/
├── Reports/
├── Meter Readings/
└── Purchase Orders/
```

- **Permissions:** Editor access granted to `ops@immediateresponsehvac.ca` and `techs@immediateresponsehvac.ca`. Anyone with link can write (for PM/client uploads).
- **Domain-Wide Delegation:** Impersonates `admin@immediateresponsehvac.ca` for Drive API calls.
- **Meter Readings Processing:** `processMeterReadings()` scans the Meter Readings folder, analyzes images with Vision API, renames files to `[Type]_[Value][Unit]_[STATUS].ext` (e.g., `CO_45ppm_DANGER.jpg`).
- **Address Truncation:** Removes postal code and ", Canada" from Google Maps-formatted addresses for cleaner folder names.

## 12. Email Architecture (Gmail API + Domain-Wide Delegation)
- **Auth:** JWT with service account `gmail-automation-sa`, impersonating `nicole@immediateresponsehvac.ca`
- **Scope:** `https://mail.google.com/` (full Gmail access, matches Admin Console DWD config)
- **Private Key Fix:** `credentials.private_key.replace(/\\n/g, '\n')` — Secret Manager stores `\n` as literal characters

### Email Types
1. **Customer Confirmation** (`sendCustomerConfirmationEmail`) — Sent on intake. Insurance → PM email, Regular → client email, fallback → `admin@immediateresponsehvac.ca`. Always CC `nicole@`.
2. **PM Job Scheduled** (`sendEmail` in lifecycle) — Sent when tech is assigned. Includes 4-hour service window.
3. **Ops Report Submitted** (`sendEmail` in lifecycle) — Sent when tech submits report. Links to Review Dashboard.
4. **Ops Final Report** (`sendEmailWithAttachment`) — Sent when PDF is generated. Includes PDF as MIME multipart/mixed attachment. Subject: `[Address] | [Claim Type] | Final Report by [Tech Name]`.
5. **Code Red Alert** (`sendEmail` in lifecycle) — Sent when lead is stuck in intake > 4 hours.

## 13. Code Red & PM Notifications

### Code Red (Stale Lead Detection)
- **Trigger:** `onSchedule` runs every 30 minutes
- **Logic:** Finds leads with `status == 'intake'` AND `created_at` older than 4 hours AND `priority_flag != true`
- **Action:** Sets `priority_flag: true`, `code_red_at: serverTimestamp()`. Emails Nicole.
- **Subject:** `🚨 CODE RED: [Address] — Intake > 4 hours`

### PM Email Notification (4-Hour Window)
- When `assignTech` is called, calculates `pm_notification_time = scheduledTime + 4 hours`
- Sends "Job Scheduled" email to PM with window: `[startFormatted] – [endFormatted]`

## 14. Calendar Auto-Accept (Domain-Wide Delegation)
When a tech is assigned to a lead:
1. `addAttendeesToEvent()` adds the tech as an attendee on the Ghost calendar
2. `acceptEventForAttendee()` impersonates the tech via DWD, fetches the event from their perspective, sets `responseStatus: 'accepted'`
3. Result: event appears on the tech's personal calendar without manual acceptance

### Calendar Color Codes
- **Yellow (5):** To Be Scheduled (new lead, time forced to 6:00 AM)
- **Green (10):** Scheduled (tech assigned, confirmed time)
- **Blue (9):** In-Progress (tech driving to site)
- **Purple (3):** Report Submitted

### Unscheduled Event Rollover
- `moveUnscheduledEvents()` runs daily at 6 AM Mountain. Finds yesterday's events with `[UNSCHEDULED]` in the title and moves them to today.

## 15. Cancel Drive Flow
Used when a job is cancelled/rescheduled after the tech has already started driving.

1. Validates caller is Ops or assigned tech, and lead is `in-progress` with no `labor_start_time` (still driving)
2. Stops the existing QBO Drive Time activity (sets endTime)
3. Creates a **Non-Billable Drive** activity with the same duration (`BillableStatus: NotBillable`)
4. Reverts lead status to `scheduled`
5. Clears all drive state fields (`drive_start_time`, `navigation_url`, `active_timer`, etc.)
6. Reverts calendar color to Green

## 16. AlloyDB (PM Directory)
- **Host:** `10.29.0.2:5432` (private IP, VPC Connector required)
- **Tables:** `project_managers`, `lead_submissions`
- **PM Upsert:** `INSERT ... ON CONFLICT (email) DO UPDATE` — deduplicates PMs by email
- **PM Search:** `ILIKE %query%` on `full_name`, returns top 10 matches
- **Timeout wrapper:** All AlloyDB calls wrapped in `withTimeout(promise, 3000ms)` to prevent hanging. Failures are non-blocking — email is already sent by then.
- **Connection pool:** `pg.Pool`, max 5 connections, 10s connection timeout, SSL required.

## 17. Firestore `leads/{leadId}` — Complete Field Contract

### Intake Fields (set on creation)
- `property_address`, `apartment_number`, `job_type`, `claim_type`
- `job_categories[]`, `misc_description`, `scope_details`
- `client_name`, `client_email`, `client_cell`
- `pm_full_name`, `pm_email`, `pm_cell_phone`
- `po_number`, `visit_requested`, `visit_status`
- `access_instructions`, `lockbox_code`, `gate_code`
- `drive_folder_id`, `drive_folder_url`
- `calendar_event_id`, `calendar_event_url`
- `status`, `created_at`

### QBO Sync Fields (set by `handleLeadCreated`)
- `qbo_customer_id`, `qbo_project_id`
- `qbo_estimate_id`, `qbo_estimate_sync_token`, `qbo_doc_number`
- `qbo_synced_at`, `qbo_sync_error`, `qbo_sync_attempted_at`

### Lifecycle Fields (set by lead-lifecycle handlers)
- `technician`, `technician_email`, `technician_assigned_at`
- `scheduled_time`, `pm_notification_time`
- `status_updated_at`, `status_updated_by`
- `drive_start_time`, `drive_end_time`, `navigation_url`
- `drive_time_activity_id`, `drive_time_activity_sync_token`
- `clock_in_at`, `clock_in_coords` (`{ lat, lng }`)
- `labor_start_time`, `labor_end_time`
- `labor_time_activity_id`, `labor_time_activity_sync_token`
- `active_timer` (`{ type, started_at }` or deleted)
- `report_id`, `clock_out_at`
- `drive_cancelled_at`, `drive_cancelled_by`
- `priority_flag`, `code_red_at`

### PDF / Export Fields (set by `generatePdfReport`)
- `qbo_export_status`: `'ready'`
- `qbo_export_flagged_at`

### QBO Internal Fields Set (infinite-loop guard)
All of the above non-intake fields are in `QBO_INTERNAL_FIELDS` to prevent the `onDocumentUpdated` trigger from re-syncing when lifecycle/QBO handlers write back to the doc.

## 18. Project Outputs
- **Live Tech Dashboard**: Real-time sync of technician progress and geofence events.
- **Visual Health Audit Charts**: Professionally visualized meter readings for client transparency.
- **AI-Powered Professional PDF**: Final PDF report compiled from notes, charts, photos, and AI analysis.

## 19. Cloud Functions Registry (The 23 Core Services)
1. `handleIntake`: Webhooks from lead form.
2. `assignTech`: Calendar/QBO/Firestore sync.
3. `techStartNavigation`: Start 'Drive Time'.
4. `techClockIn`: Verify geofence & start 'Labor Time'.
5. `techSubmitReport`: Stop Labor & lock report.
6. `getProfessionalReport`: Gemini-powered summarizer.
7. `getReportForReview`: Nicole's administrative API.
8. `generatePdfReport`: Branded PDF generator + Ops email delivery + QBO export flag.
9. `syncQboCustomer`: Bidirectional CRM sync.
10. `syncQboEstimate`: QBO financial sync.
11. `handleCalendarSync`: Google Calendar integration.
12. `mediaWarehouseIngest`: Structured storage of logs.
13. `faultCodeLookup`: Expert knowledge retrieval.
14. `notifyTechPush`: FCM service for job alerts.
15. `notifyAdminStatus`: Alert ops on job completions.
16. `authRotateQbo`: Manage OAuth lifecycle.
17. `getKnowledgeBase`: RAG for HVAC technical data.
18. `validateGeofence`: Spatial verification service.
19. `exportToQboInvoice`: Final billing transition.
20. `cleanupStorage`: Automated lifecycle management.
21. `opsWeeklyReport`: Aggregated performance metrics.
22. `updatePropertyData`: Contextual enrichment of addresses.
23. `handleAdjusterPortal`: External read-only access for insurance.

## 20. Insurance Claim Validation Standards
- **Gauges as Evidence**: Every metric (Gas Pressure, etc.) must be paired with a 'Source Evidence' photo.
- **Timestamped Logs**: All status transitions must record GPS and Server Time for audit trails.
- **Branding**: Reports must include 'IMR HVAC' logo and 'Claim Validation Audit' header.
- **AI Human-in-the-Loop**: All AI-generated text must be reviewable/editable by authorized Ops staff before client delivery.
- **Tech-to-Ops Workflow**: 
	- Upon tech submission, the `techSubmitReport` function triggers an automated email notification to `ops@immediateresponsehvac.ca`.
	- Email contains the 'View Draft' link for Nicole/Rob to perform the final Insurance Approval.
	- Upon PDF approval, `generatePdfReport` emails `ops@immediateresponsehvac.ca` with the PDF attached and flags QBO time entries as Ready for Export.

## 21. AI Reporting Engine (Insurance Adjuster Focus)
The Gemini prompt and PDF output are tuned for **insurance adjusters**, not homeowners.

### Gemini Prompt Priorities (in order)
1. **Cause of Loss** — Root cause of damage (flood, fire, mechanical failure, etc.)
2. **Scope of Remediation** — Every component needing replacement/repair to restore code-compliant operation
3. **Safety & Code Violations** — Specific TSSA/CSA citations; no generic language

### System Status Determination
- **Salvageable**: Minor repairs (<30% of replacement cost)
- **Partial Repair**: Core unit repairable (30–70% of replacement)
- **Total Loss**: Cannot be safely/economically repaired (cracked heat exchanger, submerged electronics, fire-damaged gas valve, etc.)

### Report Data Model (`reports/{leadId}`)
- `systemStatus`: `Salvageable` | `Partial Repair` | `Total Loss`
- `causeOfLoss`: string
- `scopeOfRemediation`: string
- `technicalJustifications[]`: `{ component, justification, standard }` — each cites TSSA/CSA/manufacturer spec
- `technicalMetrics[]`: `{ metric, value, unit, status, recommended, sourcePhotoUrl }`
- `equipmentId`: `{ brand, model, serial, age, refrigerant }`
- `executiveSummary`, `systemFindings`, `recommendations[]`, `safetyNotes`
- `pdfUrl`, `pdfGeneratedAt`, `pdfGeneratedBy`, `reviewStatus`

### PDF Output
- **Total Loss Banner**: Red alert bar at top of page when `systemStatus === 'Total Loss'`
- **Dynamic Title**: `[Property Address] | [Claim Type] | [PM Full Name]` in header + PDF metadata
- **Dynamic Filename**: `[Property_Address]_[Claim_Type]_[PM_Full_Name].pdf` (sanitized, fallbacks to `Service_Report`)
- **Storage Path**: `reports/approved/{filename}.pdf` in Firebase Storage
- **Sections**: Cause of Loss → Executive Summary → System Findings → Scope of Remediation → Technical Justifications → Technical Metrics (gauge charts) → Safety & Compliance → Recommendations → Damage Evidence (inspection photos) → Post-Remediation Verification (completion photos)
- **Dual-Bucket Photos**: Inspection photos labeled "Damage Evidence", completion photos labeled "Post-Remediation Verification"

### Post-Generation Automation
- **Ops Email**: Sent to `ops@immediateresponsehvac.ca` with PDF attached. Subject: `[Property Address] | [Claim Type] | Final Report by [Tech Name]`
- **QBO Export Flag**: `leads/{leadId}.qbo_export_status` set to `ready` + `qbo_export_flagged_at` timestamped — Louise's Monday queue filters on this field

### Firestore Fields Added to `leads/{leadId}`
- `qbo_export_status`: `'ready'` (set at PDF generation)
- `qbo_export_flagged_at`: timestamp
- Both added to `QBO_INTERNAL_FIELDS` set to prevent infinite update loops
