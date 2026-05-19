# AGENTS.md - ir-hvac-intake-ai

## Project Overview
HVAC lead intake automation system for **Immediate Response HVAC**. Automates lead intake from a Flutter form into AlloyDB AI, triggering Google Workspace workflows.

## Tech Stack
- **Runtime**: Firebase Cloud Functions (Node.js/TypeScript)
- **AI**: Vertex AI + Google ADK (Agent Development Kit)
- **Database**: AlloyDB AI (PostgreSQL-compatible)
- **Integrations**: Google Drive API, Google Calendar API
- **Frontend**: Flutter (external, consumes this API)
- **Future**: QuickBooks Online via MCP tools

---

## Core Workflow

### On Form Submission:
1. Receive intake data from Flutter app via HTTP Cloud Function
2. **If Insurance job**: Upsert PM in `project_managers` table (using email as conflict key)
3. Insert record in `lead_submissions` table
4. Create Google Drive folder: `[Property Address]_[PM Name]`
   - Create `Videos` subfolder
   - Create `Photos` subfolder
5. Create Google Calendar event on **Ghost Calendar**
   - Calendar ID: `c_82f31464fae8eeb8fd1cee1af6675655ffc9456594b656b049cc061323199f35`
   - Attach Drive folder link to event
6. Update lead record with `drive_folder_id` and `calendar_event_id`
7. Return success response with folder/event links

---

## Database Schema (AlloyDB AI)

### Table: `project_managers`
Stores Insurance Adjuster/PM profiles for auto-population and cross-referencing.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `pm_id` | UUID | PRIMARY KEY | |
| `full_name` | TEXT | INDEXED | For search/fuzzy matching |
| `company_name` | TEXT | | |
| `email` | TEXT | UNIQUE | **Upsert key** |
| `cell_phone` | TEXT | | |
| `billing_address` | TEXT | | |
| `name_embedding` | VECTOR | | For AlloyDB AI fuzzy search |
| `last_updated` | TIMESTAMP | | |

### Table: `lead_submissions`
Stores every individual job request.

| Column | Type | Constraints | Notes |
|--------|------|-------------|-------|
| `lead_id` | UUID | PRIMARY KEY | |
| `property_address` | TEXT | NOT NULL | |
| `job_type` | ENUM | | `Residential`, `Commercial`, `Res_Insurance`, `Comm_Insurance` |
| `claim_type` | ENUM | NULLABLE | `Flood`, `Fire`, `Abatement`, `Other` (Insurance only) |
| `job_categories` | JSONB | | Array of selected categories |
| `misc_description` | TEXT | | Only if "Miscellaneous" selected |
| `pm_id` | UUID | FK → project_managers | NULLABLE (non-insurance jobs) |
| `client_name` | TEXT | | |
| `client_email` | TEXT | | |
| `client_cell` | TEXT | | |
| `final_billing_address` | TEXT | | See billing logic below |
| `visit_requested` | TIMESTAMP | | |
| `access_instructions` | TEXT | | `Contact PM` or `Contact Client` |
| `scope_details` | TEXT | | Large text area |
| `drive_folder_id` | TEXT | | Set after folder creation |
| `calendar_event_id` | TEXT | | Set after event creation |
| `status` | TEXT | | `new`, `scheduled`, `completed` |
| `created_at` | TIMESTAMP | | |

---

## Form Logic Specification

### 1. Initial Fields
- **Field 1**: `property_address` (Text Input) - REQUIRED
- **Field 2**: `job_type` (Select)
  - Options: `Residential`, `Commercial`, `Residential Insurance`, `Commercial Insurance`

### 2. Job Type Branching Logic

#### Logic A (Standard Jobs)
When `Residential` or `Commercial` is selected:
- SKIP PM/Company fields
- SKIP Claim Type field
- Auto-populate `final_billing_address` = `property_address`
- Show all job categories (no filtering)

#### Logic B (Insurance Jobs)
When `Residential Insurance` or `Commercial Insurance` is selected:
- SHOW PM/Company fields (Field 3)
- SHOW Claim Type filter (Field 4)
- `final_billing_address` = PM's `billing_address`

### 3. PM Lookup Logic (Insurance Only)
- **Field 3**: `pm_name` (Searchable Database Field)
- On input: Query `project_managers` using ILIKE or **AlloyDB AI Vector Search** for fuzzy matching
- If PM found:
  - Auto-populate: `company_name`, `pm_email`, `pm_cell`, `billing_address`
  - Display confirmation: *"System shows you are with [Company Name]. Is this still correct?"*
- **Robust PM Record Management**: Relaxed email requirements for PMs. If you edit a PM's auto-populated info (like changing an email or phone number), the system intelligently identifies the existing record by Name + Company and updates it, preventing duplicate entries.
DATE on `project_managers`

### 4. Claim Type Filter (Insurance Only)
- **Field 4**: `claim_type` (Select)
- Options: `Flood`, `Fire`, `Abatement`, `Other`
- This filters the Job Category list

### 5. Job Categories (Multi-Select)
Display categories based on `claim_type` (or show ALL for non-insurance jobs):

