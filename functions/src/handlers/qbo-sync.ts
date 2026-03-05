/**
 * QBO Sync Handlers
 * Orchestrates QBO operations triggered by Firestore and Calendar events
 */

import * as admin from 'firebase-admin';
import { google } from 'googleapis';
import { config } from '../config';
import {
  findOrCreateCustomer,
  findOrCreateProject,
  createEstimate,
  getEstimate,
  updateEstimateTechnician,
} from '../services/quickbooks';

// ============================================
// Trigger A: Lead → QBO Sync
// ============================================

/**
 * Handle a new lead document — create QBO Customer, Project, and Estimate
 *
 * Called by the onDocumentCreated('leads/{leadId}') Firestore trigger.
 * Writes qbo_project_id, qbo_estimate_id, and po_number back to the lead doc.
 */
export async function handleLeadToQbo(
  leadId: string,
  leadData: FirebaseFirestore.DocumentData
): Promise<void> {
  console.log(`[QBO Sync] Processing lead ${leadId}...`);

  const clientName = leadData.client_name as string;
  const clientPhone = leadData.client_cell as string | null;
  const clientEmail = leadData.client_email as string | null;
  const propertyAddress = leadData.property_address as string;
  const jobCategories = leadData.job_categories as string[];
  const claimType = leadData.claim_type as string | null;
  const pmName = leadData.pm_full_name as string | null;
  const scopeDetails = leadData.scope_details as string | null;
  const poNumber = leadData.po_number as string | null;

  try {
    // Step 1: Find or create Customer
    console.log(`[QBO Sync] Step 1: Find/create customer "${clientName}"`);
    const customer = await findOrCreateCustomer(
      clientName,
      clientPhone,
      clientEmail
    );

    // Step 2: Find or create Project: "[Property Address] - [Client Name]"
    const projectName = `${propertyAddress} - ${clientName}`;
    console.log(`[QBO Sync] Step 2: Find/create project "${projectName}"`);
    const project = await findOrCreateProject(customer.Id, projectName);

    // Step 3: Create Estimate linked to the project
    console.log('[QBO Sync] Step 3: Creating estimate...');
    const estimate = await createEstimate({
      projectId: project.Id,
      customerRef: project.Id, // Project (sub-customer) is the CustomerRef
      poNumber,
      scopeDetails,
      jobCategories,
      claimType,
      pmName,
      propertyAddress,
    });

    // Step 4: Write QBO IDs back to Firestore lead doc
    console.log('[QBO Sync] Step 4: Updating Firestore lead doc with QBO IDs');
    await admin.firestore().collection('leads').doc(leadId).update({
      qbo_customer_id: customer.Id,
      qbo_project_id: project.Id,
      qbo_estimate_id: estimate.Id,
      qbo_estimate_sync_token: estimate.SyncToken,
      qbo_doc_number: estimate.DocNumber,
      qbo_synced_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    console.log(
      `[QBO Sync] ✅ Lead ${leadId} synced to QBO — Estimate #${estimate.DocNumber}`
    );
  } catch (error: any) {
    console.error(`[QBO Sync] ❌ Failed to sync lead ${leadId}:`, error);

    // Record the error in Firestore so it can be retried / investigated
    await admin
      .firestore()
      .collection('leads')
      .doc(leadId)
      .update({
        qbo_sync_error: error?.message || 'Unknown error',
        qbo_sync_attempted_at: admin.firestore.FieldValue.serverTimestamp(),
      })
      .catch((updateErr) =>
        console.error('[QBO Sync] Failed to record error:', updateErr)
      );

    throw error; // Re-throw to mark the function invocation as failed
  }
}

// ============================================
// Trigger B: Calendar → QBO Technician Sync
// ============================================

// User to impersonate for domain-wide delegation (same as calendar.ts)
const IMPERSONATE_USER = 'admin@immediateresponsehvac.ca';

/**
 * Get an authenticated Google Calendar client
 */
async function getCalendarClient() {
  const auth = new google.auth.GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/calendar.readonly'],
  });

  const client = await auth.getClient();
  if ('subject' in client) {
    (client as any).subject = IMPERSONATE_USER;
  }

  return google.calendar({ version: 'v3', auth: client as any });
}

