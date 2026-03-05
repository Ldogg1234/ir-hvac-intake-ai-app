/**
 * AlloyDB AI Service
 * Handles database operations for HVAC intake system
 */

import { Pool, PoolConfig } from 'pg';
import { v4 as uuidv4 } from 'uuid';
import { config } from '../config';
import { ProjectManager, LeadSubmission, PMInput, LeadStatus } from '../types';

// Database connection pool (lazy initialized)
let pool: Pool | null = null;

// AlloyDB instance private IP
const ALLOYDB_IP = '10.29.0.2';

/**
 * Get or create database connection pool
 */
function getPool(): Pool {
  if (!pool) {
    // Get password from environment (set by Secret Manager binding)
    const password = process.env.ALLOYDB_PASSWORD || '';
    console.log(`AlloyDB connection: host=${ALLOYDB_IP}, user=${config.alloydb.user}, db=${config.alloydb.dbName}, pw_length=${password.length}`);
    
    const poolConfig: PoolConfig = {
      host: ALLOYDB_IP,
      port: 5432,
      database: config.alloydb.dbName,
      user: config.alloydb.user,
      password: password,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 10000,
      ssl: { rejectUnauthorized: false }, // AlloyDB requires SSL
    };

    pool = new Pool(poolConfig);

    pool.on('error', (err) => {
      console.error('Unexpected error on idle client', err);
    });
  }

  return pool;
}

// ============================================
// Project Manager Operations
// ============================================

/**
 * Upsert a project manager (insert or update on email conflict)
 */
export async function upsertProjectManager(pm: PMInput): Promise<ProjectManager> {
  const db = getPool();
  
  const query = `
    INSERT INTO project_managers (pm_id, full_name, company_name, email, cell_phone, billing_address, last_updated)
    VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ON CONFLICT (email) DO UPDATE SET
      full_name = EXCLUDED.full_name,
      company_name = EXCLUDED.company_name,
      cell_phone = EXCLUDED.cell_phone,
      billing_address = EXCLUDED.billing_address,
      last_updated = NOW()
    RETURNING *
  `;

  const pmId = uuidv4();
  const values = [pmId, pm.full_name, pm.company_name, pm.email, pm.cell_phone, pm.billing_address];

  const result = await db.query(query, values);
  return result.rows[0] as ProjectManager;
}

/**
 * Search for PMs by name using ILIKE (fuzzy matching)
 * TODO: Implement vector search for better fuzzy matching
 */
export async function searchPMByName(searchQuery: string): Promise<ProjectManager[]> {
  const db = getPool();
  
  const query = `
    SELECT pm_id, full_name, company_name, email, cell_phone, billing_address, last_updated
    FROM project_managers
    WHERE full_name ILIKE $1
    ORDER BY full_name
    LIMIT 10
  `;

  const values = [`%${searchQuery}%`];
  const result = await db.query(query, values);
  return result.rows as ProjectManager[];
}

/**
 * Get PM by email
 */
export async function getPMByEmail(email: string): Promise<ProjectManager | null> {
  const db = getPool();
  
  const query = `
    SELECT pm_id, full_name, company_name, email, cell_phone, billing_address, last_updated
    FROM project_managers
    WHERE email = $1
  `;

  const result = await db.query(query, [email]);
  return result.rows[0] as ProjectManager || null;
}

/**
 * Get PM by ID
 */
export async function getPMById(pmId: string): Promise<ProjectManager | null> {
  const db = getPool();
  
  const query = `
    SELECT pm_id, full_name, company_name, email, cell_phone, billing_address, last_updated
    FROM project_managers
    WHERE pm_id = $1
  `;

  const result = await db.query(query, [pmId]);
  return result.rows[0] as ProjectManager || null;
}

// ============================================
// Lead Operations
// ============================================

interface CreateLeadInput {
  lead_id: string;
  property_address: string;
  apartment_number?: string | null;
  job_type: string;
  claim_type: string | null;
  job_categories: string[];
  misc_description: string | null;
  pm_id: string | null;
  client_name: string;
  client_email: string | null;
  client_cell: string | null;
  final_billing_address: string;
  visit_requested: Date;
  access_instructions: string | null;
  lockbox_code?: string | null;
  gate_code?: string | null;
  scope_details: string | null;
  status: LeadStatus;
}

/**
 * Create a new lead submission
 */