#### Group A: Flood Options
- Inspection - Full HVAC Flood
- Inspection - Furnace System - Flood
- Inspection - Air Conditioner - Flood
- Inspection - HWT Flood
- Inspection - Boiler System Flood

#### Group B: Fire Options
- Inspection - Full HVAC Fire
- Inspection - Furnace System - Fire
- Inspection - Air Conditioner Fire
- Inspection - HWT Fire
- Inspection - Boiler System Fire
- Inspection - Emergency Commercial Fire
- Inspection - Fireplace

#### Group C: Abatement & Ductwork
- Inspection - Ductwork Residential
- Inspection - Ductwork Commercial
- Cleaning - Residential Duct
- Cleaning - Commercial Duct
- Re and Re - Ventilation System

#### Group D: General Re and Re (Replacement)
- Re and Re - Full HVAC
- Re and Re - Furnace
- Re and Re - AC
- Re and Re - HWT
- Re and Re - Furnace and HWT
- Re and Re - Furnace and AC
- Re and Re - Boiler unit
- Re and Re - Boiler unit and HWT

#### Group E: Service & Troubleshooting
- Troubleshooting - Furnace
- Troubleshooting - AC
- Troubleshooting - HVAC
- Thermostat - Service Call
- Miscellaneous (**Logic**: If selected, show free-flow text box → `misc_description`)

### 6. Final Contact & Logistics (Always Visible)
- **Field 5**: `client_name`
- **Field 6**: `client_email`
- **Field 7**: `client_cell`
- **Field 8**: `scope_details` (Text Area)
- **Field 9**: `visit_requested` (Date/Time Picker)
- **Field 10**: `access_instructions` (Radio)
  - ( ) Contact you (PM) directly
  - ( ) Contact the client directly

---

## Business Rules

### Billing Address Logic
```
IF job_type IN ('Residential', 'Commercial'):
    final_billing_address = property_address
ELSE IF job_type IN ('Res_Insurance', 'Comm_Insurance'):
    final_billing_address = pm.billing_address
```

### Upsert Logic (Insurance Jobs)
```sql
-- Logic: 
-- 1. Try to find existing PM by email (highest confidence link).
-- 2. If not found, try to find by (full_name, company_name) as a fallback.
-- 3. If found in either case, UPDATE the record with new info (allows updating emails).
-- 4. If not found at all, INSERT a new record.
-- This ensures PMs are tracked even without emails, and existing records are updated if info changes.
```

### Drive Folder Naming
```
[PM Name]_[Property Address]
├── Videos/
├── Photos/
└── Purchase Orders/
```
- For non-insurance jobs without PM: `[Client Name]_[Property Address]`

---

## API Endpoints

### POST `/api/intake`
Submit a new lead intake form.

**Request Body:**
```json
{
  "property_address": "123 Main St, Calgary, AB",
  "job_type": "Res_Insurance",
  "claim_type": "Flood",
  "job_categories": ["Inspection - Full HVAC Flood", "Inspection - HWT Flood"],
  "misc_description": null,
  "pm": {
    "full_name": "John Smith",
    "company_name": "ABC Insurance",
    "email": "john@abcins.com",
    "cell_phone": "403-555-1234",
    "billing_address": "456 Corporate Dr, Calgary, AB"
  },
  "client_name": "Jane Doe",
  "client_email": "jane@email.com",
  "client_cell": "403-555-5678",
  "scope_details": "Furnace and HWT damaged in basement flood...",
  "visit_requested": "2026-02-15T10:00:00Z",
  "access_instructions": "Contact PM"
}
```

**Response:**
```json
{
  "success": true,
  "lead_id": "uuid-here",
  "drive_folder_url": "https://drive.google.com/drive/folders/...",
  "calendar_event_url": "https://calendar.google.com/event?eid=..."
}
```

### GET `/api/pm/search?q={name}`
Search for PM by name (fuzzy matching via AlloyDB AI vectors).

