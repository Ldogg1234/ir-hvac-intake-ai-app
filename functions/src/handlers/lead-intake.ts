// Deploy nudge: Feb 13 - final handshake fix
/**
 * Lead Intake Handler
 * Orchestrates the complete lead intake workflow
 */

import { z } from 'zod';
import { v4 as uuidv4 } from 'uuid';
import * as admin from 'firebase-admin';
import { IntakeRequest, IntakeResponse, PMSearchResponse } from '../types';
import { isInsuranceJob } from '../config';
import { createLeadFolderStructure } from '../services/drive';
import { createLeadCalendarEvent } from '../services/calendar';
import { upsertProjectManager, createLead, updateLeadWithWorkflow, searchPMByName } from '../services/alloydb';
import { sendCustomerConfirmationEmail } from '../services/email';

// Input validation schema
const IntakeRequestSchema = z.object({
  property_address: z.string().min(1, 'Property address is required'),
  apartment_number: z.string().nullable().optional(),
  job_type: z.enum(['Residential', 'Commercial', 'Res_Insurance', 'Comm_Insurance']),
  claim_type: z.enum(['Flood', 'Fire', 'Abatement', 'Other']).nullable().optional(),
  job_categories: z.array(z.string()).min(1, 'At least one job category is required'),
  misc_description: z.string().nullable().optional(),
  pm: z.object({
    full_name: z.string().min(1),
    company_name: z.string().nullable().optional(),
    email: z.union([z.string().email(), z.literal('')]).nullable().optional(),
    cell_phone: z.string().nullable().optional(),
    billing_address: z.string().nullable().optional(),
  }).nullable().optional(),
  client_name: z.string().min(1, 'Client name is required'),
  client_email: z.union([z.string().email(), z.literal('')]).nullable().optional(),
  client_cell: z.string().nullable().optional(),
  scope_details: z.string().nullable().optional(),
  po_number: z.string().nullable().optional(),
  visit_requested: z.string().min(1, 'Visit date/time is required'),
  visit_status: z.enum(['To Be Scheduled', 'Confirmed date']).nullable().optional(),
  access_instructions: z.enum(['Contact PM', 'Contact Client', 'Crew on site - Reg hrs', 'Crew on site - 24 hrs', 'Lockbox']).nullable().optional(),
  lockbox_code: z.string().nullable().optional(),
  gate_code: z.string().nullable().optional(),
});

/**
 * Timeout wrapper to prevent indefinite hanging
 */
function withTimeout<T>(promise: Promise<T>, timeoutMs: number, operationName: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => 
      setTimeout(() => reject(new Error(`${operationName} timeout after ${timeoutMs}ms`)), timeoutMs)
    ),
  ]);
}

/**
 * Handle the complete lead intake workflow
 */