export async function createLead(lead: CreateLeadInput): Promise<LeadSubmission> {
  const db = getPool();
  
  const query = `
    INSERT INTO lead_submissions (
      lead_id, property_address, apartment_number, job_type, claim_type, job_categories,
      misc_description, pm_id, client_name, client_email, client_cell,
      final_billing_address, visit_requested, access_instructions,
      lockbox_code, gate_code, scope_details, status, created_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, NOW())
    RETURNING *
  `;

  const values = [
    lead.lead_id,
    lead.property_address,
    lead.apartment_number || null,
    lead.job_type,
    lead.claim_type,
    JSON.stringify(lead.job_categories),
    lead.misc_description,
    lead.pm_id,
    lead.client_name,
    lead.client_email,
    lead.client_cell,
    lead.final_billing_address,
    lead.visit_requested,
    lead.access_instructions,
    lead.lockbox_code || null,
    lead.gate_code || null,
    lead.scope_details,
    lead.status,
  ];

  const result = await db.query(query, values);
  return result.rows[0] as LeadSubmission;
}

/**
 * Update lead with workflow IDs (Drive folder, Calendar event)
 */
export async function updateLeadWithWorkflow(
  leadId: string,
  updates: {
    drive_folder_id?: string;
    calendar_event_id?: string;
    status?: LeadStatus;
  }
): Promise<void> {
  const db = getPool();
  
  const setClauses: string[] = [];
  const values: (string | undefined)[] = [];
  let paramIndex = 1;

  if (updates.drive_folder_id !== undefined) {
    setClauses.push(`drive_folder_id = $${paramIndex++}`);
    values.push(updates.drive_folder_id);
  }

  if (updates.calendar_event_id !== undefined) {
    setClauses.push(`calendar_event_id = $${paramIndex++}`);
    values.push(updates.calendar_event_id);
  }

  if (updates.status !== undefined) {
    setClauses.push(`status = $${paramIndex++}`);
    values.push(updates.status);
  }

  if (setClauses.length === 0) return;

  values.push(leadId);
  const query = `
    UPDATE lead_submissions
    SET ${setClauses.join(', ')}
    WHERE lead_id = $${paramIndex}
  `;

  await db.query(query, values);
}

/**
 * Get lead by ID
 */
export async function getLeadById(leadId: string): Promise<LeadSubmission | null> {
  const db = getPool();
  
  const query = `
    SELECT *
    FROM lead_submissions
    WHERE lead_id = $1
  `;

  const result = await db.query(query, [leadId]);
  return result.rows[0] as LeadSubmission || null;
}

/**
 * Update lead status
 */
export async function updateLeadStatus(leadId: string, status: LeadStatus): Promise<void> {
  const db = getPool();
  
  const query = `
    UPDATE lead_submissions
    SET status = $1
    WHERE lead_id = $2
  `;

  await db.query(query, [status, leadId]);
}

// ============================================
// Database Schema Setup
// ============================================

/**
 * Create tables if they don't exist
 * Run this during initial deployment
 */
export async function initializeSchema(): Promise<void> {
  const db = getPool();

  // Create project_managers table
  await db.query(`
    CREATE TABLE IF NOT EXISTS project_managers (
      pm_id UUID PRIMARY KEY,
      full_name TEXT NOT NULL,
      company_name TEXT NOT NULL,
      email TEXT UNIQUE NOT NULL,
      cell_phone TEXT,
      billing_address TEXT,
      last_updated TIMESTAMP DEFAULT NOW()
    )
  `);

  // Create index on full_name for search
  await db.query(`
    CREATE INDEX IF NOT EXISTS idx_pm_full_name ON project_managers (full_name)
  `);

  // Create lead_submissions table
  await db.query(`
    CREATE TABLE IF NOT EXISTS lead_submissions (
      lead_id UUID PRIMARY KEY,
      property_address TEXT NOT NULL,
      apartment_number TEXT,
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
      lockbox_code TEXT,
      gate_code TEXT,
      scope_details TEXT,
      drive_folder_id TEXT,
      calendar_event_id TEXT,
      status TEXT NOT NULL DEFAULT 'new',
      created_at TIMESTAMP DEFAULT NOW()
    )
  `);

  // Create indexes
  await db.query(`
    CREATE INDEX IF NOT EXISTS idx_lead_status ON lead_submissions (status)
  `);
  await db.query(`
    CREATE INDEX IF NOT EXISTS idx_lead_created ON lead_submissions (created_at)
  `);

  console.log('Database schema initialized');
}

/**
 * Close the connection pool
 */
export async function closePool(): Promise<void> {
  if (pool) {
    await pool.end();
    pool = null;
  }
}
