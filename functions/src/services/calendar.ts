/**
 * Google Calendar Service
 * Handles calendar event creation for HVAC lead intake
 * 
 * Events are created on the 'Ghost' calendar with Drive folder attached
 * Calendar ID: c_82f31464fae8eeb8fd1cee1af6675655ffc9456594b656b049cc061323199f35
 */

import { google, calendar_v3 } from 'googleapis';
import { config, gmailServiceAccountKey } from '../config/index';
import { parseLocalDateTime, resolveRelativeDate } from '../utils/index';


// Types
export interface CreateEventParams {
  propertyAddress: string;
  apartmentNumber?: string | null;
  clientName: string;
  clientEmail?: string | null;
  clientPhone?: string | null;
  pmName?: string | null;
  pmEmail?: string | null;
  pmPhone?: string | null;
  pmCompany?: string | null;
  jobCategories: string[];
  claimType?: string | null;
  jobType: string;
  scopeDetails?: string | null;
  visitRequested: Date | string;
  visitEnd?: Date | string | null;
  visitStatus?: string | null; // 'To Be Scheduled' or 'Confirmed date'
  accessInstructions?: string | null;
  lockboxCode?: string | null;
  gateCode?: string | null;
  driveFolderUrl: string;
  driveFolderId: string;
  emergencyDispatch?: boolean;
  isScheduled?: boolean;
  applianceCount?: string | null;
  applianceList?: string | null;
  equipmentType?: string | null;
  fuelType?: string | null;
  quotedAmount?: number | null;
  jobDuration?: number;
  includeWeekends?: boolean;
  hasActionableQuoteDetails?: boolean | null;
  selectedAttendees?: string[];
}

export interface CalendarEvent {
  eventId: string;
  eventUrl: string;
  htmlLink: string;
}

// User to impersonate for domain-wide delegation
const IMPERSONATE_USER = 'admin@immediateresponsehvac.ca';

// Initialize Calendar client with domain-wide delegation
// Uses the same JWT pattern as getDriveClient() — subject must be set at construction time.
export async function getCalendarClient(): Promise<calendar_v3.Calendar> {

  const secretValue = gmailServiceAccountKey.value();
  if (!secretValue) {
    throw new Error('GMAIL_SERVICE_ACCOUNT_KEY secret is not available');
  }

  // Remove possible UTF-8 BOM (0xFEFF) that can cause JSON.parse to fail
  const cleaned = secretValue.charCodeAt(0) === 0xFEFF ? secretValue.slice(1) : secretValue;
  const creds = JSON.parse(cleaned);

  const client = new google.auth.JWT({
    email: creds.client_email,
    key: creds.private_key,
    scopes: ['https://www.googleapis.com/auth/calendar'],
    subject: IMPERSONATE_USER,
  });

  return google.calendar({ version: 'v3', auth: client as any });
}

// Marker for unscheduled events - Nicole removes this when assigning a tech
export const UNSCHEDULED_MARKER = '[UNSCHEDULED]';

/**
 * Search the Ghost Calendar for an existing event matching a property address.
 * Returns the first matching event, or null if none found.
 * Used to prevent duplicate events being created for the same lead.
 */
export async function findExistingCalendarEvent(
  propertyAddress: string
): Promise<{ eventId: string; eventUrl: string } | null> {
  try {
    const calendar = await getCalendarClient();
    // Search within a wide window — ±6 months
    const timeMin = new Date(Date.now() - 180 * 24 * 60 * 60 * 1000).toISOString();
    const timeMax = new Date(Date.now() + 180 * 24 * 60 * 60 * 1000).toISOString();

    // Use the street number + street name as a search key (robust against formatting differences)
    const searchKey = propertyAddress.split(',')[0].trim();

    const resp = await calendar.events.list({
      calendarId: config.calendar.ghostCalendarId,
      q: searchKey,
      maxResults: 5,
      singleEvents: true,
      timeMin,
      timeMax,
    });

    const events = resp.data.items || [];
    if (events.length === 0) return null;

    // Match against the address more precisely to avoid false positives
    const match = events.find(e =>
      e.summary?.toLowerCase().includes(searchKey.toLowerCase()) && e.id
    );

    if (!match || !match.id || !match.htmlLink) return null;

    console.log(`[Calendar] Found existing event for "${searchKey}": ${match.id} — "${match.summary}"`);
    return { eventId: match.id, eventUrl: match.htmlLink };
  } catch (err: any) {
    console.warn(`[Calendar] findExistingCalendarEvent failed (non-fatal):`, err.message);
    return null;
  }
}

/**
 * Validates that a stored calendar_event_id actually exists in Google Calendar.
 * If not, searches for the real event by address and updates Firestore automatically.
 * Returns the correct, verified event ID to use.
 *
 * This self-heals the case where Firestore stores an orphaned/wrong event ID,
 * which previously caused all updates to silently target an invisible event.
 */