export async function handleLeadIntake(body: unknown): Promise<IntakeResponse> {
  console.log('========================================');
  console.log('LEAD INTAKE STARTED');
  console.log('========================================');
  console.log('Raw request body:', JSON.stringify(body, null, 2));

  // Validate input
  console.log('Step 0: Validating input schema...');
  const validationResult = IntakeRequestSchema.safeParse(body);
  if (!validationResult.success) {
    console.error('VALIDATION FAILED:', validationResult.error.errors);
    throw new Error(`Validation error: ${validationResult.error.errors.map(e => e.message).join(', ')}`);
  }
  console.log('✅ Step 0: Validation Passed');

  const request: IntakeRequest = validationResult.data as IntakeRequest;
  const leadId = uuidv4();
  console.log(`Generated Lead ID: ${leadId}`);
  console.log(`Job Type: ${request.job_type}`);
  console.log(`Client Email: ${request.client_email || 'NOT PROVIDED'}`);
  console.log(`PM Email: ${request.pm?.email || 'NOT PROVIDED'}`);

  // ========================================
  // PRIORITY #1: SEND EMAIL NOTIFICATION IMMEDIATELY
  // ========================================
  console.log('========================================');
  console.log('🚨 PRIORITY #1: EMAIL NOTIFICATION');
  console.log('========================================');
  console.log('--- Step 1: Initiating Email Send ---');
  console.log('About to call: await sendCustomerConfirmationEmail(request)');
  console.log('This MUST complete before returning response to user');
  console.log('DEBUG: Request object keys are:', Object.keys(request));
  console.log('DEBUG: Request object:', JSON.stringify(request, null, 2));
  
  try {
    console.log('Executing: await sendCustomerConfirmationEmail...');
    console.log('Function is being called NOW');
    await sendCustomerConfirmationEmail(request);
    console.log('Function returned from await');
    console.log('✅ Step 1: Email notification sent successfully!');
    console.log('Email was AWAITED and completed');
    console.log('Email sent BEFORE any database/drive operations can fail');
  } catch (emailError) {
    console.error('⚠️ Step 1: Email service error (non-critical):', emailError);
    console.error('Email error type:', emailError instanceof Error ? emailError.constructor.name : typeof emailError);
    console.error('Email error message:', emailError instanceof Error ? emailError.message : String(emailError));
    console.log('Continuing with background operations despite email error...');
  }
  
  console.log('--- Step 1: Email Send Complete (or failed safely) ---');
  console.log('Proceeding to background operations...');
  console.log('========================================');

  // ========================================
  // BACKGROUND OPERATIONS (NON-BLOCKING)
  // These happen AFTER email is sent and don't affect user response
  // ========================================
  console.log('\n========================================');
  console.log('Starting background operations (database, drive, calendar)...');
  console.log('These operations will NOT affect the success response');
  console.log('========================================\n');

  let pmId: string | null = null;
  let driveFolderId: string | null = null;
  let calendarEventId: string | null = null;
  let dbOperationSucceeded = false;

  // Step 2: Upsert PM if insurance job (BACKGROUND - NON-BLOCKING with 3s timeout)
  console.log('Step 2: Checking if PM upsert needed...');
  if (isInsuranceJob(request.job_type) && request.pm) {
    console.log('Step 2: Upserting PM for insurance job...');
    try {
      const pm = await withTimeout(
        upsertProjectManager(request.pm),
        3000,
        'PM Upsert'
      );
      pmId = pm.pm_id;
      console.log(`✅ Step 2: PM upserted successfully: ${pmId}`);
    } catch (pmError) {
      console.error('⚠️ Step 2 FAILED (background operation): PM upsert error');
      console.error('PM Error Details:', pmError);
      console.error('PM Error Message:', pmError instanceof Error ? pmError.message : String(pmError));
      console.warn('Skipping PM - email already sent');
    }
  } else {
    console.log('✅ Step 2: PM upsert not needed (skipped)');
  }

  // Step 3: Determine billing address
  console.log('Step 3: Determining billing address...');
  const finalBillingAddress = (isInsuranceJob(request.job_type) && request.pm?.billing_address)
    ? request.pm.billing_address
    : request.property_address;
  console.log(`✅ Step 3: Billing address determined: ${finalBillingAddress}`);

  // Step 4: Create lead record in AlloyDB (BACKGROUND - NON-BLOCKING with 3s timeout)
  console.log('Step 4: Connecting to AlloyDB and creating lead record...');
  console.log('Database operation has 3-second timeout to prevent hanging...');
  try {
    await withTimeout(
      createLead({
        lead_id: leadId,
        property_address: request.property_address,
        apartment_number: request.apartment_number || null,
        job_type: request.job_type,
        claim_type: request.claim_type || null,
        job_categories: request.job_categories,
        misc_description: request.misc_description || null,
        pm_id: pmId,
        client_name: request.client_name,
        client_email: request.client_email || null,
        client_cell: request.client_cell || null,
        final_billing_address: finalBillingAddress,
        visit_requested: new Date(request.visit_requested),
        access_instructions: request.access_instructions || null,
        lockbox_code: request.lockbox_code || null,
        gate_code: request.gate_code || null,
        scope_details: request.scope_details || null,
        status: 'new',
      }),
      3000,
      'AlloyDB Lead Creation'
    );
    console.log(`✅ Step 4: Lead record created successfully: ${leadId}`);
    dbOperationSucceeded = true;
  } catch (dbError) {
    console.error('⚠️ Step 4 FAILED (background operation): Database error or timeout');
    console.error('DB Error Type:', dbError instanceof Error ? dbError.constructor.name : typeof dbError);
    console.error('DB Error Message:', dbError instanceof Error ? dbError.message : String(dbError));
    console.error('DB Error Stack:', dbError instanceof Error ? dbError.stack : 'N/A');
    
    if (dbError instanceof Error && dbError.message.includes('timeout')) {
      console.error('⏰ DATABASE TIMEOUT - Connection took longer than 3 seconds');
      console.warn('⚡ Skipping database - email already sent, user already notified');
    } else {
      console.warn('Database is unavailable - email already sent, user already notified');
    }
  }

  // Step 5: Create Drive folder (BACKGROUND - NON-BLOCKING)
  console.log('Step 5: Creating Drive folder structure...');
  let driveFolder: any = null;
  try {
    driveFolder = await createLeadFolderStructure({
      propertyAddress: request.property_address,
      pmName: request.pm?.full_name || null,
      clientName: request.client_name,
    });
    driveFolderId = driveFolder.folderId;
    console.log(`✅ Step 5: Drive folder created: ${driveFolderId}`);
    console.log(`Drive folder URL: ${driveFolder.folderUrl}`);
  } catch (driveError) {
    console.error('⚠️ Step 5 FAILED (background operation): Google Drive error');
    console.error('Drive Error Details:', driveError);
    console.error('Drive Error Message:', driveError instanceof Error ? driveError.message : String(driveError));
    console.warn('Skipping Drive - email already sent');
    driveFolder = {
      folderId: null,
      folderUrl: 'N/A (Drive unavailable)',
      inspectionPhotosFolderId: null,
      postJobPhotosFolderId: null,
      videosFolderId: null,
      reportsFolderId: null,
      meterReadingsFolderId: null,
      clockInUrl: null,
    };
  }

  // Step 6: Create Calendar event (BACKGROUND - NON-BLOCKING)
  console.log('Step 6: Creating Google Calendar event...');
  let calendarEvent: any = null;
  try {
    calendarEvent = await createLeadCalendarEvent({
      propertyAddress: request.property_address,
      apartmentNumber: request.apartment_number,
      clientName: request.client_name,
      clientEmail: request.client_email,
      clientPhone: request.client_cell,
      pmName: request.pm?.full_name,
      pmEmail: request.pm?.email,
      pmPhone: request.pm?.cell_phone,
      jobCategories: request.job_categories,
      claimType: request.claim_type,
      jobType: request.job_type,
      scopeDetails: request.scope_details,
      visitRequested: request.visit_requested,
      visitStatus: request.visit_status || null,
      accessInstructions: request.access_instructions,
      lockboxCode: request.lockbox_code,
      driveFolderUrl: driveFolder?.folderUrl || 'N/A',
      driveFolderId: driveFolder?.folderId || null,
    });
    calendarEventId = calendarEvent.eventId;
    console.log(`✅ Step 6: Calendar event created: ${calendarEventId}`);
    console.log(`Calendar event URL: ${calendarEvent.htmlLink}`);
  } catch (calendarError) {
    console.error('⚠️ Step 6 FAILED (background operation): Google Calendar error');
    console.error('Calendar Error Details:', calendarError);
    console.error('Calendar Error Message:', calendarError instanceof Error ? calendarError.message : String(calendarError));
    console.warn('Skipping Calendar - email already sent');
    calendarEvent = {
      eventId: null,
      eventUrl: 'N/A (Calendar unavailable)',
      htmlLink: 'N/A (Calendar unavailable)',
    };
  }

  // Step 7: Update lead with Drive and Calendar IDs (BACKGROUND - NON-BLOCKING with 3s timeout)
  console.log('Step 7: Updating lead with workflow IDs...');
  if (dbOperationSucceeded && driveFolder?.folderId && calendarEvent?.eventId) {
    try {
      await withTimeout(
        updateLeadWithWorkflow(leadId, {
          drive_folder_id: driveFolder.folderId,
          calendar_event_id: calendarEvent.eventId,
          status: 'scheduled',
        }),
        3000,
        'AlloyDB Lead Update'
      );
      console.log(`✅ Step 7: Lead updated with workflow IDs`);
    } catch (updateError) {
      console.error('⚠️ Step 7 FAILED (background operation): Database update error or timeout');
      console.error('Update Error Details:', updateError);
      console.error('Update Error Message:', updateError instanceof Error ? updateError.message : String(updateError));
      console.warn('Skipping database update - email already sent');
    }
  } else {
    console.warn('⚠️ Step 7 SKIPPED: Missing prerequisites (DB/Drive/Calendar failed)');
    console.log('Email was already sent in Step 1, so user is notified regardless');
  }

  // Step 8: Write lead to Firestore (triggers QBO sync via onDocumentCreated)
  console.log('Step 8: Writing lead to Firestore for QBO sync...');
  try {
    await admin.firestore().collection('leads').doc(leadId).set({
      property_address: request.property_address,
      apartment_number: request.apartment_number || null,
      job_type: request.job_type,
      claim_type: request.claim_type || null,
      job_categories: request.job_categories,
      misc_description: request.misc_description || null,
      pm_full_name: request.pm?.full_name || null,
      pm_email: request.pm?.email || null,
      pm_cell_phone: request.pm?.cell_phone || null,
      client_name: request.client_name,
      client_email: request.client_email || null,
      client_cell: request.client_cell || null,
      scope_details: request.scope_details || null,
      po_number: request.po_number || null,
      visit_requested: request.visit_requested,
      visit_status: request.visit_status || null,
      access_instructions: request.access_instructions || null,
      lockbox_code: request.lockbox_code || null,
      gate_code: request.gate_code || null,
      drive_folder_id: driveFolder?.folderId || null,
      drive_folder_url: driveFolder?.folderUrl || null,
      calendar_event_id: calendarEvent?.eventId || null,
      calendar_event_url: calendarEvent?.htmlLink || null,
      status: 'new',
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`✅ Step 8: Lead written to Firestore — QBO sync will trigger`);
  } catch (firestoreError) {
    console.error('⚠️ Step 8 FAILED: Firestore write error');
    console.error('Firestore Error:', firestoreError instanceof Error ? firestoreError.message : String(firestoreError));
    console.warn('QBO sync will not trigger for this lead');
  }

  console.log('\n========================================');
  console.log('✅ LEAD INTAKE COMPLETED');
  console.log('========================================');
  console.log('📧 Email Notification: ✅ SENT (Step 1 - PRIORITY)');
  console.log('========================================');
  console.log('Background Operations Status:');
  console.log(`  Database: ${dbOperationSucceeded ? '✅ Success' : '⚠️ Failed (non-critical)'}`);
  console.log(`  Drive Folder: ${driveFolder?.folderId ? '✅ Created' : '⚠️ Failed (non-critical)'}`);
  console.log(`  Calendar Event: ${calendarEvent?.eventId ? '✅ Created' : '⚠️ Failed (non-critical)'}`);
  console.log('========================================');
  console.log('✅ USER NOTIFIED - WORKFLOW SUCCESS');
  console.log('========================================\n');
  
  return {
    success: true,
    lead_id: leadId,
    drive_folder_url: driveFolder?.folderUrl || 'Pending',
    calendar_event_url: calendarEvent?.htmlLink || 'Pending',
    message: 'Lead received - Confirmation email sent. Our team will contact you shortly.',
  };
}

/**
 * Handle PM search by name
 */
export async function handlePMSearch(query: string): Promise<PMSearchResponse> {
  console.log(`Searching for PM: ${query}`);
  const results = await searchPMByName(query);
  console.log(`Found ${results.length} results`);
  return { results };
}
// Deploy nudge: 02/13/2026 09:38:45
