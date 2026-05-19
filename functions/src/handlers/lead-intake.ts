// Deploy nudge: Feb 13 - final handshake fix
/**
 * Lead Intake Handler
 * Orchestrates the complete lead intake workflow
 */

import { z } from 'zod';
import { v4 as uuidv4 } from 'uuid';
import * as admin from 'firebase-admin';
import { IntakeRequest, IntakeResponse, PMSearchResponse, ProjectManager } from '../types';
import { isInsuranceJob } from '../config';
import { createLeadFolderStructure, uploadFileToFolder } from '../services/drive';
import { createLeadCalendarEvent, acceptEventForAttendee } from '../services/calendar';
import { sendCustomerConfirmationEmail, sendTravelNotificationEmail, sendFixedScheduleNotificationEmail } from '../services/email';
import { logError } from '../utils/logger';
import { replaceUndefinedWithNull, normalizeAddress, isReAndRe, isInspection, isTroubleshooting, isDuctCleaning } from '../utils';

// Input validation schema
const IntakeRequestSchema = z.object({
  property_address: z.string().min(1, 'Property address is required').refine(val => {
    const v = val.toLowerCase().trim();
    return v !== 'n/a' && v !== 'unknown address' && v !== 'unknown' && v !== 'tbd';
  }, 'Property address cannot be a placeholder (e.g. N/A)'),
  apartment_number: z.string().nullable().optional(),
  job_type: z.enum(['Residential', 'Commercial', 'Res_Insurance', 'Comm_Insurance']),
  claim_type: z.union([z.enum(['Flood', 'Fire', 'Abatement', 'Other']), z.literal('')]).nullable().optional(),
  job_categories: z.array(z.string()).nullable().optional(),
  misc_description: z.string().nullable().optional(),
  pm: z.object({
    pm_id: z.string().nullable().optional(),
    full_name: z.string().min(1),
    company_name: z.string().nullable().optional(),
    email: z.union([z.string().email(), z.literal('')]).nullable().optional(),
    cell_phone: z.string().nullable().optional(),
    billing_address: z.string().nullable().optional(),
    assistant_emails: z.string().nullable().optional(),
    billing_emails: z.string().nullable().optional(),
  }).nullable().optional(),
  client_name: z.string().min(1, 'Client name is required'),
  client_email: z.union([z.string().email(), z.literal('')]).nullable().optional(),
  client_cell: z.string().nullable().optional(),
  scope_details: z.string().nullable().optional(),
  po_number: z.string().nullable().optional(),
  visit_requested: z.string().nullable().optional().or(z.literal('')),
  visit_end: z.string().nullable().optional(),
  visit_status: z.enum(['To Be Scheduled', 'Confirmed date']).nullable().optional(),
  job_duration: z.number().nullable().optional(),
  include_weekends: z.boolean().nullable().optional(),
  access_instructions: z.enum(['Contact PM', 'Contact Client', 'Crew on site - Reg hrs', 'Crew on site - 24 hrs', 'Lockbox']).nullable().optional(),
  lockbox_code: z.string().nullable().optional(),
  gate_code: z.string().nullable().optional(),
  emergency_dispatch: z.boolean().nullable().optional(),
  appliance_count: z.union([z.string(), z.number()]).nullable().optional(),
  appliance_list: z.string().nullable().optional(),
  equipment_type: z.string().nullable().optional(),
  fuel_type: z.string().nullable().optional(),
  update_pm: z.boolean().nullable().optional(),
  additional_work: z.boolean().nullable().optional(),
  distance_metres: z.number().nullable().optional(),
  td4_required: z.boolean().nullable().optional(),
  is_call_back: z.boolean().nullable().optional(),
  has_actionable_quote_details: z.boolean().nullable().optional(),
  is_bid_or_tender: z.boolean().nullable().optional(),
  bid_due_date: z.string().nullable().optional(),
  submitted_by: z.string().nullable().optional(),
  supporting_docs: z.array(z.object({
    name: z.string(),
    data: z.string(),
    mime_type: z.string(),
  })).nullable().optional(),
  qbo_line_items: z.array(z.any()).nullable().optional(),
  automated_email: z.boolean().nullable().optional(),
  calendar_event: z.boolean().nullable().optional(),
  automated_qbo: z.boolean().nullable().optional(),
});

/**
 * Handle the complete lead intake workflow
 */