export async function resolveCalendarEventId(
  storedEventId: string,
  propertyAddress: string,
  leadId?: string
): Promise<string> {
  const calendar = await getCalendarClient();

  // 1. Check if the stored ID is valid
  try {
    const check = await calendar.events.get({
      calendarId: config.calendar.ghostCalendarId,
      eventId: storedEventId,
    });
    if (check.data.id) {
      return storedEventId; // All good — stored ID is valid
    }
  } catch (err: any) {
    console.warn(`[Calendar] Stored event ID "${storedEventId}" is invalid (${err.message}). Searching by address...`);
  }

  // 2. Stored ID is bad — find the real event
  const found = await findExistingCalendarEvent(propertyAddress);
  if (!found) {
    console.error(`[Calendar] Could not resolve calendar event for "${propertyAddress}". No matching event found.`);
    throw new Error(`Calendar event not found for "${propertyAddress}". Please check the Ghost Calendar manually.`);
  }

  // 3. Self-heal: update Firestore with the correct event ID
  if (leadId) {
    try {
      const { getFirestore } = await import('firebase-admin/firestore');
      const db = getFirestore();
      await db.collection('leads').doc(leadId).update({
        calendar_event_id: found.eventId,
        calendar_event_url: found.eventUrl,
        calendar_id_healed_at: new Date().toISOString(),
      });
      console.log(`[Calendar] ✅ Self-healed calendar_event_id for lead ${leadId}: ${storedEventId} → ${found.eventId}`);
    } catch (fsErr: any) {
      console.error(`[Calendar] Failed to self-heal Firestore for lead ${leadId}:`, fsErr.message);
    }
  }

  return found.eventId;
}

/**
 * Generate event title based on job details
 * Includes [UNSCHEDULED] marker - Nicole removes this when assigning a tech
 */
export function generateEventTitle(params: CreateEventParams): string {
  const jobTypeLabel = params.jobType.replace(/_/g, ' ');
  let prefix = '';
  if (params.emergencyDispatch) {
    prefix = 'URGENT: ';
  } else if (params.isScheduled || params.hasActionableQuoteDetails) {
    prefix = '[SCHEDULED] ';
  } else {
    prefix = UNSCHEDULED_MARKER + ' ';
  }
  const unitSuffix = params.apartmentNumber ? ` (Unit/Apt: ${params.apartmentNumber})` : '';
  return `${prefix}HVAC ${jobTypeLabel} - ${params.propertyAddress}${unitSuffix}`;
}

/**
 * Generate event description with all relevant job details
 */
export function generateEventDescription(params: CreateEventParams): string {
  const sections: string[] = [];

  // Header
  sections.push('🔧 HVAC SERVICE REQUEST');
  sections.push('═'.repeat(40));
  sections.push('');

  // Property Information
  sections.push('📍 PROPERTY INFORMATION');
  sections.push(`Address: ${params.propertyAddress}`);
  if (params.apartmentNumber) {
    sections.push(`Apartment/Unit: ${params.apartmentNumber}`);
  }
  sections.push('');

  // Job Details
  sections.push('📋 JOB DETAILS');
  sections.push(`Type: ${params.jobType.replace(/_/g, ' ')}`);
  if (params.claimType) {
    sections.push(`Claim Type: ${params.claimType}`);
  }
  sections.push(`Categories: ${params.jobCategories.join(', ')}`);
  if (params.visitStatus) {
    sections.push(`Status: ${params.visitStatus}`);
  }
  if (params.quotedAmount) {
    sections.push(`Quoted Amount: $${params.quotedAmount}`);
  }
  sections.push('');

  // Equipment/Appliance Info
  if (params.equipmentType || params.applianceCount) {
    sections.push('🛠️ EQUIPMENT & APPLIANCES');
    if (params.equipmentType) {
      sections.push(`Equipment: ${params.equipmentType}${params.fuelType ? ' (' + params.fuelType + ')' : ''}`);
    }
    if (params.applianceCount) {
      sections.push(`Appliance Count: ${params.applianceCount}`);
    }
    if (params.applianceList) {
      sections.push(`Appliance List: ${params.applianceList}`);
    }
    sections.push('');
  }

  // Scope
  if (params.scopeDetails) {
    sections.push('📝 SCOPE OF WORK');
    sections.push(params.scopeDetails);
    sections.push('');
  }

  // Client Information
  sections.push('👤 CLIENT INFORMATION');
  sections.push(`Name: ${params.clientName}`);
  if (params.clientEmail) {
    sections.push(`Email: ${params.clientEmail}`);
  }
  if (params.clientPhone) {
    sections.push(`Phone: ${params.clientPhone}`);
  }
  sections.push('');

  // PM Information (if insurance job)
  if (params.pmName) {
    sections.push('🏢 PROJECT MANAGER');
    sections.push(`Name: ${params.pmName}${params.pmCompany ? ' (' + params.pmCompany + ')' : ''}`);
    if (params.pmEmail) {
      sections.push(`Email: ${params.pmEmail}`);
    }
    if (params.pmPhone) {
      sections.push(`Phone: ${params.pmPhone}`);
    }
    sections.push('');
  }

  if (params.accessInstructions) {
    sections.push('🔑 ACCESS INSTRUCTIONS');
    sections.push(params.accessInstructions);
    if (params.lockboxCode) {
      sections.push(`Lockbox Code: ${params.lockboxCode}`);
    }
    if (params.gateCode) {
      sections.push(`Gate Code: ${params.gateCode}`);
    }
    sections.push('');
  }

  // Drive Folder Link
  sections.push('📁 DOCUMENTS & MEDIA');
  sections.push(`Drive Folder: ${params.driveFolderUrl}`);
  sections.push('');

  // Assigned Technicians (Actionable Quotes)
  if (params.hasActionableQuoteDetails) {
    sections.push('👷 ASSIGNED TECHNICIANS (QUOTES)');
    sections.push('Tyler (tyler@immediateresponsehvac.ca)');
    sections.push('Cory (cory@immediateresponsehvac.ca)');
    sections.push('');
  }

  // Assigned Technicians (Selected Attendees)
  if (params.selectedAttendees && params.selectedAttendees.length > 0) {
    sections.push('👷 ASSIGNED TECHNICIANS');
    params.selectedAttendees.forEach(email => {
      sections.push(`- ${email}`);
    });
    sections.push('');
  }

  return sections.join('\n');
}