**Response:**
```json
{
  "results": [
    {
      "pm_id": "uuid",
      "full_name": "John Smith",
      "company_name": "ABC Insurance",
      "email": "john@abcins.com",
      "cell_phone": "403-555-1234",
      "billing_address": "456 Corporate Dr, Calgary, AB"
    }
  ]
}
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `ALLOYDB_CONNECTION_NAME` | AlloyDB instance connection string |
| `ALLOYDB_DB_NAME` | Database name |
| `ALLOYDB_USER` | Database user |
| `ALLOYDB_PASSWORD` | Via Secret Manager |
| `GOOGLE_DRIVE_PARENT_FOLDER_ID` | Parent folder for all lead folders |
| `GHOST_CALENDAR_ID` | `c_82f31464fae8eeb8fd1cee1af6675655ffc9456594b656b049cc061323199f35` |
| `GCP_PROJECT_ID` | Google Cloud project ID |

---

## AlloyDB AI Optimization

### Vector Embeddings for Fuzzy PM Search
Create embeddings on `full_name` to enable fuzzy matching:
- User types "John Smyth" → suggests "Jonathan Smith"
- Prevents duplicate PM records

### JSONB for Job Categories
Store `job_categories` as JSONB array for analytics:
```sql
-- Example: Count flood-related furnace calls in February
SELECT COUNT(*) FROM lead_submissions
WHERE job_categories @> '["Inspection - Furnace System - Flood"]'
AND created_at >= '2026-02-01' AND created_at < '2026-03-01';
```

---

## QuickBooks Online Integration (ACTIVE)
Automated QBO sync triggered by Firestore document creation:
- **Trigger A** (`onLeadCreated`): Firestore `onDocumentCreated('leads/{leadId}')` → creates/matches QBO Customer → creates/matches QBO Project (`[Property Address] - [Client Name]`) → creates QBO Estimate with custom fields
- **Trigger B** (`syncCalendarTechnicians`): Scheduled every 5 minutes → polls Ghost calendar for new attendees → sparse-updates QBO Estimate "Technician" custom field
- **OAuth** (`qboAuthCallback`): One-time consent flow → tokens stored in Firestore `qbo_tokens/primary`

### QBO Field Mapping (per project_blueprint.md)
- **Line Item**: "HVAC Service", Description = `scope_details`
- **PO Number**: `po_number` → QBO Estimate `PONumber`
- **Custom Field 1 (Job Type)**: `job_categories.join(' | ')`
- **Custom Field 2 (Claim Type)**: `claim_type`
- **Custom Field 3 (Project Manager)**: `pm.full_name`
- **Custom Field 4 (Technician)**: Updated via calendar sync

### QBO TimeActivity — Automatic Drive/Labor Time Tracking
The system automatically creates and manages QBO TimeActivities for each lead:
- **Drive Time**: Created when tech taps "Start Navigation" (`techStartNavigation`). Linked to QBO Project via `CustomerRef`. Uses `findOrCreateNamedServiceItem('Drive Time')` to resolve/create the QBO Service Item.
- **Labor Time**: Created when tech enters geofence (`techClockIn`). Drive Time is stopped (end = now) and Labor Time starts simultaneously. Uses `findOrCreateNamedServiceItem('Labor Time')`.
- **Report Submission**: Labor Time is stopped when the tech submits their report (`techSubmitReport`).
- All TimeActivities use `NameOf: 'Other'` with `OtherName` = tech name, and `ItemRef` = the service item.
- Activity IDs and SyncTokens are stored in Firestore (`drive_time_activity_id`, `labor_time_activity_id`) for update operations.

### Firestore Collections
- `leads/{leadId}` — Lead data + QBO IDs (`qbo_customer_id`, `qbo_project_id`, `qbo_estimate_id`) + time tracking fields (`drive_start_time`, `drive_end_time`, `labor_start_time`, `drive_time_activity_id`, `labor_time_activity_id`)
- `qbo_tokens/primary` — OAuth access/refresh tokens (server-side only)
- `pms/{pmId}` — PM autocomplete cache
- `price_book/{itemId}` — Standard services, prices, and descriptions.
- `estimates/{estimateId}` — Bespoke estimates. Contains nested collection `line_items`. Status tracks `draft`, `sent_to_client`, `partially_approved`, `approved`.
- `invoices/{invoiceId}` — Finalized invoices for finished work.

---

## File Structure
```
ir-hvac-intake-ai/
├── functions/
│   ├── src/
│   │   ├── index.ts              # Cloud Functions entry point (16 exports)
│   │   ├── config/
│   │   │   └── index.ts          # Environment config + secrets
│   │   ├── services/
│   │   │   ├── alloydb.ts        # AlloyDB AI connection & queries
│   │   │   ├── calendar.ts       # Google Calendar event creation
│   │   │   ├── drive.ts          # Google Drive folder creation
│   │   │   ├── email.ts          # Gmail API confirmation emails
│   │   │   ├── location.ts       # Geocoding & clock-in proximity
│   │   │   ├── quickbooks.ts     # QBO OAuth, Customer/Project/Estimate CRUD
│   │   │   ├── reportGenerator.ts# Gemini report generation
│   │   │   └── vision.ts         # Vision API
│   │   ├── handlers/
│   │   │   ├── lead-intake.ts    # Main intake workflow (+ Firestore write)
│   │   │   ├── lead-lifecycle.ts # Status machine + Drive/Labor Time + Code Red
│   │   │   └── qbo-sync.ts       # QBO sync + calendar tech detection
│   │   ├── types/
│   │   │   └── index.ts          # TypeScript interfaces
│   │   └── utils/
│   │       └── index.ts          # Utility functions
│   ├── package.json
│   ├── tsconfig.json
│   └── .env.example
├── lib/                           # Flutter Tech Report app (separate from intake)
│   ├── main.dart
│   ├── screens/report_draft_screen.dart
│   └── services/
├── web-form/                      # Static HTML intake form (Firebase Hosting)
│   ├── index.html
│   └── clock-in.html
├── firebase.json
├── firestore.rules
├── project_blueprint.md           # Source of truth for QBO mapping
├── .firebaserc
├── AGENTS.md
└── README.md
```