export async function handleLeadIntake(body: unknown): Promise<IntakeResponse> {
  console.log('========================================');
  console.log('LEAD INTAKE STARTED (Lean Stack)');
  console.log('========================================');
  
  // Validate input
  const validationResult = IntakeRequestSchema.safeParse(body);
  if (!validationResult.success) {
    console.error('VALIDATION FAILED:', validationResult.error.errors);
    throw new Error(`Validation error: ${validationResult.error.errors.map(e => e.message).join(', ')}`);
  }

  const request: IntakeRequest = validationResult.data as IntakeRequest;
  
  // Custom Validation: Insurance Jobs SHOULD have PM details, but we only REQUIRE name to proceed.
  if (isInsuranceJob(request.job_type)) {
    if (!request.pm?.full_name) {
      throw new Error('Validation error: Project Manager Name is required for Insurance jobs.');
    }
    // Default company if missing
    if (!request.pm.company_name) {
      console.warn(`[Intake] PM Company missing for insurance job: ${request.property_address}. Defaulting.`);
      request.pm.company_name = 'Insurance/Restoration Company';
    }
    // Ensure other fields have at least a placeholder or are null to satisfy later logic
    if (!request.pm.email) console.warn(`[Intake] PM Email missing for insurance job: ${request.property_address}`);
    if (!request.pm.cell_phone) console.warn(`[Intake] PM Phone missing for insurance job: ${request.property_address}`);
    if (!request.pm.billing_address) {
      console.warn(`[Intake] PM Billing Address missing for insurance job: ${request.property_address}. Will fallback to property address.`);
      // We don't set it here, let the business logic handle the fallback
    }
  } else {
    // Strip PM details for non-insurance jobs to prevent QBO mapping errors
    if (request.pm) {
      delete request.pm;
    }
  }

  // --- GLOBAL SETTINGS CHECK ---
  let globalSettings: any = {
    automated_email: true,
    calendar_event: true,
    automated_qbo: true
  };
  try {
    const settingsDoc = await admin.firestore().collection('system_settings').doc('global').get();
    if (settingsDoc.exists) {
      globalSettings = { ...globalSettings, ...settingsDoc.data() };
    }
  } catch (settingsError) {
    console.warn('[Intake] Failed to fetch global settings:', settingsError);
  }

  // Apply global defaults if not explicitly disabled by the request
  request.automated_email = request.automated_email !== false && globalSettings.automated_email !== false;
  request.calendar_event = request.calendar_event !== false && globalSettings.calendar_event !== false;
  request.automated_qbo = request.automated_qbo !== false && globalSettings.automated_qbo !== false;

  // --- DUPLICATE & AUTO-MERGE CHECK ---
  let targetExistingLeadId: string | null = null;
  let targetExistingLeadData: any = null;

  if (request.property_address) {
    try {
      const db = admin.firestore();
      const normalizedTargetAddress = normalizeAddress(request.property_address);
      const addressParts = request.property_address.trim().split(' ');
      const streetNumber = addressParts[0].match(/^\d+/) ? addressParts[0] : '';
      const searchPrefix = streetNumber || request.property_address.substring(0, 5);
      const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);

      const recentLeads = await db.collection('leads')
        .where('property_address', '>=', searchPrefix)
        .where('property_address', '<=', searchPrefix + '\uf8ff')
        .get();

      const sortedDocs = recentLeads.docs.sort((a, b) => {
        const aDate = (a.data().created_at as admin.firestore.Timestamp)?.toDate() || new Date(0);
        const bDate = (b.data().created_at as admin.firestore.Timestamp)?.toDate() || new Date(0);
        return aDate.getTime() - bDate.getTime(); // Oldest first to merge into the original lead
      });

      const incomingGroups = {
        inspection: isInspection(request.job_categories || []),
        troubleshooting: isTroubleshooting(request.job_categories || []),
        reAndRe: isReAndRe(request.job_categories || []) || 
                 (request.work_requested?.toLowerCase().includes('repairs and replacement') || false) ||
                 (request.work_requested?.toLowerCase() === 'r&r'),
        ductCleaning: isDuctCleaning(request.job_categories || [])
      };

      for (const doc of sortedDocs) {
        const data = doc.data();
        if (!data.created_at || !data.property_address) continue;
        
        const normExisting = normalizeAddress(data.property_address);
        if (normExisting !== normalizedTargetAddress && 
            !normExisting.includes(normalizedTargetAddress) && 
            !normalizedTargetAddress.includes(normExisting)) {
          continue; 
        }

        const createdAt = (data.created_at as admin.firestore.Timestamp).toDate();
        const existingCategories = data.job_categories || [];

        // MERGE RULE: If same job type exists, hasn't been invoiced, and within 30 days.
        if (createdAt > thirtyDaysAgo && data.status !== 'invoiced' && !data.qbo_invoice_id) {
          let typeConflict = '';
          if (incomingGroups.inspection && isInspection(existingCategories)) typeConflict = 'Inspection';
          else if (incomingGroups.troubleshooting && isTroubleshooting(existingCategories)) typeConflict = 'Troubleshooting';
          else if (incomingGroups.reAndRe && isReAndRe(existingCategories)) typeConflict = 'Repairs and Replacement';
          else if (incomingGroups.ductCleaning && isDuctCleaning(existingCategories)) typeConflict = 'Duct Cleaning';

          if (typeConflict) {
            targetExistingLeadId = doc.id;
            targetExistingLeadData = data;
            break;
          }

          // Special R&R Merge Rule
          if (incomingGroups.reAndRe && isReAndRe(existingCategories)) {
            targetExistingLeadId = doc.id;
            targetExistingLeadData = data;
            break;
          }
        }
      }
    } catch (mergeCheckError) {
      console.warn('[Intake] Merge check failed (non-critical):', mergeCheckError);
    }
  }

  if (targetExistingLeadId && targetExistingLeadData) {
    console.log(`[Intake] AUTO-MERGE: Appending to existing lead ${targetExistingLeadId}`);
    
    const dateStr = new Date().toLocaleDateString('en-US', { timeZone: 'America/Toronto' });
    const newScope = (targetExistingLeadData.scope_details || '') + 
                     `\n\n--- ADDITIONAL SCOPE APPENDED (${dateStr}) ---\n` +
                     (request.scope_details || 'Additional work requested.');
    
    let newQboLineItems = targetExistingLeadData.qbo_line_items || [];
    if (request.qbo_line_items && request.qbo_line_items.length > 0) {
      newQboLineItems = [...newQboLineItems, ...request.qbo_line_items];
    }

    let newCategories = targetExistingLeadData.job_categories || [];
    if (request.job_categories && request.job_categories.length > 0) {
      const combined = [...newCategories, ...request.job_categories];
      newCategories = Array.from(new Set(combined)); 
    }

    await admin.firestore().collection('leads').doc(targetExistingLeadId).update({
      scope_details: newScope,
      qbo_line_items: newQboLineItems,
      job_categories: newCategories,
      updated_at: admin.firestore.FieldValue.serverTimestamp()
    });

    // Notify team
    try {
      const { sendEmail } = require('../services/email');
      await sendEmail({
        to: 'nicole@immediateresponsehvac.ca, admin@immediateresponsehvac.ca, tyler@immediateresponsehvac.ca',
        subject: `ℹ️ AUTO-MERGED ADDITIONAL SCOPE: ${request.property_address}`,
        body: `
          <h2>Additional Scope Automatically Merged</h2>
          <p>A manual intake request for <strong>${request.property_address}</strong> matched an existing active lead of the same job type.</p>
          <p>Instead of creating a new duplicate lead, the system automatically appended the new scope and items to the existing active job.</p>
          <p><strong>Appended Scope:</strong><br>${request.scope_details || 'N/A'}</p>
          <p><a href="https://console.firebase.google.com/project/immediate-response-ai-b18b8/firestore/data/~2Fleads~2F${targetExistingLeadId}">View Lead in Database</a></p>
        `
      });
    } catch (e) {
      console.warn('[Intake] Failed to send merge notification email:', e);
    }

    return {
      success: true,
      lead_id: targetExistingLeadId,
      drive_folder_url: targetExistingLeadData.drive_folder_url || '',
      calendar_event_url: targetExistingLeadData.calendar_event_url || ''
    };
  }

  const leadId = uuidv4();
  console.log(`Lead ID: ${leadId}`);

  // Auto-fill PO Number from Memory Bank if missing
  if (!request.po_number && request.property_address) {
    try {
      const addressKey = request.property_address.toLowerCase().trim();
      const memRef = admin.firestore().collection('client_po_memory');
      const memQuery = await memRef.where('property_address', '==', addressKey).get();
      if (!memQuery.empty) {
        request.po_number = memQuery.docs[0].data().po_number;
        console.log(`🧠 PO Memory Bank active: auto-filled PO ${request.po_number} for ${addressKey}`);
      }
    } catch (e: any) {
      console.warn(`[PO Memory] Failed to lookup PO for ${request.property_address}:`, e.message);
    }
  }

  // PRIORITY #1: SEND EMAIL NOTIFICATION IMMEDIATELY
  if (!request.is_bid_or_tender && request.automated_email !== false) {
    try {
      await sendCustomerConfirmationEmail(request);
      console.log('✅ Email notification sent');
    } catch (emailError) {
      await logError('LeadIntake:Email', emailError, { leadId, clientEmail: request.client_email });
    }
  } else {
    console.log('🔇 Skipping customer confirmation email.');
  }

  // PRIORITY #1.5: Fixed Schedule Notification
  try {
    if (request.visit_status === 'Confirmed date' && request.visit_requested) {
      console.log('📅 Fixed schedule detected. Sending notification to Nicole.');
      await sendFixedScheduleNotificationEmail(request);
    }
  } catch (fixedEmailError) {
    console.error('❌ Failed to send fixed schedule notification:', fixedEmailError);
  }
  
  // BACKGROUND OPERATIONS (Firestore, Drive, Calendar)
  let pmId: string | null = null;
  let driveFolder: any = null;
  let calendarEvent: any = null;

  // Step 2: Upsert PM if insurance job
  if (isInsuranceJob(request.job_type) && request.pm) {
    try {
      const pmData = request.pm;
      let pmRef: admin.firestore.DocumentReference | null = null;
      let existingPmId: string | null = null;

      // 1. Try by pm_id first (most reliable)
      if (pmData.pm_id) {
        const doc = await admin.firestore().collection('pms').doc(pmData.pm_id).get();
        if (doc.exists) {
          pmRef = doc.ref;
          existingPmId = doc.id;
        }
      }

      // 2. Try by email if not found and email exists
      if (!pmRef && pmData.email && pmData.email !== 'N/A') {
        const emailQuery = await admin.firestore().collection('pms')
          .where('email', '==', pmData.email)
          .limit(1)
          .get();
        if (!emailQuery.empty) {
          pmRef = emailQuery.docs[0].ref;
          existingPmId = emailQuery.docs[0].id;
        }
      }

      // 3. Try by full_name and company_name as fallback
      if (!pmRef) {
        const nameQuery = await admin.firestore().collection('pms')
          .where('full_name', '==', pmData.full_name)
          .where('company_name', '==', pmData.company_name || '')
          .limit(1)
          .get();
        if (!nameQuery.empty) {
          pmRef = nameQuery.docs[0].ref;
          existingPmId = nameQuery.docs[0].id;
        }
      }

      if (pmRef && existingPmId) {
        pmId = existingPmId;

        // Enrich request.pm with database info if missing (ensures notifications/QBO have full info)
        try {
          const pmDoc = await pmRef.get();
          if (pmDoc.exists && request.pm) {
            const dbPm = pmDoc.data() || {};
            request.pm.billing_address = request.pm.billing_address || dbPm.billing_address;
            request.pm.cell_phone = request.pm.cell_phone || dbPm.cell_phone;
            request.pm.email = request.pm.email || dbPm.email;
            request.pm.company_name = request.pm.company_name || dbPm.company_name;
            request.pm.assistant_emails = request.pm.assistant_emails || dbPm.assistant_emails;
            request.pm.billing_emails = request.pm.billing_emails || dbPm.billing_emails;
          }
        } catch (e) {
          console.warn('[LeadIntake] PM enrichment failed:', e);
        }

        // Only update PM if explicitly requested
        if (request.update_pm) {
          const pmRecord: any = {
            full_name: pmData.full_name,
            last_updated: admin.firestore.FieldValue.serverTimestamp(),
          };
          if (pmData.company_name) pmRecord.company_name = pmData.company_name;
          if (pmData.email) pmRecord.email = pmData.email;
          if (pmData.cell_phone) pmRecord.cell_phone = pmData.cell_phone;
          if (pmData.billing_address) pmRecord.billing_address = pmData.billing_address;
          
          if (pmData.assistant_emails !== undefined) {
            pmRecord.assistant_emails = (pmData.assistant_emails?.trim() === '') ? admin.firestore.FieldValue.delete() : pmData.assistant_emails;
          }
          if (pmData.billing_emails !== undefined) {
            pmRecord.billing_emails = (pmData.billing_emails?.trim() === '') ? admin.firestore.FieldValue.delete() : pmData.billing_emails;
          }

          await pmRef.set(pmRecord, { merge: true });
          console.log(`✅ PM record updated: ${pmId}`);
        }
      } else {
        const newPm = await admin.firestore().collection('pms').add({
          full_name: pmData.full_name,
          company_name: pmData.company_name || '',
          email: pmData.email || null,
          cell_phone: pmData.cell_phone || '',
          billing_address: pmData.billing_address || '',
          assistant_emails: pmData.assistant_emails || null,
          billing_emails: pmData.billing_emails || null,
          last_updated: admin.firestore.FieldValue.serverTimestamp(),
        });
        pmId = newPm.id;
      }
      console.log(`✅ PM managed: ${pmId}`);
    } catch (pmError) {
      await logError('LeadIntake:PM', pmError, { pmData: request.pm });
    }
  }

  // Step 3: Create Drive folder
  try {
    if (request.is_call_back) {
      console.log(`🔄 Call Back detected for ${request.property_address}. Searching for previous Drive folder...`);
      // Find the existing drive folder using the same logic we use to find previous leads
      // Since property_address can vary slightly, a strict where might miss it.
      // So let's do a broad fetch and substring match like in handleLeadSearchByAddress.
      const previousLeadsSnapshot = await admin.firestore().collection('leads')
        .orderBy('created_at', 'desc')
        .limit(200)
        .get();

      if (!previousLeadsSnapshot.empty) {
        const exactDoc = previousLeadsSnapshot.docs.find(doc => doc.data().property_address === request.property_address && doc.data().drive_folder_id);
        const match = exactDoc?.data();

        if (match) {
          if (match.drive_folder_id) {
            driveFolder = {
              folderId: match.drive_folder_id,
              folderUrl: match.drive_folder_url || `https://drive.google.com/drive/folders/${match.drive_folder_id}`
            };
            console.log(`✅ Call Back: Reusing existing Drive folder: ${driveFolder.folderId}`);
          }
          
          // Store original technician info for callback reporting
          (request as any).original_technician = match.technician || null;
          (request as any).original_technician_email = match.technician_email || null;
          (request as any).original_lead_id = match.lead_id || exactDoc?.id;
        } else {
          // Fallback to substring matching if exact match fails
          const fallbackDoc = previousLeadsSnapshot.docs.find(doc => {
            const prop = (doc.data().property_address || '').toLowerCase();
            return prop.includes(request.property_address.toLowerCase().trim()) && (doc.data().drive_folder_id || doc.data().technician);
          });
          const fallbackMatch = fallbackDoc?.data();
          if (fallbackMatch) {
            if (fallbackMatch.drive_folder_id) {
              driveFolder = {
                folderId: fallbackMatch.drive_folder_id,
                folderUrl: fallbackMatch.drive_folder_url || `https://drive.google.com/drive/folders/${fallbackMatch.drive_folder_id}`
              };
              console.log(`✅ Call Back: Reusing existing Drive folder (fuzzy match): ${driveFolder.folderId}`);
            }
            // Store original technician info
            (request as any).original_technician = fallbackMatch.technician || null;
            (request as any).original_technician_email = fallbackMatch.technician_email || null;
            (request as any).original_lead_id = fallbackMatch.lead_id || fallbackDoc?.id;
          }
        }
      }
      if (!driveFolder) {
        console.log(`⚠️ Previous Drive folder not found for Call Back. Creating a new one.`);
      }
    }

    if (!driveFolder) {
      driveFolder = await createLeadFolderStructure({
        propertyAddress: request.property_address,
        pmName: request.pm?.full_name || null,
        pmCompany: request.pm?.company_name || null,
        clientName: request.client_name,
        jobCategories: request.job_categories,
        distanceMetres: request.distance_metres,
        td4Required: request.td4_required,
      });
      console.log(`✅ Drive folder created: ${driveFolder.folderId}`);
    }

    // Upload supporting documents if any
    if (request.supporting_docs && request.supporting_docs.length > 0 && driveFolder.folderId) {
      console.log(`📤 Uploading ${request.supporting_docs.length} supporting document(s)...`);
      for (const file of request.supporting_docs) {
        try {
          await uploadFileToFolder(driveFolder.folderId, file.name, file.data, file.mime_type);
          console.log(`   ✅ Uploaded: ${file.name}`);
        } catch (uploadError) {
          console.error(`   ❌ Failed to upload ${file.name}:`, uploadError);
        }
      }
    }
  } catch (driveError) {
    await logError('LeadIntake:Drive', driveError, { leadId, propertyAddress: request.property_address });
    driveFolder = { folderId: null, folderUrl: 'Pending' };
  }

  // Step 4: Create Calendar event
  if (request.calendar_event !== false) {
    try {
      // For Bid/Tender, ensure it's treated as an actionable quote to schedule Tyler & Cory
      if (request.is_bid_or_tender) {
        console.log(`[Lead Intake] Silent Lead (Bid/Tender) detected. Forcing actionable quote status for internal scheduling.`);
        request.has_actionable_quote_details = true;
      }

      calendarEvent = await createLeadCalendarEvent({
        propertyAddress: request.property_address,
        apartmentNumber: request.apartment_number,
        clientName: request.client_name,
        clientEmail: request.client_email,
        clientPhone: request.client_cell,
        pmName: request.pm?.full_name,
        pmEmail: request.pm?.email,
        pmPhone: request.pm?.cell_phone,
        pmCompany: request.pm?.company_name,
        jobCategories: request.job_categories,
        claimType: request.claim_type,
        jobType: request.job_type,
        scopeDetails: request.scope_details,
        visitRequested: request.visit_requested,
        visitEnd: request.visit_end || null,
        visitStatus: request.visit_status || null,
        jobDuration: request.job_duration,
        includeWeekends: request.include_weekends,
        accessInstructions: request.access_instructions,
        lockboxCode: request.lockbox_code,
        driveFolderUrl: driveFolder?.folderUrl || 'Pending',
        driveFolderId: driveFolder?.folderId || '', // Ensure non-nullable for Calendar service
        emergencyDispatch: request.emergency_dispatch,
        applianceCount: request.appliance_count,
        applianceList: request.appliance_list,
        equipmentType: request.equipment_type,
        fuelType: request.fuel_type,
        hasActionableQuoteDetails: request.has_actionable_quote_details,
      });
      console.log(`✅ Calendar event created: ${calendarEvent.eventId}`);
    } catch (calendarError) {
      await logError('LeadIntake:Calendar', calendarError, { leadId, propertyAddress: request.property_address });
      calendarEvent = { eventId: null, htmlLink: 'Pending' };
    }
  } else {
    console.log('🔇 Calendar Event skipped via toggle preference.');
    calendarEvent = { eventId: null, htmlLink: 'Skipped' };
  }

  // Step 4.5: Travel Notification for Nicole
  if (driveFolder?.isSpecialWorkSite && driveFolder?.distanceMetres) {
    try {
      await sendTravelNotificationEmail({
        propertyAddress: request.property_address,
        distanceKm: (driveFolder.distanceMetres / 1000).toFixed(2),
        driveFolderUrl: driveFolder.folderUrl,
        calendarEventUrl: calendarEvent?.htmlLink,
        jobId: leadId.substring(0, 8),
        clientName: request.client_name,
        td4Required: request.td4_required,
      });
      console.log(`✅ Travel notification email sent to Nicole`);
    } catch (travelEmailError) {
      console.error(`❌ Failed to send travel notification email:`, travelEmailError);
    }
  }

  // Step 4.6: Actionable Quote Notification for Tyler & Cory
  if (request.has_actionable_quote_details && driveFolder?.folderUrl) {
    try {
      const { sendActionableQuoteNotificationEmail } = require('../services/email');
      await sendActionableQuoteNotificationEmail(request, driveFolder.folderUrl, leadId);
      console.log(`✅ Actionable Quote notification email sent to Tyler & Cory`);
    } catch (quoteEmailError) {
      console.error(`❌ Failed to send Actionable Quote notification email:`, quoteEmailError);
    }
  }

    // Step 5: Save to Firestore
  try {
    const finalBillingAddress = (isInsuranceJob(request.job_type) && request.pm?.billing_address)
      ? request.pm.billing_address
      : request.property_address;

    // IMPORTANT: Clean up the request object for Firestore.
    // Base64 images in supporting_docs can exceed the 1MB document limit.
    let firestoreData: any = { ...request };
    if (firestoreData.supporting_docs) {
      delete firestoreData.supporting_docs;
    }

    // Sanitize data to prevent Firestore "Unsupported field value: undefined" errors
    firestoreData = replaceUndefinedWithNull(firestoreData);

    // Determine initial status and assignments
    let status = 'not-scheduled';
    if (request.visit_status === 'Quote Only (No Visit)') {
      status = 'quote-to-be-sent';
    }
    
    let technicians: string | null = null;
    let technicianEmails: string | null = null;

    if (request.has_actionable_quote_details) {
      console.log(`[Lead Intake] Actionable Quote detected. Auto-assigning Tyler & Cory and setting status to scheduled.`);
      status = 'scheduled';
      technicians = 'Tyler & Cory';
      technicianEmails = 'tyler@immediateresponsehvac.ca, cory@immediateresponsehvac.ca';
    }

    const docPayload = replaceUndefinedWithNull({
      ...firestoreData,
      lead_id: leadId,
      pm_id: pmId,
      assistant_emails: request.pm?.assistant_emails || null,
      billing_emails: request.pm?.billing_emails || null,
      final_billing_address: finalBillingAddress,
      drive_folder_id: driveFolder?.folderId || null,
      drive_folder_url: driveFolder?.folderUrl || null,
      reports_folder_id: driveFolder?.reportsFolderId || null,
      inspection_photos_folder_id: driveFolder?.inspectionPhotosFolderId || null,
      post_job_photos_folder_id: driveFolder?.postJobPhotosFolderId || null,
      purchase_orders_folder_id: driveFolder?.purchaseOrdersFolderId || null,
      profit_and_loss_folder_id: driveFolder?.profitAndLossFolderId || null,
      profit_and_loss_sheet_id: driveFolder?.profitAndLossSheetId || null,
      calendar_event_id: calendarEvent?.eventId || null,
      calendar_event_url: calendarEvent?.htmlLink || null,
      job_duration: request.job_duration || 1,
      include_weekends: request.include_weekends !== false,
      submitted_by: request.submitted_by || 'Unknown',
      status: status,
      technician: technicians,
      technician_email: technicianEmails,
      scheduled_time: status === 'scheduled' ? (request.visit_requested || null) : null,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
    });

    await admin.firestore().collection('leads').doc(leadId).set(docPayload);
    console.log(`✅ Lead saved to Firestore: ${leadId} (Status: ${status})`);

    // Step 6: Auto-accept calendar event for technicians (Actionable Quotes)
    if (request.has_actionable_quote_details && calendarEvent?.eventId) {
      try {
        console.log(`[Lead Intake] Auto-accepting calendar event ${calendarEvent.eventId} for Tyler & Cory...`);
        await acceptEventForAttendee(calendarEvent.eventId, 'tyler@immediateresponsehvac.ca');
        await acceptEventForAttendee(calendarEvent.eventId, 'cory@immediateresponsehvac.ca');
        console.log(`✅ Calendar event auto-accepted for technicians`);
      } catch (acceptErr: any) {
        console.error(`❌ Failed to auto-accept calendar event (non-fatal):`, acceptErr?.message);
      }
    }
  } catch (firestoreError: any) {
    await logError('LeadIntake:Firestore', firestoreError, { 
      leadId,
      requestPayload: JSON.parse(JSON.stringify(request)) // Deep clone to avoid circular refs or weirdness
    });
    return {
      success: false,
      lead_id: leadId,
      drive_folder_url: driveFolder?.folderUrl || 'Failed',
      calendar_event_url: calendarEvent?.htmlLink || 'Failed',
      message: `Failed to save lead to database: ${firestoreError?.message || 'Unknown error'}`,
    };
  }


  return {
    success: true,
    lead_id: leadId,
    drive_folder_url: driveFolder?.folderUrl || 'Pending',
    calendar_event_url: calendarEvent?.htmlLink || 'Pending',
    purchase_orders_folder_id: driveFolder?.purchaseOrdersFolderId || undefined,
    message: 'Lead received - Confirmation email sent.',
  };
}