/**
 * Build the list of event attendees
 * Includes client and PM (if applicable) emails
 * 
 * NOTE: Currently disabled - service accounts cannot invite attendees
 * without Domain-Wide Delegation. Contact info is in the description instead.
 */
// function buildAttendees(params: CreateEventParams): calendar_v3.Schema$EventAttendee[] {
//   const attendees: calendar_v3.Schema$EventAttendee[] = [];
//
//   // Add client email if provided
//   if (params.clientEmail) {
//     attendees.push({
//       email: params.clientEmail,
//       displayName: params.clientName,
//       responseStatus: 'needsAction',
//     });
//   }
//
//   // Add PM email if provided (insurance jobs)
//   if (params.pmEmail && params.pmName) {
//     attendees.push({
//       email: params.pmEmail,
//       displayName: params.pmName,
//       responseStatus: 'needsAction',
//     });
//   }
//
//   return attendees;
// }

/**
 * Calculate event end time (default 2 hours after start)
 */
function calculateEndTime(startTime: Date, durationHours: number = 2): Date {
  const endTime = new Date(startTime);
  endTime.setHours(endTime.getHours() + durationHours);
  return endTime;
}

/**
 * Create a calendar event for a lead on the Ghost calendar
 * 
 * Features:
 * - Creates event on Ghost calendar
 * - Color codes events based on visit status (Yellow = To Be Scheduled, Green = Confirmed)
 * - Sets time to 6am for "To Be Scheduled" events
 * - Attaches Drive folder as event attachment
 * - Includes full job details in description
 * 
 * @param params - Event creation parameters
 * @returns CalendarEvent object with event ID and URL
 */
/**
 * Computes start time, end time, and recurrence rules for a calendar event
 */
