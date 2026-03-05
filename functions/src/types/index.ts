/**
 * TypeScript Types for HVAC Intake System
 */

// ============================================
// Enums
// ============================================

export type JobType = 'Residential' | 'Commercial' | 'Res_Insurance' | 'Comm_Insurance';
export type ClaimType = 'Flood' | 'Fire' | 'Abatement' | 'Other';
export type LeadStatus = 'new' | 'scheduled' | 'in_progress' | 'completed' | 'cancelled';
export type AccessInstruction = 'Contact PM' | 'Contact Client' | 'Crew on site - Reg hrs' | 'Crew on site - 24 hrs' | 'Lockbox';
export type VisitStatus = 'To Be Scheduled' | 'Confirmed date';

// ============================================
// Database Models
// ============================================

export interface ProjectManager {
  pm_id: string;
  full_name: string;
  company_name: string;
  email: string;
  cell_phone: string;
  billing_address: string;
  last_updated: Date;
}

export interface LeadSubmission {
  lead_id: string;
  property_address: string;
  apartment_number: string | null;
  job_type: JobType;
  claim_type: ClaimType | null;
  job_categories: string[];
  misc_description: string | null;
  pm_id: string | null;
  client_name: string;
  client_email: string | null;
  client_cell: string | null;
  final_billing_address: string;
  visit_requested: Date;
  access_instructions: AccessInstruction | null;
  lockbox_code: string | null;
  gate_code: string | null;
  scope_details: string | null;
  drive_folder_id: string | null;
  calendar_event_id: string | null;
  status: LeadStatus;
  created_at: Date;
}

// ============================================
// API Request/Response Types
// ============================================

export interface PMInput {
  full_name: string;
  company_name?: string | null;
  email?: string | null;
  cell_phone?: string | null;
  billing_address?: string | null;
}

export interface IntakeRequest {
  property_address: string;
  apartment_number?: string | null;
  job_type: JobType;
  claim_type?: ClaimType | null;
  job_categories: string[];
  misc_description?: string | null;
  pm?: PMInput | null;
  client_name: string;
  client_email?: string | null;
  client_cell?: string | null;
  scope_details?: string | null;
  po_number?: string | null;
  visit_requested: string; // ISO date string
  visit_status?: VisitStatus | null; // 'To Be Scheduled' (yellow, 6am) or 'Confirmed date' (green, exact time)
  access_instructions?: AccessInstruction | null;
  lockbox_code?: string | null;
  gate_code?: string | null;
}

export interface IntakeResponse {
  success: boolean;
  lead_id: string;
  drive_folder_url: string;
  calendar_event_url: string;
  message?: string;
}

export interface PMSearchResponse {
  results: ProjectManager[];
}

export interface ErrorResponse {
  success: false;
  error: string;
  code?: string;
}

// ============================================
// Service Types
// ============================================

export interface DriveFolder {
  folderId: string;
  folderUrl: string;
  inspectionPhotosFolderId: string;
  postJobPhotosFolderId: string;
  videosFolderId: string;
  reportsFolderId: string;
  meterReadingsFolderId: string;
  clockInUrl: string;
}

export interface CalendarEvent {
  eventId: string;
  eventUrl: string;
  htmlLink: string;
}

// ============================================
// Workflow Context
// ============================================

export interface IntakeWorkflowContext {
  request: IntakeRequest;
  pmId: string | null;
  leadId: string;
  driveFolder: DriveFolder | null;
  calendarEvent: CalendarEvent | null;
}