/**
 * Handle Manual Intake (Callable)
 * Creates a Drive folder and standard active project record with no email.
 */
export async function handleManualIntake(data: any): Promise<any> {
  console.log('========================================');
  console.log('MANUAL INTAKE STARTED (Callable)');
  console.log('Payload:', JSON.stringify(data));
  console.log('========================================');

  const { propertyAddress, claimRef, technicianEmail } = data;
  if (!propertyAddress || !claimRef) {
    throw new Error('propertyAddress and claimRef are required.');
  }

  const leadId = uuidv4();
  let driveFolder: any = null;

  try {
    driveFolder = await createLeadFolderStructure({
      propertyAddress: propertyAddress,
      pmName: claimRef, // use claimRef as a folder suffix
      pmCompany: null,
      clientName: 'Manual Intake',
      jobCategories: [],
    });
    console.log(`✅ Drive folder created: ${driveFolder.folderId}`);
  } catch (driveError) {
    await logError('ManualIntake:Drive', driveError, { leadId, propertyAddress });
    driveFolder = { folderId: null, folderUrl: 'Pending' };
  }

  try {
    const docPayload = replaceUndefinedWithNull({
      lead_id: leadId,
      property_address: propertyAddress,
      claim_reference: claimRef,
      status: 'active',
      drive_folder_id: driveFolder?.folderId || null,
      drive_folder_url: driveFolder?.folderUrl || null,
      reports_folder_id: driveFolder?.reportsFolderId || null,
      inspection_photos_folder_id: driveFolder?.inspectionPhotosFolderId || null,
      post_job_photos_folder_id: driveFolder?.postJobPhotosFolderId || null,
      purchase_orders_folder_id: driveFolder?.purchaseOrdersFolderId || null,
      profit_and_loss_folder_id: driveFolder?.profitAndLossFolderId || null,
      profit_and_loss_sheet_id: driveFolder?.profitAndLossSheetId || null,
      created_at: admin.firestore.FieldValue.serverTimestamp(),
      is_manual_intake: true,
      job_type: 'Residential',
      technician_email: technicianEmail || null,
      technician: technicianEmail ? technicianEmail.split('@')[0] : null,
    });

    await admin.firestore().collection('leads').doc(leadId).set(docPayload);
    console.log(`✅ Manual Lead saved to Firestore: ${leadId} assigned to ${technicianEmail}`);
  } catch (firestoreError: any) {
    await logError('ManualIntake:Firestore', firestoreError, { leadId });
    throw new Error(`Failed to save manual lead: ${firestoreError?.message || 'Unknown error'}`);
  }

  return {
    success: true,
    lead_id: leadId,
    drive_folder_url: driveFolder?.folderUrl || 'Pending',
    message: 'Manual Forensic Project Created.',
  };
}