export function getEventTiming(params: CreateEventParams): { start: calendar_v3.Schema$EventDateTime; end: calendar_v3.Schema$EventDateTime; recurrence?: string[] | null } {
  let startTimeRaw = params.visitRequested;
  
  if (typeof startTimeRaw === 'string' && startTimeRaw !== '') {
    // If it's just a date (YYYY-MM-DD), append the 8:00 AM default time
    if (/^\d{4}-\d{2}-\d{2}$/.test(startTimeRaw)) {
      startTimeRaw = `${startTimeRaw}T08:00:00`;
    }
  }

  let startTime: Date | null = null;
  
  // Try relative date first (e.g. "next Tuesday")
  if (typeof startTimeRaw === 'string') {
    startTime = resolveRelativeDate(startTimeRaw);
  }

  // Fallback to standard parsing
  if (!startTime) {
    startTime = typeof startTimeRaw === 'string' 
      ? parseLocalDateTime(startTimeRaw) 
      : startTimeRaw;
  }
  
  if (!startTime || isNaN((startTime as Date).getTime())) {
    startTime = new Date();
  } else {
    startTime = startTime as Date;
  }
  
  const isEmergency = params.emergencyDispatch === true;
  let isToBeScheduled = params.visitStatus === 'To Be Scheduled';
  
  if (params.hasActionableQuoteDetails) {
    // Actionable quote: due next day at 8:00 AM EDT/EST
    isToBeScheduled = false;
    startTime = new Date();
    // Add 1 day
    startTime.setDate(startTime.getDate() + 1);
    
    // Set to 8:00 AM Toronto time
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Toronto',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    });
    const parts = formatter.formatToParts(startTime);
    const yr = parts.find(p => p.type === 'year')?.value;
    const mo = parts.find(p => p.type === 'month')?.value;
    const dy = parts.find(p => p.type === 'day')?.value;
    
    if (yr && mo && dy) {
      startTime = new Date(`${yr}-${mo}-${dy}T08:00:00-04:00`); 
    } else {
      startTime.setHours(8, 0, 0, 0);
    }
    
    console.log(`[Calendar] Actionable Quote - Setting due time to 8:00 AM next day: ${startTime.toISOString()}`);
  } else if (isEmergency) {
    startTime = new Date();
    console.log(`[Calendar] EMERGENCY Dispatch - Setting time to NOW: ${startTime.toISOString()}`);
  } else if (isToBeScheduled) {
    let baseDate = (params.visitRequested && params.visitRequested !== '') 
      ? new Date(params.visitRequested as string) 
      : new Date();
    
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Toronto',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    });
    const parts = formatter.formatToParts(baseDate);
    const yr = parts.find(p => p.type === 'year')?.value;
    const mo = parts.find(p => p.type === 'month')?.value;
    const da = parts.find(p => p.type === 'day')?.value;
    
    const startDateTimeString = `${yr}-${mo}-${da}T08:00:00`;
    startTime = parseLocalDateTime(startDateTimeString) || new Date();
    console.log(`[Calendar] To Be Scheduled - Setting time to 8:00 AM on ${startTime.toDateString()}`);
  } else {
    console.log(`[Calendar] New lead with requested time - Staying Yellow for scheduling: ${startTime.toString()}`);
  }
  
  let endTime: Date;
  if (!isEmergency && !isToBeScheduled && params.visitEnd) {
    const parsedEnd = typeof params.visitEnd === 'string' ? parseLocalDateTime(params.visitEnd) : params.visitEnd;
    if (parsedEnd && !isNaN((parsedEnd as Date).getTime())) {
      endTime = parsedEnd as Date;
      console.log(`[Calendar] Using provided end time: ${endTime.toISOString()}`);
    } else {
      endTime = calculateEndTime(startTime);
    }
  } else {
    endTime = calculateEndTime(startTime);
  }

  if (endTime.getTime() <= startTime.getTime()) {
    const oldEnd = endTime.toISOString();
    endTime = calculateEndTime(startTime);
    console.warn(`[Calendar] SAFETY TRIGGER: Invalid time range detected (End: ${oldEnd} <= Start: ${startTime.toISOString()}). Forcing default +2h duration: ${endTime.toISOString()}`);
  }

  const result: { start: calendar_v3.Schema$EventDateTime; end: calendar_v3.Schema$EventDateTime; recurrence?: string[] | null } = {
    start: {
      dateTime: startTime.toISOString(),
      timeZone: 'America/Toronto',
    },
    end: {
      dateTime: endTime.toISOString(),
      timeZone: 'America/Toronto',
    }
  };

  if (params.jobDuration && params.jobDuration > 1) {
    let rrule = `RRULE:FREQ=DAILY;COUNT=${params.jobDuration}`;
    if (params.includeWeekends === false) {
      rrule += `;BYDAY=MO,TU,WE,TH,FR`;
    }
    result.recurrence = [rrule];
  } else {
    result.recurrence = []; // Clear recurrence if jobDuration is 1
  }

  return result;
}