/**
 * Sync technician assignments from Google Calendar to QBO Estimates
 *
 * Called by the scheduled function (every 5 minutes).
 *
 * Logic:
 * 1. List events updated in the last 10 minutes on the Ghost calendar
 * 2. For each event with attendees, find the matching Firestore lead doc
 * 3. Detect new attendees that aren't the client or PM (→ technician)
 * 4. Sparse-update the QBO Estimate's "Technician" custom field
 */
export async function handleCalendarTechSync(): Promise<{
  processed: number;
  updated: number;
  errors: number;
}> {
  console.log('[Tech Sync] Starting calendar technician sync...');

  const calendar = await getCalendarClient();
  const calendarId = config.calendar.ghostCalendarId;

  // Look back 10 minutes for recently modified events
  const updatedMin = new Date(Date.now() - 10 * 60 * 1000).toISOString();

  const response = await calendar.events.list({
    calendarId,
    updatedMin,
    singleEvents: false,
    showDeleted: false,
    maxResults: 50,
  });

  const events = response.data.items || [];
  console.log(
    `[Tech Sync] Found ${events.length} events updated since ${updatedMin}`
  );

  let processed = 0;
  let updated = 0;
  let errors = 0;

  for (const event of events) {
    processed++;
    try {
      if (!event.id || !event.attendees || event.attendees.length === 0) {
        continue;
      }

      // Find the Firestore lead doc that references this calendar event
      const leadsSnapshot = await admin
        .firestore()
        .collection('leads')
        .where('calendar_event_id', '==', event.id)
        .limit(1)
        .get();

      if (leadsSnapshot.empty) {
        continue; // No matching lead for this event
      }

      const leadDoc = leadsSnapshot.docs[0];
      const leadData = leadDoc.data();

      // Skip if already has a technician assigned
      if (leadData.technician) {
        continue;
      }

      // Skip if no QBO estimate to update
      if (!leadData.qbo_estimate_id) {
        continue;
      }

      // Determine which attendees are technicians
      // Exclude the client email and PM email
      const clientEmail = (leadData.client_email || '').toLowerCase();
      const pmEmail = (leadData.pm_email || '').toLowerCase();

      const techAttendees = event.attendees.filter((attendee) => {
        const email = (attendee.email || '').toLowerCase();
        return (
          email &&
          email !== clientEmail &&
          email !== pmEmail &&
          !email.includes('calendar.google.com') && // Skip calendar resource
          attendee.responseStatus !== 'declined'
        );
      });

      if (techAttendees.length === 0) {
        continue;
      }

      // Use the first non-client/PM attendee as the technician
      const tech = techAttendees[0];
      const techName =
        tech.displayName || tech.email?.split('@')[0] || 'Unknown';

      console.log(
        `[Tech Sync] Assigning tech "${techName}" to lead ${leadDoc.id}`
      );

      // Get current SyncToken (may have changed since creation)
      let syncToken = leadData.qbo_estimate_sync_token;
      if (!syncToken) {
        const estimate = await getEstimate(leadData.qbo_estimate_id);
        syncToken = estimate.SyncToken;
      }

      // Update QBO Estimate
      await updateEstimateTechnician(
        leadData.qbo_estimate_id,
        syncToken,
        techName
      );

      // Update Firestore lead doc
      await leadDoc.ref.update({
        technician: techName,
        technician_email: tech.email,
        technician_assigned_at: admin.firestore.FieldValue.serverTimestamp(),
      });

      updated++;
      console.log(
        `[Tech Sync] ✅ Updated lead ${leadDoc.id} with tech "${techName}"`
      );
    } catch (error: any) {
      errors++;
      console.error(
        `[Tech Sync] ❌ Error processing event ${event.id}:`,
        error?.message
      );
    }
  }

  console.log(
    `[Tech Sync] Complete: ${processed} processed, ${updated} updated, ${errors} errors`
  );
  return { processed, updated, errors };
}