/**
 * Handle PM search by name
 */
export async function handlePMSearch(query: string): Promise<PMSearchResponse> {
  console.log(`Searching for PM: ${query}`);
  try {
    const db = admin.firestore();
    const pmsRef = db.collection('pms');
    let results: admin.firestore.QuerySnapshot;

    // If query looks like an email, search by email AND assistant_emails
    if (query.includes('@')) {
      const email = query.toLowerCase().trim();
      
      // Try primary email
      const primaryResults = await pmsRef.where('email', '==', email).limit(5).get();
      if (!primaryResults.empty) {
        return {
          results: primaryResults.docs.map(doc => ({ pm_id: doc.id, ...doc.data() })) as ProjectManager[]
        };
      }
      
      // Try assistant emails (this is a simple equality check; for comma-separated lists, we'd need more complex logic, 
      // but usually the sender is just one of the emails). 
      // Note: Firestore 'array-contains' only works if assistant_emails was an array.
      // Since it's a string, we might need a manual filter if it's a comma-separated list.
      const allPms = await pmsRef.get();
      const filtered = allPms.docs.filter(doc => {
        const data = doc.data();
        const assistants = (data.assistant_emails || '').toLowerCase();
        return assistants.includes(email);
      }).slice(0, 5);

      if (filtered.length > 0) {
        return {
          results: filtered.map(doc => ({ pm_id: doc.id, ...doc.data() })) as ProjectManager[]
        };
      }

      return { results: [] };
    }

    // Otherwise, default to name prefix search
    results = await pmsRef
      .where('full_name', '>=', query)
      .where('full_name', '<=', query + '\uf8ff')
      .limit(10)
      .get();

    return {
      results: results.docs.map(doc => ({
        pm_id: doc.id,
        ...doc.data()
      })) as ProjectManager[]
    };
  } catch (error) {
    console.error('PM search error:', error);
    return { results: [] };
  }
}