export async function createLeadCalendarEvent(
  params: CreateEventParams
): Promise<CalendarEvent> {
  const calendar = await getCalendarClient();
  
  const isEmergency = params.emergencyDispatch === true;
  const isQuoteAssigned = params.hasActionableQuoteDetails === true;
  
  let colorId = '5'; // Yellow
  if (isEmergency) {
    colorId = '11'; // Red
  } else if (isQuoteAssigned) {
    colorId = '10'; // Green (Assigned/Scheduled)
  }

  const timing = getEventTiming(params);

  // Build event resource
  const eventResource: calendar_v3.Schema$Event = {
    summary: generateEventTitle(params),
    description: generateEventDescription(params),
    location: params.apartmentNumber 
      ? `${params.propertyAddress} (Unit/Apt: ${params.apartmentNumber})` 
      : params.propertyAddress,
    start: timing.start,
    end: timing.end,
    recurrence: timing.recurrence && timing.recurrence.length > 0 ? timing.recurrence : undefined,
    // Attach attendees for actionable quotes or custom selected attendees
    attendees: (() => {
      let atts: {email: string, responseStatus: string}[] = [];
      if (isQuoteAssigned) {
        atts.push({ email: 'tyler@immediateresponsehvac.ca', responseStatus: 'accepted' });
        atts.push({ email: 'cory@immediateresponsehvac.ca', responseStatus: 'accepted' });
      }
      if (params.selectedAttendees && params.selectedAttendees.length > 0) {
        params.selectedAttendees.forEach(email => {
          if (!atts.find(a => a.email.toLowerCase() === email.toLowerCase())) {
            atts.push({ email, responseStatus: 'needsAction' });
          }
        });
      }
      return atts.length > 0 ? atts : undefined;
    })(),
    // Attach Drive folder to the event
    attachments: [
      {
        fileUrl: params.driveFolderUrl,
        title: `${params.propertyAddress} - Documents`,
        mimeType: 'application/vnd.google-apps.folder',
      },
    ],
    // Event settings
    reminders: {
      useDefault: false,
      overrides: [
        { method: 'email', minutes: 24 * 60 },  // 1 day before
        { method: 'popup', minutes: 60 },        // 1 hour before
      ],
    },
    // Color based on visit status: Yellow (To Be Scheduled) or Green (Confirmed)
    colorId,
    // Visibility
    visibility: 'public',
    // Enable attachments
    conferenceData: undefined,
  };

  // Guard: check for an existing event before creating to prevent duplicates
  const existing = await findExistingCalendarEvent(params.propertyAddress);
  if (existing) {
    console.warn(`[Calendar] ⚠️ Duplicate prevented — event already exists for "${params.propertyAddress}": ${existing.eventId}`);
    return {
      eventId: existing.eventId,
      eventUrl: existing.eventUrl,
      htmlLink: existing.eventUrl,
    };
  }

  // Create the event
  const response = await calendar.events.insert({
    calendarId: config.calendar.ghostCalendarId,
    requestBody: eventResource,
    sendUpdates: 'all',  // Send notifications to attendees
    supportsAttachments: true,
  });

  if (!response.data.id || !response.data.htmlLink) {
    throw new Error('Failed to create calendar event');
  }

  return {
    eventId: response.data.id,
    eventUrl: response.data.htmlLink,
    htmlLink: response.data.htmlLink,
  };
}

/**
 * Update an existing calendar event
 */
export async function updateCalendarEvent(
  eventId: string,
  updates: Partial<calendar_v3.Schema$Event>,
  options?: { propertyAddress?: string; leadId?: string }
): Promise<CalendarEvent> {
  const calendar = await getCalendarClient();

  // Self-heal: verify the eventId is valid; if not, find the real one by address
  let resolvedEventId = eventId;
  if (options?.propertyAddress) {
    try {
      resolvedEventId = await resolveCalendarEventId(eventId, options.propertyAddress, options.leadId);
      if (resolvedEventId !== eventId) {
        console.log(`[Calendar Service] 🔧 Using resolved event ID: ${resolvedEventId} (was: ${eventId})`);
      }
    } catch (resolveErr: any) {
      // Log but continue with original ID — don't block the update
      console.error(`[Calendar Service] resolveCalendarEventId failed:`, resolveErr.message);
    }
  }

  console.log(`[Calendar Service] Patching event ${resolvedEventId} with:`, {
    summary: updates.summary,
    attendeeCount: updates.attendees?.length || 0,
    attendees: updates.attendees?.map(a => a.email)
  });

  const response = await calendar.events.patch({
    calendarId: config.calendar.ghostCalendarId,
    eventId: resolvedEventId,
    requestBody: updates,
    sendUpdates: 'all',
  });

  if (!response.data.id || !response.data.htmlLink) {
    throw new Error('Failed to update calendar event');
  }

  return {
    eventId: response.data.id,
    eventUrl: response.data.htmlLink,
    htmlLink: response.data.htmlLink,
  };
}

/**
 * Delete a calendar event (for cleanup/rollback purposes)
 */
export async function deleteCalendarEvent(eventId: string): Promise<void> {
  const calendar = await getCalendarClient();
  
  await calendar.events.delete({
    calendarId: config.calendar.ghostCalendarId,
    eventId,
    sendUpdates: 'none',  // Changed from 'all' to 'none' to avoid service account notification limitations
  });
}

/**
 * Get an existing calendar event
 */
export async function getCalendarEvent(
  eventId: string
): Promise<calendar_v3.Schema$Event | null> {
  const calendar = await getCalendarClient();
  
  try {
    const response = await calendar.events.get({
      calendarId: config.calendar.ghostCalendarId,
      eventId,
    });
    return response.data;
  } catch {
    return null;
  }
}

/**
 * Add attendees to an existing event
 */
