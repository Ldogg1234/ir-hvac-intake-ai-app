/**
 * TypeScript Types for HVAC Intake System
 */

// ============================================
// Enums
// ============================================

export type JobType = 'Residential' | 'Commercial' | 'Res_Insurance' | 'Comm_Insurance';
export type ClaimType = 'Flood' | 'Fire' | 'Abatement' | 'Other';
export type LeadStatus = 'not-scheduled' | 'scheduled' | 'waiting-for-report' | 'report-sent' | 'to-be-invoiced' | 'invoiced' | 'paid' | 'quote-to-be-sent' | 'quoted' | 'in-progress' | 'report-submitted';
export type AccessInstruction = 'Contact PM' | 'Contact Client' | 'Crew on site - Reg hrs' | 'Crew on site - 24 hrs' | 'Lockbox';
export type VisitStatus = 'To Be Scheduled' | 'Confirmed date' | 'Quote Only (No Visit)';

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
  assistant_emails?: string;
  billing_emails?: string;
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
  assistant_emails?: string | null;
  billing_emails?: string | null;
  visit_requested: Date;
  access_instructions: AccessInstruction | null;
  lockbox_code: string | null;
  gate_code: string | null;
  scope_details: string | null;
  drive_folder_id: string | null;
  calendar_event_id: string | null;
  status: LeadStatus;
  created_at: Date;
  emergency_dispatch?: boolean;
  appliance_count?: string | null;
  appliance_list?: string | null;
  equipment_type?: string | null;
  fuel_type?: string | null;
  is_call_back?: boolean;
  additional_work?: boolean;
  quoted_amount?: number | null;
  job_duration?: number;
  include_weekends?: boolean;
  is_bid_or_tender?: boolean;
  bid_due_date?: string | null;
  last_report_sent_at?: any;
  is_ongoing?: boolean;
}

// ============================================
// API Request/Response Types
// ============================================

export interface PMInput {
  pm_id?: string | null;
  full_name: string;
  company_name?: string | null;
  email?: string | null;
  cell_phone?: string | null;
  billing_address?: string | null;
  assistant_emails?: string | null;
  billing_emails?: string | null;
}

export interface FileAttachment {
  name: string;
  data: string; // Base64 encoded content
  mime_type: string;
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
  visit_end?: string | null; // ISO date string for confirmed appointments
  visit_status?: VisitStatus | null; // 'To Be Scheduled' (yellow, 6am) or 'Confirmed date' (green, exact time)
  access_instructions?: AccessInstruction | null;
  lockbox_code?: string | null;
  gate_code?: string | null;
  emergency_dispatch?: boolean;
  appliance_count?: string | null;
  appliance_list?: string | null;
  equipment_type?: string | null;
  fuel_type?: string | null;
  update_pm?: boolean;
  distance_metres?: number;
  td4_required?: boolean;
  is_call_back?: boolean;
  additional_work?: boolean;
  quoted_amount?: number | null;
  job_duration?: number;
  include_weekends?: boolean;
  submitted_by?: string;
  is_bid_or_tender?: boolean;
  bid_due_date?: string | null;
  qbo_line_items?: Array<{
    Description: string;
    Qty: number;
    UnitPrice: number;
    Amount: number;
  }> | null;
  has_actionable_quote_details?: boolean | null;
  work_requested?: string | null;
  supporting_docs?: FileAttachment[];
  automated_email?: boolean | null;
  calendar_event?: boolean | null;
  automated_qbo?: boolean | null;
}

export interface IntakeResponse {
  success: boolean;
  lead_id: string;
  drive_folder_url: string;
  calendar_event_url: string;
  purchase_orders_folder_id?: string;
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