/**
 * Handle Lead search by address (Public)
 * Returns the most recent lead matching the exact address to auto-populate the form for additional work.
 */
export async function handleLeadSearchByAddress(address: string, baseAddress?: string): Promise<any> {
  console.log(`Searching for Lead by exact address: ${address} or baseAddress: ${baseAddress}`);
  try {
    // We grab the last 200 leads and perform an in-memory string search. 
    // This makes the search vastly more resilient to unit number formatting differences 
    // (e.g. "6 - 123 Main St" vs "6-123 Main St") and bypasses strict Firestore equality matching.
    const results = await admin.firestore().collection('leads')
      .orderBy('created_at', 'desc')
      .limit(200)
      .get();
      
    if (results.empty) {
      return { success: true, result: null };
    }

    let match = null;
    
    // 1. Try exact match first
    const exactDoc = results.docs.find(doc => doc.data().property_address === address);
    if (exactDoc) {
      match = exactDoc.data();
    } 
    // 2. Try baseAddress substring match (e.g. finding "1771 Hunters..." inside "6-1771 Hunters...")
    else if (baseAddress && baseAddress.trim().length > 5) {
      const baseDoc = results.docs.find(doc => {
        const property = (doc.data().property_address || '').toLowerCase();
        return property.includes(baseAddress.toLowerCase().trim());
      });
      if (baseDoc) match = baseDoc.data();
    }
    // 3. Fallback: Try substring match with whatever 'address' is provided
    else {
      const fallbackDoc = results.docs.find(doc => {
        const property = (doc.data().property_address || '').toLowerCase();
        return property.includes(address.toLowerCase().trim());
      });
      if (fallbackDoc) match = fallbackDoc.data();
    }

    if (!match) {
      return { success: true, result: null };
    }
    
    return {
      success: true,
      result: {
        client_name: match.client_name || null,
        client_email: match.client_email || null,
        client_cell: match.client_cell || null,
        pm: match.pm || null,
        job_type: match.job_type || null,
        claim_type: match.claim_type || null
      }
    };
  } catch (error: any) {
    console.error('Lead search by address error:', error);
    return { success: false, error: error.message || 'Failed to search by address' };
  }
}