export async function addAttendeesToEvent(
  eventId: string,
  newAttendees: calendar_v3.Schema$EventAttendee[]
): Promise<CalendarEvent> {
  // Get existing event
  const existingEvent = await getCalendarEvent(eventId);
  if (!existingEvent) {
    throw new Error(`Event not found: ${eventId}`);
  }

  // Merge attendees without duplicates
  const existingAttendees = existingEvent.attendees || [];
  
  // Create a map to deduplicate by email
  const attendeeMap = new Map<string, calendar_v3.Schema$EventAttendee>();
  
  for (const attendee of existingAttendees) {
    if (attendee.email) {
      attendeeMap.set(attendee.email.toLowerCase(), attendee);
    }
  }
  
  for (const attendee of newAttendees) {
    if (attendee.email) {
      attendeeMap.set(attendee.email.toLowerCase(), attendee);
    }
  }

  const allAttendees = Array.from(attendeeMap.values());

  return updateCalendarEvent(eventId, { attendees: allAttendees });
}

/**
 * Remove an attendee from an existing event
 */
export async function removeAttendeeFromEvent(
  eventId: string,
  emailToRemove: string
): Promise<CalendarEvent> {
  const existingEvent = await getCalendarEvent(eventId);
  if (!existingEvent) {
    throw new Error(`Event not found: ${eventId}`);
  }

  const existingAttendees = existingEvent.attendees || [];
  const updatedAttendees = existingAttendees.filter(
    (a) => a.email?.toLowerCase() !== emailToRemove.toLowerCase()
  );

  return updateCalendarEvent(eventId, { attendees: updatedAttendees });
}

/**
 * Auto-accept a calendar event on behalf of a tech.
 * Uses Domain-Wide Delegation to impersonate the tech and set their response to 'accepted'.
 * This ensures the event appears on the tech's calendar without them needing to manually accept.
 */
export async function acceptEventForAttendee(
  eventId: string,
  attendeeEmail: string
): Promise<void> {
  // Create a calendar client impersonating the tech (not the admin) using proper JWT DWD
  const secretValue = gmailServiceAccountKey.value();
  if (!secretValue) {
    throw new Error('GMAIL_SERVICE_ACCOUNT_KEY secret is not available');
  }
  const creds = JSON.parse(secretValue);
  const jwtClient = new google.auth.JWT({
    email: creds.client_email,
    key: creds.private_key,
    scopes: ['https://www.googleapis.com/auth/calendar'],
    subject: attendeeEmail,
  });
  const techCalendar = google.calendar({ version: 'v3', auth: jwtClient as any });

  // Fetch the event from the tech's perspective
  const event = await techCalendar.events.get({
    calendarId: attendeeEmail, // Tech's primary calendar
    eventId,
  });

  if (!event.data) {
    console.warn(`[Calendar] Event ${eventId} not found on ${attendeeEmail}'s calendar`);
    return;
  }

  // Update the tech's own attendee entry to 'accepted'
  const attendees = event.data.attendees || [];
  const techEntry = attendees.find(
    (a) => a.email?.toLowerCase() === attendeeEmail.toLowerCase()
  );
  if (techEntry) {
    techEntry.responseStatus = 'accepted';
  }

  await techCalendar.events.patch({
    calendarId: attendeeEmail,
    eventId,
    requestBody: { attendees },
    sendUpdates: 'none', // Don't spam everyone with the acceptance
  });

  console.log(`[Calendar] Auto-accepted event ${eventId} for ${attendeeEmail}`);
}

/**
 * Generate a calendar event URL from event ID
 */
export function getCalendarEventUrl(eventId: string): string {
  // Encode event ID for URL
  const encodedId = Buffer.from(eventId).toString('base64').replace(/=/g, '');
  return `https://calendar.google.com/calendar/event?eid=${encodedId}`;
}

/**
 * Move all unscheduled events from yesterday to today
 * 
 * This function runs daily at 6 AM Mountain Time.
 * It finds all events from the previous day that still have [UNSCHEDULED] in the title
 * and moves them to today at the same time.
 * 
 * @returns Number of events moved
 */
