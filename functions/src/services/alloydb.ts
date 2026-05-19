/**
 * Legacy AlloyDB Service (Placeholder)
 * This file is being decommissioned in favor of Firestore.
 * This placeholder is kept to avoid breaking imports during migration.
 */

import { ProjectManager, LeadSubmission, PMInput, LeadStatus } from '../types';

/**
 * @deprecated Use Firestore instead.
 */
export async function upsertProjectManager(pm: PMInput): Promise<ProjectManager> {
  console.error('ALOYDB_DEPRECATED: upsertProjectManager called. Use Firestore instead.');
  throw new Error('AlloyDB is no longer supported. Use Firestore services.');
}

/**
 * @deprecated Use Firestore instead.
 */
export async function searchPMByName(searchQuery: string): Promise<ProjectManager[]> {
  console.error('ALOYDB_DEPRECATED: searchPMByName called. Use Firestore instead.');
  return [];
}

/**
 * @deprecated Use Firestore instead.
 */
export async function getPMByEmail(email: string): Promise<ProjectManager | null> {
  console.error('ALOYDB_DEPRECATED: getPMByEmail called. Use Firestore instead.');
  return null;
}

/**
 * @deprecated Use Firestore instead.
 */
export async function getPMById(pmId: string): Promise<ProjectManager | null> {
  console.error('ALOYDB_DEPRECATED: getPMById called. Use Firestore instead.');
  return null;
}

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
 * @deprecated Use Firestore instead.
 */
export async function createLead(lead: CreateLeadInput): Promise<LeadSubmission> {
  console.error('ALOYDB_DEPRECATED: createLead called. Use Firestore instead.');
  throw new Error('AlloyDB is no longer supported. Use Firestore services.');
}

/**
 * @deprecated Use Firestore instead.
 */
export async function updateLeadWithWorkflow(
  leadId: string,
  updates: {
    drive_folder_id?: string;
    calendar_event_id?: string;
    status?: LeadStatus;
  }
): Promise<void> {
  console.error('ALOYDB_DEPRECATED: updateLeadWithWorkflow called. Use Firestore instead.');
}

/**
 * @deprecated Use Firestore instead.
 */
export async function getLeadById(leadId: string): Promise<LeadSubmission | null> {
  console.error('ALOYDB_DEPRECATED: getLeadById called. Use Firestore instead.');
  return null;
}

/**
 * @deprecated Use Firestore instead.
 */
export async function updateLeadStatus(leadId: string, status: LeadStatus): Promise<void> {
  console.error('ALOYDB_DEPRECATED: updateLeadStatus called. Use Firestore instead.');
}

/**
 * @deprecated Use Firestore instead.
 */
export async function initializeSchema(): Promise<void> {
  console.log('AlloyDB schema initialization bypassed (Decommissioned)');
}

/**
 * @deprecated No-op.
 */
export async function closePool(): Promise<void> {
  // No-op
}