/**
 * Handle Lead search by client name (Public)
 * Returns the most recent lead matching the client name to auto-populate the form for additional work.
 */
export async function handleLeadSearchByClientName(clientName: string): Promise<any> {
  console.log(`Searching for Lead by client name: ${clientName}`);
  try {
    const results = await admin.firestore().collection('leads')
      .orderBy('created_at', 'desc')
      .limit(200)
      .get();
      
    if (results.empty) {
      return { success: true, result: null };
    }

    // Substring match on client_name
    const matchDoc = results.docs.find(doc => {
      const name = (doc.data().client_name || '').toLowerCase();
      return name.includes(clientName.toLowerCase().trim());
    });

    if (!matchDoc) {
      return { success: true, result: null };
    }
    
    const match = matchDoc.data();
    
    return {
      success: true,
      result: {
        client_name: match.client_name || null,
        client_email: match.client_email || null,
        client_cell: match.client_cell || null,
        pm: match.pm || null,
        job_type: match.job_type || null,
        claim_type: match.claim_type || null,
        property_address: match.property_address || null
      }
    };
  } catch (error: any) {
    console.error('Lead search by client name error:', error);
    return { success: false, error: error.message || 'Failed to search by client name' };
  }
}

/**
 * Handle manual retry for failed Drive, Calendar, or QBO Syncs
 */