export async function moveUnscheduledEvents(): Promise<{ moved: number; errors: number }> {
  const calendar = await getCalendarClient();
  
  // Calculate yesterday's date range (Mountain Time)
  const now = new Date();
  // Adjust for Mountain Time (UTC-7 or UTC-6 during DST)
  const mtOffset = -7 * 60; // Mountain Standard Time offset in minutes
  const localNow = new Date(now.getTime() + (mtOffset + now.getTimezoneOffset()) * 60000);
  
  const yesterdayStart = new Date(localNow);
  yesterdayStart.setDate(yesterdayStart.getDate() - 1);
  yesterdayStart.setHours(0, 0, 0, 0);
  
  const yesterdayEnd = new Date(localNow);
  yesterdayEnd.setDate(yesterdayEnd.getDate() - 1);
  yesterdayEnd.setHours(23, 59, 59, 999);

  console.log(`Searching for unscheduled events between ${yesterdayStart.toISOString()} and ${yesterdayEnd.toISOString()}`);

  // Get all events from yesterday
  const response = await calendar.events.list({
    calendarId: config.calendar.ghostCalendarId,
    timeMin: yesterdayStart.toISOString(),
    timeMax: yesterdayEnd.toISOString(),
    singleEvents: true,
    orderBy: 'startTime',
  });

  const events = response.data.items || [];
  console.log(`Found ${events.length} events from yesterday`);

  // Filter for unscheduled events
  const unscheduledEvents = events.filter(event => 
    event.summary?.includes(UNSCHEDULED_MARKER)
  );

  console.log(`Found ${unscheduledEvents.length} unscheduled events to move`);

  let moved = 0;
  let errors = 0;

  // Move each unscheduled event to today
  for (const event of unscheduledEvents) {
    try {
      if (!event.id || !event.start || !event.end) {
        console.warn(`Skipping event with missing data: ${event.summary}`);
        errors++;
        continue;
      }

      // Calculate new start and end times (add 1 day)
      const oldStart = new Date(event.start.dateTime || event.start.date || '');
      const oldEnd = new Date(event.end.dateTime || event.end.date || '');
      
      const newStart = new Date(oldStart);
      newStart.setDate(newStart.getDate() + 1);
      
      const newEnd = new Date(oldEnd);
      newEnd.setDate(newEnd.getDate() + 1);

      // Update the event
      await calendar.events.patch({
        calendarId: config.calendar.ghostCalendarId,
        eventId: event.id,
        requestBody: {
          start: {
            dateTime: newStart.toISOString(),
            timeZone: 'America/Edmonton',
          },
          end: {
            dateTime: newEnd.toISOString(),
            timeZone: 'America/Edmonton',
          },
        },
        sendUpdates: 'none', // Don't spam attendees with updates
      });

      console.log(`Moved event: ${event.summary}`);
      moved++;
    } catch (error) {
      console.error(`Failed to move event ${event.summary}:`, error);
      errors++;
    }
  }

  return { moved, errors };
}

/**
 * Safety Cleanup: Find and delete any events at a specific address in the Ghost Calendar.
 * Useful for cleaning up orphans from failed intake attempts.
 */
export async function deleteCalendarEventsByAddress(address: string): Promise<number> {
  const calendar = await getCalendarClient();
  const query = address.toLowerCase().trim();
  
  // Search for events in the ghost calendar
  // We use a small window around now to avoid deleting historical data if address is reused
  const timeMin = new Date();
  timeMin.setMonth(timeMin.getMonth() - 1); // Last month
  const timeMax = new Date();
  timeMax.setMonth(timeMax.getMonth() + 12); // Next year

  const response = await calendar.events.list({
    calendarId: config.calendar.ghostCalendarId,
    q: query,
    timeMin: timeMin.toISOString(),
    timeMax: timeMax.toISOString(),
    singleEvents: true,
    maxResults: 20,
  });

  const events = response.data.items || [];
  let deletedCount = 0;
  
  for (const event of events) {
    // Extra safety: Verify address is actually in the summary or location
    const summaryMatch = event.summary?.toLowerCase().includes(query);
    const locationMatch = event.location?.toLowerCase().includes(query);
    
    // We ONLY delete events that are [UNSCHEDULED] or have "HVAC" in them to be safe
    const isHvacEvent = event.summary?.includes('[UNSCHEDULED]') || event.summary?.toLowerCase().includes('hvac');

    if (event.id && (summaryMatch || locationMatch) && isHvacEvent) {
      console.log(`[Calendar Cleanup] Deleting orphaned/duplicate event: ${event.summary} (ID: ${event.id})`);
      try {
        await calendar.events.delete({
          calendarId: config.calendar.ghostCalendarId,
          eventId: event.id,
          sendUpdates: 'none',
        });
        deletedCount++;
      } catch (e: any) {
        console.error(`[Calendar Cleanup] Failed to delete event ${event.id}:`, e.message);
      }
    }
  }
  
  return deletedCount;
}

/**
 * Get today's events for a specific technician.
 * Uses Domain-Wide Delegation to impersonate the tech and fetch their primary calendar.
 * 
 * @param techEmail - Technician's email address
 * @returns List of calendar events
 */
/**
 * Get today's events for a specific technician.
 * Uses a two-pronged approach:
 * 1. Tries to fetch technician's primary calendar using Domain-Wide Delegation (if authorized).
 * 2. Fetches Ghost calendar events for today and filters for events where the tech is an attendee.
 * 
 * @param techEmail - Technician's email address
 * @returns List of calendar events
 */
