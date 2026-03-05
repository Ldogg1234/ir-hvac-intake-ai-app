CREATE TABLE IF NOT EXISTS project_managers (
  pm_id UUID PRIMARY KEY,
  full_name TEXT NOT NULL,
  company_name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  cell_phone TEXT,
  billing_address TEXT,
  last_updated TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pm_full_name ON project_managers (full_name);

CREATE TABLE IF NOT EXISTS lead_submissions (
  lead_id UUID PRIMARY KEY,
  property_address TEXT NOT NULL,
  job_type TEXT NOT NULL,
  claim_type TEXT,
  job_categories JSONB NOT NULL,
  misc_description TEXT,
  pm_id UUID REFERENCES project_managers(pm_id),
  client_name TEXT NOT NULL,
  client_email TEXT,
  client_cell TEXT,
  final_billing_address TEXT NOT NULL,
  visit_requested TIMESTAMP NOT NULL,
  access_instructions TEXT,
  scope_details TEXT,
  drive_folder_id TEXT,
  calendar_event_id TEXT,
  status TEXT NOT NULL DEFAULT 'new',
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lead_status ON lead_submissions (status);
CREATE INDEX IF NOT EXISTS idx_lead_created ON lead_submissions (created_at);