export async function handleLeadRetry(leadId: string): Promise<{ success: boolean; message: string; details: any }> {
  console.log(`[Retry] Starting manual retry for lead: ${leadId}`);
  
  const leadDoc = await admin.firestore().collection('leads').doc(leadId).get();
  if (!leadDoc.exists) {
    throw new Error(`Lead ${leadId} not found`);
  }
  
  const leadData = leadDoc.data()!;
  const updates: any = {};
  const details: any = { drive: 'ok', calendar: 'ok', qbo: 'ok' };
  
  // 1. Check for Drive Folder
  let driveFolderId = leadData.drive_folder_id;
  if (!driveFolderId) {
    console.log(`[Retry] Missing Drive Folder. Attempting creation...`);
    try {
      const driveFolder = await createLeadFolderStructure({
        propertyAddress: leadData.property_address || '',
        pmName: leadData.pm?.full_name || null,
        clientName: leadData.client_name || '',
        jobCategories: leadData.job_categories || [],
      });
      driveFolderId = driveFolder.folderId;
      updates.drive_folder_id = driveFolder.folderId;
      updates.drive_folder_url = driveFolder.folderUrl;
      updates.purchase_orders_folder_id = driveFolder.purchaseOrdersFolderId;
      details.drive = 'created';
    } catch (e: any) {
      console.error(`[Retry] Drive folder creation failed:`, e);
      details.drive = `failed: ${e.message}`;
    }
  }

  // 2. Check for Calendar Event
  let calendarEventId = leadData.calendar_event_id;
  if (!calendarEventId) {
    if (leadData.is_bid_or_tender) {
      console.log(`[Retry] Silent Lead (Bid/Tender) detected. Forcing actionable quote status for internal scheduling.`);
      leadData.has_actionable_quote_details = true;
    }
    
    console.log(`[Retry] Missing Calendar Event. Attempting creation...`);
    try {
      const calendarEvent = await createLeadCalendarEvent({
        propertyAddress: leadData.property_address || '',
        apartmentNumber: leadData.apartment_number || null,
        clientName: leadData.client_name || '',
        clientEmail: leadData.client_email || null,
        clientPhone: leadData.client_cell || null,
        pmName: leadData.pm?.full_name || null,
        pmEmail: leadData.pm?.email || null,
        pmPhone: leadData.pm?.cell_phone || null,
        pmCompany: leadData.pm?.company_name || null,
        jobCategories: leadData.job_categories || [],
        claimType: leadData.claim_type || null,
        jobType: leadData.job_type || null,
        scopeDetails: leadData.scope_details || '',
        visitRequested: leadData.visit_requested || '',
        visitEnd: leadData.visit_end || null,
        visitStatus: leadData.visit_status || null,
        accessInstructions: leadData.access_instructions || null,
        lockboxCode: leadData.lockbox_code || null,
        driveFolderUrl: updates.drive_folder_url || leadData.drive_folder_url || 'Pending',
        driveFolderId: driveFolderId || '',
        emergencyDispatch: leadData.emergency_dispatch || false,
        applianceCount: leadData.appliance_count || null,
        applianceList: leadData.appliance_list || null,
        equipmentType: leadData.equipment_type || null,
        fuelType: leadData.fuel_type || null,
        hasActionableQuoteDetails: leadData.has_actionable_quote_details || null,
      });
        calendarEventId = calendarEvent.eventId;
        updates.calendar_event_id = calendarEvent.eventId;
        updates.calendar_event_url = calendarEvent.htmlLink;
        details.calendar = 'created';
      } catch (e: any) {
        console.error(`[Retry] Calendar event creation failed:`, e);
        details.calendar = `failed: ${e.message}`;
      }
  }

  // Save Drive/Calendar updates before checking QBO so QBO uses correct URLs
  if (Object.keys(updates).length > 0) {
    await leadDoc.ref.update(updates);
    Object.assign(leadData, updates);
  }

  // 3. Check for QBO Sync
  if (!leadData.qbo_project_id || !leadData.qbo_estimate_id || leadData.qbo_sync_error) {
    console.log(`[Retry] Missing or failed QBO objects. Attempting handleLeadToQbo...`);
    try {
      // Dynamic import to prevent circular dependency issues
      const qboSync = await import('./qbo-sync');
      
      // Clear previous error if it exists before trying
      if (leadData.qbo_sync_error) {
        await leadDoc.ref.update({ qbo_sync_error: admin.firestore.FieldValue.delete() });
      }
      
      await qboSync.handleLeadToQbo(leadId, leadData);
      details.qbo = 'synced';
    } catch (e: any) {
      console.error(`[Retry] QBO sync failed:`, e);
      details.qbo = `failed: ${e.message}`;
    }
  }

  return {
    success: true,
    message: 'Retry operations completed',
    details,
  };
}

