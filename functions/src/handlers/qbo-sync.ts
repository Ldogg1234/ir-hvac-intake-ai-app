/**
 * QBO Sync Handlers
 * Orchestrates QBO operations triggered by Firestore and Calendar events
 */

import * as admin from 'firebase-admin';
import { config } from '../config';
import {
  findOrCreateCustomer,
  findOrCreateProject,
  createEstimate,
  getEstimate,
  updateEstimateTechnician,
  updateCustomer,
  updateProject,
  updateEstimateAddress,
  updateEstimate,
  formatProjectName,
  getEstimatePdfBuffer,
  sanitizeEmail,
  truncateDescription,
  truncateCustomField,
  calculateInspectionPrice,
} from '../services/quickbooks';
import { sendEstimateReviewEmail } from '../services/email';
import { getCalendarClient, updateCalendarEvent } from '../services/calendar';
import {
  uploadFileToFolder,
} from '../services/drive';
import { logError } from '../utils/logger';

// ============================================
// Trigger A: Lead → QBO Sync
// ============================================

/**
 * Helper to strip HTML tags and extract raw email addresses.
 * QBO rejects emails with HTML formatting (e.g. <a href="...">email</a>)
 */
function sanitizeEmailsForQBO(emailStr: string | null | undefined): string | null {
  if (!emailStr) return null;
  if (emailStr.trim().toUpperCase() === 'N/A') return null;
  const matches = emailStr.match(/([a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+\.[a-zA-Z0-9._-]+)/gi);
  if (!matches) return null;
  return Array.from(new Set(matches)).join(', ');
}

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

  if (leadData.automated_qbo === false) {
    console.log(`[QBO Sync] Skipping QBO Sync for lead ${leadId} due to user toggle preference.`);
    return;
  }

  const clientName = (leadData.client_name as string) || 'Unknown Client';
  const clientPhone = (leadData.client_cell as string | null) || (leadData.client_phone as string | null);
  const clientEmail = sanitizeEmailsForQBO(leadData.client_email as string | null);
  const propertyAddress = (leadData.property_address as string) || 'No Address Provided';
  const billingAddress = leadData.final_billing_address as string | null;
  const jobCategories = (leadData.job_categories as string[]) || [];
  const applianceCountInput = leadData.appliance_count ? parseInt(String(leadData.appliance_count), 10) : null;
  const claimType = leadData.claim_type as string | null;
  const pmName = leadData.pm?.full_name as string | null;
  const pmCompany = leadData.pm?.company_name as string | null;
  const scopeDetails = leadData.scope_details as string | null;
  const poNumber = leadData.po_number as string | null;

  try {
    // Step 1: Find or create Customer
    let customer;
    const hasPM = !!(pmName);
    
    if (hasPM) {
      // For insurance jobs, the QBO Client (Parent Customer) is the Company Name + Billing Address
      const pmBilling = leadData.pm?.billing_address as string | null;
      let companyToUse = pmCompany || 'Unknown Company';
      if (pmBilling) {
        companyToUse = `${companyToUse} - ${pmBilling}`;
      }
      
      console.log(`[QBO Sync] Step 1: Find/create Insurance parent company "${companyToUse}"`);
      const pmPhone = leadData.pm?.cell_phone as string | null;
      const pmEmailMain = sanitizeEmailsForQBO(leadData.pm?.email as string | null);
      const pmBillingEmails = sanitizeEmailsForQBO(leadData.pm?.billing_emails as string | null);
      const pmAssistantEmails = sanitizeEmailsForQBO(leadData.pm?.assistant_emails as string | null);
      
      // Combine all emails into a comma-separated list for QBO and sanitize to max 100 chars
      const combinedEmails = sanitizeEmail([pmEmailMain, pmBillingEmails, pmAssistantEmails]
        .filter(e => e && e !== 'N/A' && e.trim() !== '')
        .join(', '));
      
      customer = await findOrCreateCustomer(
        companyToUse,
        pmPhone || null,
        combinedEmails || null,
        billingAddress || propertyAddress
      );
    } else {
      console.log(`[QBO Sync] Step 1: Find/create customer "${clientName}"`);
      customer = await findOrCreateCustomer(
        clientName,
        clientPhone,
        clientEmail,
        billingAddress || propertyAddress
      );
    }

    // Step 2: Find or create Project
    const additionalWork = leadData.additional_work === true;
    const isCallBack = leadData.is_call_back === true;
    const personToUse = hasPM && pmCompany ? pmCompany : clientName;
    const projectName = formatProjectName(propertyAddress, personToUse, jobCategories);
    console.log(`[QBO] Step 2: Find/create project "${projectName}" (Additional Work: ${additionalWork}, Call Back: ${isCallBack})`);
    
    // Pass additionalWork as forceNewProject flag to bypass fuzzy finding if it's additional work
    const projectPhone = hasPM ? (leadData.pm?.cell_phone as string | null) : clientPhone;
    const projectEmail = hasPM ? sanitizeEmailsForQBO(leadData.pm?.email as string | null) : clientEmail;
    
    // For call backs and additional work, we always want to find the existing project and NOT create a new one, so forceNewProject = false
    const project = await findOrCreateProject(
      customer.Id, 
      projectName, 
      propertyAddress, 
      false, // forceNewProject = false for both Call Backs and Additional Work
      projectPhone, 
      projectEmail,
      isCallBack || additionalWork
    );

    // Build combination email for the Estimate (PM email + Parent Email)
    let finalBillEmail = projectEmail;
    if (customer.PrimaryEmailAddr?.Address && customer.PrimaryEmailAddr.Address !== projectEmail) {
      if (finalBillEmail) {
        finalBillEmail = `${finalBillEmail}, ${customer.PrimaryEmailAddr.Address}`;
      } else {
        finalBillEmail = customer.PrimaryEmailAddr.Address;
      }
    }

    // Add PM billing_emails if present
    const billingEmails = sanitizeEmailsForQBO(leadData.pm?.billing_emails as string | null);
    if (billingEmails) {
      const bEmails = billingEmails.split(',').map(e => e.trim()).filter(e => e);
      if (bEmails.length > 0) {
        const toAdd = bEmails.join(', ');
        if (finalBillEmail) {
          finalBillEmail = `${finalBillEmail}, ${toAdd}`;
        } else {
          finalBillEmail = toAdd;
        }
      }
    }
    
    // Sanitize the final bill email to ensure it doesn't exceed 100 chars
    finalBillEmail = sanitizeEmail(finalBillEmail);

    // Step 3: Create Estimate linked to the project
    console.log('[QBO Sync] Step 3: Creating estimate...');
    const estimate = await createEstimate({
      projectId: project.Id,
      customerRef: project.Id, // Project (sub-customer) is the CustomerRef
      poNumber,
      scopeDetails,
      jobCategories,
      applianceCountInput,
      claimType,
      pmName,
      pmCompany,
      propertyAddress,
      billingAddress,
      billEmail: finalBillEmail,
      quotedAmount: leadData.quoted_amount as number | undefined,
      isCallBack,
      lineItems: leadData.qbo_line_items,
    });

    // Step 4: Write QBO IDs back to Firestore lead doc
    console.log('[QBO Sync] Step 4: Updating Firestore lead doc with QBO IDs');
    await admin.firestore().collection('leads').doc(leadId).update({
      qbo_customer_id: customer.Id,
      qbo_project_id: project.Id,
      qbo_estimate_id: estimate.Id,
      qbo_estimate_sync_token: estimate.SyncToken,
      qbo_doc_number: estimate.DocNumber || null, // guard against undefined
      qbo_synced_at: admin.firestore.FieldValue.serverTimestamp(),
      qbo_sync_error: admin.firestore.FieldValue.delete(), // clear any previous error
    });

    // Step 5: Download the QBO Estimate PDF, save to Drive, and update Calendar event
    const calendarEventId = leadData.calendar_event_id as string | null;
    const purchaseOrdersFolderId = leadData.purchase_orders_folder_id as string | null;

    if (calendarEventId || purchaseOrdersFolderId) {
      try {
        console.log('[QBO Sync] Step 5: Downloading estimate PDF from QBO...');
        const estimateLabel = estimate.DocNumber ? `Estimate_${estimate.DocNumber}` : `Estimate_${estimate.Id}`;
        let driveFileUrl: string | null = null;

        // 5a: Download the PDF and upload to the 04_Purchase_Orders subfolder
        if (purchaseOrdersFolderId) {
          try {
            const pdfBuffer = await getEstimatePdfBuffer(estimate.Id);
            const pdfBase64 = pdfBuffer.toString('base64');
            const fileName = `${estimateLabel}_${propertyAddress.replace(/[^a-zA-Z0-9]/g, '_').substring(0, 40)}.pdf`;
            const fileId = await uploadFileToFolder(purchaseOrdersFolderId, fileName, pdfBase64, 'application/pdf');
            driveFileUrl = `https://drive.google.com/file/d/${fileId}/view`;
            console.log(`[QBO Sync] ✅ Estimate PDF saved to Drive: ${driveFileUrl}`);

            // Write Drive file URL back to Firestore
            await admin.firestore().collection('leads').doc(leadId).update({
              qbo_estimate_drive_url: driveFileUrl,
            });
          } catch (pdfErr: any) {
            console.warn(`[QBO Sync] ⚠️ Could not save PDF to Drive: ${pdfErr?.message}`);
            // Save to Firestore so we can debug without searching logs
            await admin.firestore().collection('leads').doc(leadId).update({
              qbo_pdf_error: pdfErr?.message || 'Unknown PDF error',
            });
          }
        }

        // 5b: Calendar event QBO descriptions are omitted by design.
        // Direct links to the QBO estimate/work order are intentionally kept out 
        // to prevent technicians from viewing financial or unapproved estimate data.

        // 5c: Send Human-in-the-Loop Notification if it's a Quote
        const quotedAmount = leadData.quoted_amount as number | undefined;
        if (quotedAmount != null && quotedAmount > 0) {
          console.log(`[QBO Sync] Step 5c: Sending Estimate Review Email for quoted amount $${quotedAmount}`);
          await sendEstimateReviewEmail({
            propertyAddress,
            estimateDocNumber: estimate.DocNumber || estimate.Id,
            quotedAmount: quotedAmount || 0,
            driveFolderUrl: driveFileUrl || leadData.drive_folder_url as string || 'Pending',
            clientName: personToUse,
          });
        }
      } catch (step5Err: any) {
        // Non-fatal: log but don't fail the whole sync
        console.warn(`[QBO Sync] ⚠️ Step 5 error: ${step5Err?.message}`);
        await admin.firestore().collection('leads').doc(leadId).update({
          qbo_step5_error: step5Err?.message || 'Unknown Calendar/Step 5 error',
        });
      }
    } else {
      // Even if there's no calendar or PO folder, still send review email if it's a quote
      const quotedAmount = leadData.quoted_amount as number | undefined;
      if (quotedAmount != null && quotedAmount > 0) {
        console.log(`[QBO Sync] Sending Estimate Review Email for quoted amount $${quotedAmount} (no PO/Calendar folders available)`);
        await sendEstimateReviewEmail({
          propertyAddress,
          estimateDocNumber: estimate.DocNumber || estimate.Id,
          quotedAmount: quotedAmount || 0,
          driveFolderUrl: leadData.drive_folder_url as string || 'Pending',
          clientName: personToUse,
        });
      }
    }

    console.log(
      `[QBO Sync] ✅ Lead ${leadId} synced to QBO — Estimate #${estimate.DocNumber}`
    );
  } catch (error: any) {
    await logError('QBOSync:HandleLead', error, { leadId });

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
// Trigger B: Lead Update → QBO Sync
// ============================================

// Fields managed by QBO sync — changes to ONLY these fields should be ignored
// to prevent infinite update loops (sync writes back to the same doc).
const QBO_INTERNAL_FIELDS = new Set([
  'qbo_customer_id',
  'qbo_project_id',
  'qbo_estimate_id',
  'qbo_estimate_sync_token',
  'qbo_doc_number',
  'qbo_synced_at',
  'qbo_sync_error',
  'qbo_sync_attempted_at',
  'technician',
  'technician_email',
  'technician_assigned_at',
  // Lifecycle fields (managed by lead-lifecycle handlers)
  'status',
  'status_updated_at',
  'status_updated_by',
  'clock_in_at',
  'clock_in_coords',
  'clock_out_at',
  'report_id',
  'scheduled_time',
  'pm_notification_time',
  'time_updated_at',
  'drive_started_at',
  'drive_time_activity_id',
  'drive_time_activity_sync_token',
  'labor_time_activity_id',
  'labor_time_activity_sync_token',
  'navigation_url',
  'code_red',
  'code_red_at',
  'active_timer',
  'labor_end_time',
  'drive_cancelled_at',
  'drive_cancelled_by',
  'priority_flag',
  'drive_start_time',
  'drive_end_time',
  'labor_start_time',
  // PDF generation flags
  'qbo_export_status',
  'qbo_export_flagged_at',
]);

// Fields we track for bidirectional sync to QBO
const TRACKED_FIELDS = [
  'client_name',
  'client_cell',
  'client_email',
  'property_address',
  'scope_details',
  'qbo_line_items',
  'job_categories',
  'pm',
] as const;

type TrackedField = (typeof TRACKED_FIELDS)[number];

/**
 * Handle a lead document update — push changed contact/address fields to QBO
 *
 * Called by the onDocumentUpdated('leads/{leadId}') Firestore trigger.
 * Only processes changes to tracked fields; ignores QBO-internal field updates.
 */
export async function handleLeadUpdate(
  leadId: string,
  beforeData: FirebaseFirestore.DocumentData,
  afterData: FirebaseFirestore.DocumentData
): Promise<void> {
  // --- Infinite-loop guard ---
  // If the ONLY fields that changed are QBO-internal, bail out.
  const allKeys = new Set([
    ...Object.keys(beforeData),
    ...Object.keys(afterData),
  ]);
  const changedKeys = [...allKeys].filter((key) => {
    const before = JSON.stringify(beforeData[key] ?? null);
    const after = JSON.stringify(afterData[key] ?? null);
    return before !== after;
  });

  const hasNonInternalChange = changedKeys.some(
    (key) => !QBO_INTERNAL_FIELDS.has(key)
  );
  if (!hasNonInternalChange) {
    console.log(
      `[QBO Update] Skipping lead ${leadId} — only QBO-internal fields changed`
    );
    return;
  }

  // --- Determine which tracked fields changed ---
  const changed: Partial<Record<TrackedField, { before: any; after: any }>> = {};
  for (const field of TRACKED_FIELDS) {
    const before = beforeData[field] ?? null;
    const after = afterData[field] ?? null;
    if (JSON.stringify(before) !== JSON.stringify(after)) {
      changed[field] = { before, after };
    }
  }

  if (Object.keys(changed).length === 0) {
    console.log(
      `[QBO Update] No tracked fields changed for lead ${leadId}. Changed keys: ${changedKeys.join(', ')}`
    );
    return;
  }

  console.log(
    `[QBO Update] Processing lead ${leadId} — changed: ${Object.keys(changed).join(', ')}`
  );

  // Ensure QBO IDs exist (lead must have been synced first)
  const customerId = afterData.qbo_customer_id as string | undefined;
  const projectId = afterData.qbo_project_id as string | undefined;
  const estimateId = afterData.qbo_estimate_id as string | undefined;

  if (!customerId || !projectId || !estimateId) {
    console.warn(
      `[QBO Update] Lead ${leadId} missing QBO IDs — skipping update`
    );
    return;
  }

  try {
    // --- 0. Sync PM updates to global PMs collection ---
    if (changed.pm) {
      const pmId = afterData.pm_id || beforeData.pm_id;
      if (pmId) {
        const pmAfter = changed.pm.after || {};
        const pmBefore = changed.pm.before || {};
        
        const pmFieldsToUpdate: any = {};
        let needsUpdate = false;
        
        const fieldsToCheck = [
          'full_name',
          'company_name',
          'email',
          'cell_phone',
          'billing_address',
          'assistant_emails',
          'billing_emails'
        ];

        for (const f of fieldsToCheck) {
          const afterVal = pmAfter[f];
          const beforeVal = pmBefore[f];
          
          if (afterVal !== beforeVal) {
            if (afterVal === undefined || afterVal === null || (typeof afterVal === 'string' && afterVal.trim() === '')) {
                pmFieldsToUpdate[f] = admin.firestore.FieldValue.delete();
            } else {
                pmFieldsToUpdate[f] = afterVal;
            }
            needsUpdate = true;
          }
        }

        if (needsUpdate) {
          console.log(`[QBO Update] PM data modified on lead ${leadId}, propagating changes to global PM record ${pmId}...`);
          pmFieldsToUpdate.last_updated = admin.firestore.FieldValue.serverTimestamp();
          await admin.firestore().collection('pms').doc(pmId).set(pmFieldsToUpdate, { merge: true });
        }
      }
    }

    // --- 1. Check if it's a PM job ---
    const hasPM = !!afterData.pm?.full_name;

    // --- 2. Update QBO Customer (name / phone / email) ---
    const nameChanged = !!changed.client_name;
    const phoneChanged = !!changed.client_cell;
    const emailChanged = !!changed.client_email;

    if (!hasPM && (nameChanged || phoneChanged || emailChanged)) {
      // Fetch current SyncToken for the customer
      const { getCustomer } = await import('../services/quickbooks');
      const customer = await getCustomer(customerId);

      const updateOpts: Parameters<typeof updateCustomer>[0] = {
        customerId,
        syncToken: customer.SyncToken,
      };

      if (nameChanged) updateOpts.displayName = afterData.client_name;
      if (phoneChanged) updateOpts.phone = afterData.client_cell;
      if (emailChanged) updateOpts.email = afterData.client_email;

      await updateCustomer(updateOpts);
      console.log(`[QBO Update] Customer ${customerId} updated`);
    } else if (hasPM && (nameChanged || phoneChanged || emailChanged)) {
       console.log(`[QBO Update] Skipping Customer ${customerId} update (Lead has a PM, ignoring client detail changes)`);
    }

    // --- 3. Rename QBO Project if address (or name) changed ---
    const addressChanged = !!changed.property_address;

    if (addressChanged || (nameChanged && !hasPM)) {
      const { formatProjectName } = await import('../services/quickbooks');
      const personName = hasPM ? afterData.pm.company_name : afterData.client_name;
      const jobCategories = (afterData.job_categories as string[]) || [];
      const newProjectName = formatProjectName(afterData.property_address, personName, jobCategories);
      
      const { getCustomer } = await import('../services/quickbooks');
      const project = await getCustomer(projectId);

      await updateProject({
        projectId,
        syncToken: project.SyncToken,
        displayName: newProjectName,
      });
      console.log(
        `[QBO Update] Project ${projectId} renamed to "${newProjectName}"`
      );
    }

    // --- 3. Update Estimate ShipAddr if address changed ---
    if (addressChanged) {
      let syncToken = afterData.qbo_estimate_sync_token as string | undefined;
      if (!syncToken) {
        const estimate = await getEstimate(estimateId);
        syncToken = estimate.SyncToken;
      }

      const result = await updateEstimateAddress(
        estimateId,
        syncToken!,
        afterData.property_address
      );

      // Write new SyncToken back so future updates don't conflict
      await admin.firestore().collection('leads').doc(leadId).update({
        qbo_estimate_sync_token: result.SyncToken,
        qbo_synced_at: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // --- 4. Update Estimate Lines if scope, line items, or categories changed ---
    const scopeChanged = !!changed.scope_details;
    const lineItemsChanged = !!changed.qbo_line_items;
    const categoriesChanged = !!changed.job_categories;

    if (scopeChanged || lineItemsChanged || categoriesChanged) {
      console.log(`[QBO Update] Scope, line items, or categories changed for lead ${leadId}. Syncing to QBO Estimate...`);
      
      const { findOrCreateServiceItem } = await import('../services/quickbooks');
      const serviceItem = await findOrCreateServiceItem();

      let syncToken = afterData.qbo_estimate_sync_token as string | undefined;
      if (!syncToken) {
        const estimate = await getEstimate(estimateId);
        syncToken = estimate.SyncToken;
      }

      const qboUpdates: any = {
        GlobalTaxCalculation: 'TaxExcluded',
        CustomField: [
          { DefinitionId: '1', Name: 'P.O. Number', Type: 'StringType', StringValue: truncateCustomField(afterData.is_call_back ? `[CALL BACK] ${((afterData.job_categories as string[]) || []).join(' | ')}` : ((afterData.job_categories as string[]) || []).join(' | ')) },
          { DefinitionId: '2', Name: 'Project Manager', Type: 'StringType', StringValue: truncateCustomField(afterData.pm?.full_name || '') },
          { DefinitionId: '3', Name: 'sales3', Type: 'StringType', StringValue: truncateCustomField(afterData.claim_type || '') },
          { DefinitionId: '4', Name: 'Technician', Type: 'StringType', StringValue: afterData.technician || 'Pending' },
        ],
      };

      if (afterData.qbo_line_items && afterData.qbo_line_items.length > 0) {
        qboUpdates.Line = afterData.qbo_line_items.map((item: any) => ({
          DetailType: 'SalesItemLineDetail',
          Amount: item.Amount,
          Description: truncateDescription(item.Description),
          SalesItemLineDetail: {
            ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
            Qty: item.Qty,
            UnitPrice: item.UnitPrice,
            TaxCodeRef: { value: '12' }, // Default HST (H) code
          },
        }));
      } else {
        // Fallback to single line with scope_details OR auto-calculated inspection price
        const { unitPrice, amount } = calculateInspectionPrice({
          jobCategories: afterData.job_categories || [],
          applianceCountInput: afterData.appliance_count ? parseInt(String(afterData.appliance_count), 10) : null,
          quotedAmount: afterData.quoted_amount
        });

        qboUpdates.Line = [
          {
            DetailType: 'SalesItemLineDetail',
            Amount: amount,
            Description: truncateDescription(afterData.scope_details),
            SalesItemLineDetail: {
              ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
              Qty: 1,
              UnitPrice: unitPrice,
              TaxCodeRef: { value: '12' },
            },
          },
        ];
      }

      const result = await updateEstimate(estimateId, syncToken, qboUpdates);

      // Write new SyncToken back
      await admin.firestore().collection('leads').doc(leadId).update({
        qbo_estimate_sync_token: result.SyncToken,
        qbo_synced_at: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Record the sync timestamp if not already done
    if (!addressChanged && !scopeChanged && !lineItemsChanged) {
      await admin.firestore().collection('leads').doc(leadId).update({
        qbo_synced_at: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    console.log(`[QBO Update] ✅ Lead ${leadId} synced to QBO`);
  } catch (error: any) {
    await logError('QBOSync:HandleUpdate', error, { leadId, changedKeys: Object.keys(changed) });

    await admin
      .firestore()
      .collection('leads')
      .doc(leadId)
      .update({
        qbo_sync_error: error?.message || 'Unknown error',
        qbo_sync_attempted_at: admin.firestore.FieldValue.serverTimestamp(),
      })
      .catch((updateErr) =>
        console.error('[QBO Update] Failed to record error:', updateErr)
      );

    throw error;
  }
}

// ============================================
// Trigger C: Calendar → QBO Technician Sync
// ============================================

// IMPERSONATE_USER removed - using robust JWT pattern via getCalendarClient from services/calendar

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

  // Look back 60 minutes for recently modified events (safer than 10 mins)
  const updatedMin = new Date(Date.now() - 60 * 60 * 1000).toISOString();

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
      let attendees = event.attendees;

      // Fallback: Sometimes events.list drops attendees for events with multiple participants.
      if (!attendees || attendees.length === 0) {
        if (event.id) {
          try {
            const singleEvent = await calendar.events.get({
              calendarId,
              eventId: event.id,
            });
            attendees = singleEvent.data.attendees;
          } catch (e: any) {
            console.error(`[Tech Sync] Failed to fetch single event ${event.id}:`, e?.message);
          }
        }
      }

      if (!event.id || !attendees || attendees.length === 0) {
        console.log(`[Tech Sync] Skip ${event.id}: No attendees`);
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
        console.log(`[Tech Sync] Skip ${event.id}: No matching lead found in Firestore`);
        continue; // No matching lead for this event
      }

      const leadDoc = leadsSnapshot.docs[0];
      const leadData = leadDoc.data();

      const enforceCalendarScheduledState = async (calEvent: any) => {
        try {
          const currentTitle = calEvent.summary || '';
          let newTitle = currentTitle;
          if (currentTitle.includes('[UNSCHEDULED]')) {
            newTitle = currentTitle.replace('[UNSCHEDULED]', '[SCHEDULED]');
          } else if (currentTitle.includes('UNSCHEDULED')) {
            newTitle = currentTitle.replace('UNSCHEDULED', 'SCHEDULED');
          } else if (!currentTitle.includes('[SCHEDULED]')) {
            newTitle = `[SCHEDULED] ${currentTitle}`;
          }

          if (newTitle !== currentTitle || calEvent.colorId !== '10') {
            await updateCalendarEvent(calEvent.id, { 
              summary: newTitle,
              colorId: '10', // Green
            });
            console.log(`[Tech Sync] Calendar event ${calEvent.id} enforced to SCHEDULED and green color.`);
          }
        } catch (calErr: any) {
          console.error(`[Tech Sync] Calendar title/color update failed (non-fatal):`, calErr?.message);
        }
      };

      const enforceCalendarUnscheduledState = async (calEvent: any) => {
        try {
          const currentTitle = calEvent.summary || '';
          let newTitle = currentTitle;
          if (currentTitle.includes('[SCHEDULED]')) {
            newTitle = currentTitle.replace('[SCHEDULED]', '[UNSCHEDULED]');
          } else if (currentTitle.includes('SCHEDULED') && !currentTitle.includes('UNSCHEDULED')) {
            newTitle = currentTitle.replace('SCHEDULED', 'UNSCHEDULED');
          } else if (!currentTitle.includes('[UNSCHEDULED]')) {
            newTitle = `[UNSCHEDULED] ${currentTitle}`;
          }

          const targetColorId = leadData.emergency_dispatch ? '11' : '5';

          if (newTitle !== currentTitle || calEvent.colorId !== targetColorId) {
            await updateCalendarEvent(calEvent.id, { 
              summary: newTitle,
              colorId: targetColorId, 
            });
            console.log(`[Tech Sync] Calendar event ${calEvent.id} enforced to UNSCHEDULED and color ${targetColorId}.`);
          }
        } catch (calErr: any) {
          console.error(`[Tech Sync] Calendar title/color update failed (non-fatal):`, calErr?.message);
        }
      };

      // Determine which attendees are technicians
      // Exclude the client email and PM email
      const clientEmail = (leadData.client_email || '').toLowerCase();
      const pmEmail = (leadData.pm?.email || leadData.pm_email || '').toLowerCase();

      const techAttendees = attendees.filter((attendee) => {
        const email = (attendee.email || '').toLowerCase();
        return (
          email &&
          email !== clientEmail &&
          email !== pmEmail &&
          !email.includes('calendar.google.com') && // Skip calendar resource
          !email.includes('nicole@') &&
          !email.includes('admin@') &&
          attendee.responseStatus !== 'declined'
        );
      });

      const knownTechs: Record<string, string> = {
        'tyler@immediateresponsehvac.ca': 'Tyler',
        'cory@immediateresponsehvac.ca': 'Cory',
        'rob@immediateresponsehvac.ca': 'Rob',
        'randy@immediateresponsehvac.ca': 'Randy',
        'berkant@immediateresponsehvac.ca': 'Berkant',
        'omar@immediateresponsehvac.ca': 'Omar'
      };

      const techNames = techAttendees.map((tech) => {
        const techEmailLower = (tech.email || '').toLowerCase();
        let name = knownTechs[techEmailLower] || tech.displayName;
        if (!name) {
          const prefix = techEmailLower.split('@')[0] || 'Unknown';
          name = prefix.charAt(0).toUpperCase() + prefix.slice(1);
        }
        return name;
      });

      const joinedTechName = [...new Set(techNames.filter(n => n))].join(' & ');

      // Detect if the time has changed
      let newStartTime = event.start?.dateTime || event.start?.date || null;
      let newEndTime = event.end?.dateTime || event.end?.date || null;
      let oldStartTime = leadData.scheduled_time as string | null;
      let oldEndTime = leadData.pm_notification_time as string | null;

      const techChanged = joinedTechName !== (leadData.technician || '');
      let timeChanged = (newStartTime && oldStartTime && newStartTime !== oldStartTime) || 
                          (newEndTime && oldEndTime && newEndTime !== oldEndTime);

      // EXTEND and REDUCE LOGIC
      const description = event.description || '';
      const extendMatch = description.match(/EXTEND:?\s*(\d+)\s*DAYS?/i);
      const reduceMatch = description.match(/(?:REDUCE|SHORTEN):?\s*(\d+)\s*DAYS?/i);
      
      let newJobDuration = Number(leadData.job_duration) || 1;
      let durationApplied = false;

      if (extendMatch || reduceMatch) {
        if (extendMatch) {
          const extendDays = parseInt(extendMatch[1], 10);
          newJobDuration += extendDays;
          console.log(`[Tech Sync] Detected EXTEND: ${extendDays} days. New duration: ${newJobDuration}`);
        }
        
        if (reduceMatch) {
          const reduceDays = parseInt(reduceMatch[1], 10);
          newJobDuration = Math.max(1, newJobDuration - reduceDays);
          console.log(`[Tech Sync] Detected SHORTEN: ${reduceDays} days. New duration: ${newJobDuration}`);
        }
        
        // Remove ALL occurrences of EXTEND, REDUCE, or SHORTEN from description
        const newDescription = description
          .replace(/EXTEND:?\s*\d+\s*DAYS?/gi, '')
          .replace(/(?:REDUCE|SHORTEN):?\s*\d+\s*DAYS?/gi, '')
          .trim();
        
        try {
          const { getEventTiming } = await import('../services/calendar');
          const timing = getEventTiming({
            ...leadData,
            visitRequested: newStartTime || leadData.scheduled_time || leadData.visit_requested,
            visitStatus: leadData.status,
            jobDuration: newJobDuration,
            includeWeekends: leadData.include_weekends !== false
          } as any);

          const { updateCalendarEvent } = await import('../services/calendar');
          const updatePayload: any = { description: newDescription };
          
          if (event.recurringEventId) {
            // It's an instance. Patch the master for recurrence.
            await updateCalendarEvent(event.recurringEventId, {
              recurrence: timing.recurrence && timing.recurrence.length > 0 ? timing.recurrence : null
            } as any);
            // And patch the instance to remove the keyword
            await updateCalendarEvent(event.id!, updatePayload);
          } else {
            // It's a single event. Patch it with start, end, and recurrence.
            updatePayload.start = timing.start;
            updatePayload.end = timing.end;
            updatePayload.recurrence = timing.recurrence && timing.recurrence.length > 0 ? timing.recurrence : null;
            await updateCalendarEvent(event.id!, updatePayload);
          }
          
          await leadDoc.ref.update({
            job_duration: newJobDuration
          });

          durationApplied = true;
          console.log(`[Tech Sync] Successfully updated lead ${leadDoc.id} duration to ${newJobDuration} days.`);
        } catch(e: any) {
          console.error(`[Tech Sync] Failed to update calendar event ${event.id} duration:`, e);
          const { triggerSchedulingExceptionProtocol } = await import('../services/exception-protocol');
          await triggerSchedulingExceptionProtocol(
            leadData.client_name || leadData.property_address || 'Unknown Lead',
            `Failed to process EXTEND/SHORTEN keyword: ${e.message}`,
            newJobDuration
          );
        }
      }

      // RESUME LOGIC: Check for RESUME: [Date] or RESUME [Date]
      const resumeMatch = description.match(/RESUME:?\s*([^\n]+)/i);
      let resumeApplied = false;

      if (resumeMatch && !durationApplied) {
        const resumeDateStr = resumeMatch[1].trim();
        let resumeDate = new Date(resumeDateStr);
        
        // Handle JS defaulting to 2001 when no year is specified
        if (resumeDate.getFullYear() === 2001 && !resumeDateStr.includes('2001')) {
          const now = new Date();
          resumeDate.setFullYear(now.getFullYear());
          // If the specified date is more than 30 days in the past, assume next year
          if (resumeDate.getTime() < now.getTime() - 30 * 24 * 60 * 60 * 1000) {
            resumeDate.setFullYear(now.getFullYear() + 1);
          }
        }

        const newDescription = description.replace(/RESUME:?\s*([^\n]+)/gi, '').trim();

        try {
          if (isNaN(resumeDate.getTime())) {
            throw new Error(`Invalid date format for RESUME trigger: ${resumeDateStr}`);
          }

          // Use original start time if available, otherwise default to 8am ET (which is 12pm UTC)
          if (event.start?.dateTime) {
            const originalDate = new Date(event.start.dateTime);
            resumeDate.setHours(originalDate.getHours(), originalDate.getMinutes(), 0, 0);
          } else {
            resumeDate.setHours(12, 0, 0, 0); // 12:00 UTC = 8:00 AM EDT
          }

          const { updateCalendarEvent, createLeadCalendarEvent } = await import('../services/calendar');
          
          const eventParams = {
            propertyAddress: leadData.property_address || 'Unknown Address',
            apartmentNumber: leadData.apartment_number,
            clientName: leadData.client_name || 'Unknown',
            clientEmail: leadData.client_email,
            clientPhone: leadData.client_cell,
            pmName: leadData.pm?.full_name,
            pmEmail: leadData.pm?.email,
            pmPhone: leadData.pm?.cell_phone,
            pmCompany: leadData.pm?.company_name,
            jobCategories: leadData.job_categories || [],
            claimType: leadData.claim_type,
            jobType: leadData.job_type || 'Unknown',
            scopeDetails: leadData.scope_details,
            visitRequested: resumeDate,
            visitStatus: `Part Pending - Rescheduled for ${resumeDateStr}`,
            accessInstructions: leadData.access_instructions,
            lockboxCode: leadData.lockbox_code,
            gateCode: leadData.gate_code,
            driveFolderUrl: leadData.drive_folder_url || '',
            driveFolderId: leadData.drive_folder_id || '',
            emergencyDispatch: false,
            isScheduled: true,
            applianceCount: leadData.appliance_count,
            applianceList: leadData.appliance_list,
            equipmentType: leadData.equipment_type,
            fuelType: leadData.fuel_type,
            quotedAmount: leadData.quoted_amount,
            jobDuration: leadData.job_duration || 1,
            includeWeekends: leadData.include_weekends !== false
          };

          // Create a NEW calendar event for the resumeDate so we don't orphan the tech's current time entry
          const newEventResult = await createLeadCalendarEvent(eventParams);
          
          // Now update the original event to remove the keyword so it doesn't loop
          await updateCalendarEvent(event.id!, {
            description: newDescription
          });

          // Prevent the fallback description update
          timeChanged = true; 

          // Update Firestore status and calendar_event_id
          await leadDoc.ref.update({
            status: `Part Pending - Rescheduled for ${resumeDateStr}`,
            status_updated_at: admin.firestore.FieldValue.serverTimestamp(),
            status_updated_by: 'system@resume-trigger',
            calendar_event_id: newEventResult.eventId,
            visit_requested: admin.firestore.Timestamp.fromDate(resumeDate)
          });

          resumeApplied = true;
          console.log(`[Tech Sync] RESUME triggered for lead ${leadDoc.id} to date ${resumeDateStr} (New Event: ${newEventResult.eventId})`);
        } catch (e: any) {
          console.error(`[Tech Sync] Failed to process RESUME trigger:`, e);
          const { triggerSchedulingExceptionProtocol } = await import('../services/exception-protocol');
          await triggerSchedulingExceptionProtocol(
            leadData.client_name || leadData.property_address || 'Unknown Lead',
            `Failed to process RESUME keyword: ${e.message}`,
            resumeDateStr
          );
        }
      }

      // Check if calendar attendees are out of sync with Firestore (e.g. techs added directly in GCal)
      const firestoreAttendees: string[] = Array.isArray(leadData.attendees) ? leadData.attendees : [];
      const calendarAttendeeEmails = techAttendees.map(t => (t.email || '').toLowerCase()).sort();
      const firestoreAttendeeEmails = firestoreAttendees.map(e => e.toLowerCase()).sort();
      const attendeesOutOfSync = JSON.stringify(calendarAttendeeEmails) !== JSON.stringify(firestoreAttendeeEmails);

      if (!techChanged && !timeChanged && !durationApplied && !resumeApplied && !attendeesOutOfSync) {
        // Even if no data changed, always enforce the calendar title/color 
        // This solves the 'glitch' where multiple techs are added but title stays [UNSCHEDULED]
        if (techAttendees.length > 0) {
          await enforceCalendarScheduledState(event);
        } else {
          await enforceCalendarUnscheduledState(event);
        }
        console.log(`[Tech Sync] Skip ${event.id}: No meaningful changes detected for lead ${leadDoc.id}.`);
        continue;
      }

      console.log(
        `[Tech Sync] Processing update for lead ${leadDoc.id} (Event ${event.id}). Tech Changed: ${techChanged}, Time Changed: ${timeChanged}`
      );

      // 1. Handle Time Change Notification (if not first assignment)
      if (timeChanged && leadData.technician && !techChanged) {
        try {
          const { sendEmail, formatDateOnly, formatTimeOnly } = await import('./lead-lifecycle');
          
          const isInsurance = leadData.job_type === 'Res_Insurance' || leadData.job_type === 'Comm_Insurance';
          const targetEmail = isInsurance 
            ? (leadData.pm?.email || leadData.pm_email as string | null)
            : (leadData.client_email as string | null);
          
          const targetName = isInsurance 
            ? (leadData.pm?.full_name || leadData.pm_name as string | null)
            : (leadData.client_name as string | null);
          
          const firstName = targetName ? targetName.split(' ')[0] : 'there';
          const shortAddress = leadData.property_address ? (leadData.property_address as string).split(',')[0].trim() : 'the property';

          const oldStartDateParsed = new Date(oldStartTime || '');
          const newStartDateParsed = new Date(newStartTime || '');
          const newEndDateParsed = new Date(newEndTime || '');
          
          if (targetEmail && !isNaN(newStartDateParsed.getTime()) && !isNaN(oldStartDateParsed.getTime())) {
            const newDateFormatted = formatDateOnly(newStartDateParsed);
            const newStartFormatted = formatTimeOnly(newStartDateParsed);
            const newEndFormatted = formatTimeOnly(newEndDateParsed);
            
            await sendEmail({
              to: targetEmail,
              subject: `Service Visit Update - ${shortAddress}`,
              html: `
                <!DOCTYPE html>
                <html>
                <head>
                  <meta charset="utf-8">
                </head>
                <body>
                  <div style="font-family: Arial, sans-serif; max-width: 600px; color: #333; line-height: 1.5;">
                    <p>Hi ${firstName},</p>
                    <p>We're writing to let you know there has been an update to your service visit request for ${shortAddress}.</p>
                    <p>Your visit has been rescheduled to <strong>${newDateFormatted}</strong>, between <strong>${newStartFormatted}</strong> and <strong>${newEndFormatted}</strong>.</p>
                    <p>Our technician, <strong>${joinedTechName}</strong>, is assigned to this visit.</p>
                    <p>If you have any questions or need to make an adjustment to the request, please don't hesitate to reach out to us.</p>
                    <p>Best regards,<br>
                    <br>
                    <strong>Nicole Mourtzis</strong><br>
                    Office Manager<br>
                    Immediate Response HVAC<br>
                    Phone: 416-291-4822<br>
                    Email: nicole@immediateresponsehvac.ca</p>
                  </div>
                </body>
                </html>`,
            });
            console.log(`[Tech Sync] Reschedule email sent to ${targetEmail}`);
          }
        } catch (err: any) {
          console.error(`[Tech Sync] Error processing time change for ${leadDoc.id}:`, err?.message);
        }
      }

      // 2. Handle Technician Assignment / Update
      if (techChanged) {
        console.log(`[Tech Sync] Assigning tech(s) "${joinedTechName}" to lead ${leadDoc.id}`);

        // Attempt QBO Update (if estimate exists)
        if (leadData.qbo_estimate_id) {
          try {
            let syncToken = leadData.qbo_estimate_sync_token;
            if (!syncToken) {
              const estimate = await getEstimate(leadData.qbo_estimate_id);
              syncToken = estimate.SyncToken;
            }

            await updateEstimateTechnician(
              leadData.qbo_estimate_id,
              syncToken,
              joinedTechName
            );
          } catch (qboErr: any) {
            console.error(`[Tech Sync] QBO Update failed for lead ${leadDoc.id} (non-fatal):`, qboErr?.message);
          }
        }

        // Send PM/Client "Job Scheduled" email (only if it's the FIRST assignment)
        if (!leadData.technician) {
          const isInsurance = leadData.job_type === 'Res_Insurance' || leadData.job_type === 'Comm_Insurance';
          const targetEmail = isInsurance 
            ? (leadData.pm?.email || leadData.pm_email as string | null)
            : (leadData.client_email as string | null);
          
          const targetName = isInsurance 
            ? (leadData.pm?.full_name || leadData.pm_name as string | null)
            : (leadData.client_name as string | null);
          
          const firstName = targetName ? targetName.split(' ')[0] : 'there';

          if (targetEmail && newStartTime && newEndTime) {
            try {
              const { sendEmail, formatDateOnly, formatTimeOnly } = await import('./lead-lifecycle');
              const startDate = new Date(newStartTime);
              const endDate = new Date(newEndTime);
              
              if (!isNaN(startDate.getTime()) && !isNaN(endDate.getTime())) {
                const dateFormatted = formatDateOnly(startDate);
                const startFormatted = formatTimeOnly(startDate);
                const endFormatted = formatTimeOnly(endDate);
                const shortAddress = leadData.property_address ? (leadData.property_address as string).split(',')[0].trim() : 'the property';
                
                await sendEmail({
                  to: targetEmail,
                  subject: `Service Visit Update - ${shortAddress}`,
                  html: `
                    <!DOCTYPE html>
                    <html>
                    <head>
                      <meta charset="utf-8">
                    </head>
                    <body>
                      <div style="font-family: Arial, sans-serif; max-width: 600px; color: #333; line-height: 1.5;">
                        <p>Hi ${firstName},</p>
                        <p>Your service visit request for <strong>${leadData.property_address || 'the property'}</strong> has been confirmed.</p>
                        <p>Our technician, <strong>${joinedTechName}</strong>, has been assigned to your job and will be there on <strong>${dateFormatted}</strong> between <strong>${startFormatted}</strong> and <strong>${endFormatted}</strong>.</p>
                        <p>We appreciate your patience as we work to accommodate your request. If you have any questions in the interim, please don't hesitate to reach out.</p>
                        <p>Best regards,<br>
                        <br>
                        <strong>Nicole Mourtzis</strong><br>
                        Office Manager<br>
                        Immediate Response HVAC<br>
                        Phone: 416-291-4822<br>
                        Email: nicole@immediateresponsehvac.ca</p>
                      </div>
                    </body>
                    </html>`,
                });
                console.log(`[Tech Sync] Notification email sent to ${targetEmail}`);
              }
            } catch (emailErr: any) {
              console.error(`[Tech Sync] Email notification failed (non-fatal):`, emailErr?.message);
            }
          }
        }
      }

      // 3. Final Firestore Update
      // Always reflect the true attendee state — regardless of current status.
      // This ensures Google Calendar edits are always reflected in the OPS dashboard.
      const techEmailList = techAttendees.map(t => t.email).filter(Boolean) as string[];
      let newStatus: string;
      if (techEmailList.length > 0) {
        newStatus = 'scheduled';
      } else {
        newStatus = 'to-be-scheduled';
      }

      await leadDoc.ref.update({
        technician: joinedTechName,
        technician_email: techEmailList.join(', '),
        technician_assigned_at: admin.firestore.FieldValue.serverTimestamp(),
        // Sync attendees back so OPS dashboard chip stays accurate
        attendees: techEmailList,
        daily_attendees: techEmailList.length > 0 ? { day_0: techEmailList } : {},
        status: newStatus,
        status_updated_at: admin.firestore.FieldValue.serverTimestamp(),
        status_updated_by: 'system@calendar-sync',
        ...(newStartTime && { scheduled_time: newStartTime }),
        ...(newEndTime && { pm_notification_time: newEndTime }),
        ...(durationApplied && { job_duration: newJobDuration })
      });

      // 4. Update calendar event to reflect SCHEDULED/UNSCHEDULED
      if (techEmailList.length > 0) {
        await enforceCalendarScheduledState(event);
      } else {
        await enforceCalendarUnscheduledState(event);
      }

      updated++;
      console.log(
        `[Tech Sync] ✅ Updated lead ${leadDoc.id} with tech "${joinedTechName}"`
      );
    } catch (error: any) {
      errors++;
      await logError('QBOSync:TechSync', error, { eventId: event.id });
    }
  }

  console.log(
    `[Tech Sync] Complete: ${processed} processed, ${updated} updated, ${errors} errors`
  );
  return { processed, updated, errors };
}