export async function getTechTodayCalendar(techEmail: string): Promise<calendar_v3.Schema$Event[]> {
  const secretValue = gmailServiceAccountKey.value();
  if (!secretValue) {
    throw new Error('GMAIL_SERVICE_ACCOUNT_KEY secret is not available');
  }
  const creds = JSON.parse(secretValue.charCodeAt(0) === 0xFEFF ? secretValue.slice(1) : secretValue);
  
  // Calculate today's range in Toronto time (Midnight to Midnight)
  const now = new Date();
  
  // Create Toronto midnight (start of day)
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Toronto',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  const parts = formatter.formatToParts(now);
  const yr = parts.find(p => p.type === 'year')?.value;
  const mo = parts.find(p => p.type === 'month')?.value;
  const da = parts.find(p => p.type === 'day')?.value;
  
  // We want to see Today AND Tomorrow to be safe and helpful
  const startOfDay = parseLocalDateTime(`${yr}-${mo}-${da}T00:00:00`) || new Date();
  const endOfTomorrow = new Date(startOfDay);
  endOfTomorrow.setDate(endOfTomorrow.getDate() + 7); // 7 days total
  
  console.log(`[Calendar] Fetching tech events between ${startOfDay.toISOString()} and ${endOfTomorrow.toISOString()}`);

  const allEvents: calendar_v3.Schema$Event[] = [];
  const eventIds = new Set<string>();

  // Helper to add events uniquely
  const addUniqueEvents = (events: calendar_v3.Schema$Event[]) => {
    for (const event of events) {
      if (event.id && !eventIds.has(event.id)) {
        allEvents.push(event);
        eventIds.add(event.id);
      }
    }
  };

  // 1. Try DWD on Tech's Primary Calendar
  try {
    const jwtClient = new google.auth.JWT({
      email: creds.client_email,
      key: creds.private_key,
      scopes: ['https://www.googleapis.com/auth/calendar.readonly'],
      subject: techEmail,
    });
    
    const calendar = google.calendar({ version: 'v3', auth: jwtClient as any });
    const response = await calendar.events.list({
      calendarId: techEmail,
      timeMin: startOfDay.toISOString(),
      timeMax: endOfTomorrow.toISOString(),
      singleEvents: true,
      orderBy: 'startTime',
    });
    
    if (response.data.items) {
      console.log(`[Calendar] Found ${response.data.items.length} events via DWD for ${techEmail}`);
      addUniqueEvents(response.data.items);
    }
  } catch (error: any) {
    console.warn(`[Calendar] DWD Fetch Failed for ${techEmail} (Likely not authorized):`, error.message);
    // Continue - we will fall back to Ghost calendar check
  }

  // 2. Fetch from Ghost Calendar and filter for tech attendee
  try {
    const ghostCalendar = await getCalendarClient();
    const response = await ghostCalendar.events.list({
      calendarId: config.calendar.ghostCalendarId,
      timeMin: startOfDay.toISOString(),
      timeMax: endOfTomorrow.toISOString(),
      singleEvents: true,
      orderBy: 'startTime',
    });
    
    const ghostEvents = response.data.items || [];
    const techGhostEvents = ghostEvents.filter(event => 
      event.attendees?.some(a => a.email?.toLowerCase() === techEmail.toLowerCase()) ||
      event.description?.toLowerCase().includes(techEmail.toLowerCase())
    );
    
    if (techGhostEvents.length > 0) {
      console.log(`[Calendar] Found ${techGhostEvents.length} events on Ghost Calendar for ${techEmail}`);
      addUniqueEvents(techGhostEvents);
    }
  } catch (error: any) {
    console.error(`[Calendar] Ghost Calendar Fetch Failed:`, error.message);
  }
  
  // Sort by start time
  return allEvents.sort((a, b) => {
    const startA = new Date(a.start?.dateTime || a.start?.date || 0).getTime();
    const startB = new Date(b.start?.dateTime || b.start?.date || 0).getTime();
    return startA - startB;
  });
}

/**
 * Fetch ALL today's events from the Ghost Calendar (No filtering).
 * Useful for admins or as a broad fallback.
 */
export async function getTodayEvents(): Promise<calendar_v3.Schema$Event[]> {
  const now = new Date();
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit',
  });
  const parts = formatter.formatToParts(now);
  const yr = parts.find(p => p.type === 'year')?.value;
  const mo = parts.find(p => p.type === 'month')?.value;
  const da = parts.find(p => p.type === 'day')?.value;
  
  const startOfDay = parseLocalDateTime(`${yr}-${mo}-${da}T00:00:00`) || new Date();
  const endOfTomorrow = new Date(startOfDay);
  endOfTomorrow.setDate(endOfTomorrow.getDate() + 7);
  
  const ghostCalendar = await getCalendarClient();
  const response = await ghostCalendar.events.list({
    calendarId: config.calendar.ghostCalendarId,
    timeMin: startOfDay.toISOString(),
    timeMax: endOfTomorrow.toISOString(),
    singleEvents: true,
    orderBy: 'startTime',
  });
  
  return response.data.items || [];
}
