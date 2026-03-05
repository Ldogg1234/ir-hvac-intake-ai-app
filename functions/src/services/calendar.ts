/**
 * Google Calendar Service
 * Handles calendar event creation for HVAC lead intake
 * 
 * Events are created on the 'Ghost' calendar with Drive folder attached
 * Calendar ID: c_82f31464fae8eeb8fd1cee1af6675655ffc9456594b656b049cc061323199f35
 */

import { google, calendar_v3 } from 'googleapis';
import { config } from '../config';

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
  jobCategories: string[];
  claimType?: string | null;
  jobType: string;
  scopeDetails?: string | null;
  visitRequested: Date | string;
  visitStatus?: string | null; // 'To Be Scheduled' or 'Confirmed date'
  accessInstructions?: string | null;
  lockboxCode?: string | null;
  driveFolderUrl: string;
  driveFolderId: string;
}

export interface CalendarEvent {
  eventId: string;
  eventUrl: string;
  htmlLink: string;
}

// User to impersonate for domain-wide delegation
const IMPERSONATE_USER = 'admin@immediateresponsehvac.ca';

// Initialize Calendar client with domain-wide delegation
async function getCalendarClient(): Promise<calendar_v3.Calendar> {
  const auth = new google.auth.GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/calendar'],
  });
  
  const client = await auth.getClient();
  
  // Use domain-wide delegation to impersonate the admin user
  if ('subject' in client) {
    (client as any).subject = IMPERSONATE_USER;
  }
  
  return google.calendar({ version: 'v3', auth: client as any });
}

// Marker for unscheduled events - Nicole removes this when assigning a tech
export const UNSCHEDULED_MARKER = '[UNSCHEDULED]';

/**
 * Generate event title based on job details
 * Includes [UNSCHEDULED] marker - Nicole removes this when assigning a tech
 */
function generateEventTitle(params: CreateEventParams): string {
  const jobTypeLabel = params.jobType.replace(/_/g, ' ');
  return `${UNSCHEDULED_MARKER} HVAC ${jobTypeLabel} - ${params.propertyAddress}`;
}

/**
 * Generate event description with all relevant job details
 */
function generateEventDescription(params: CreateEventParams): string {
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
  sections.push('');

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
    sections.push(`Name: ${params.pmName}`);
    if (params.pmEmail) {
      sections.push(`Email: ${params.pmEmail}`);
    }
    if (params.pmPhone) {
      sections.push(`Phone: ${params.pmPhone}`);
    }
    sections.push('');
  }

  // Access Instructions
  if (params.accessInstructions) {
    sections.push('🔑 ACCESS INSTRUCTIONS');
    sections.push(params.accessInstructions);
    if (params.lockboxCode) {
      sections.push(`Lockbox Code: ${params.lockboxCode}`);
    }
    sections.push('');
  }

  // Drive Folder Link
  sections.push('📁 DOCUMENTS & MEDIA');
  sections.push(`Drive Folder: ${params.driveFolderUrl}`);
  sections.push('');

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
export async function createLeadCalendarEvent(
  params: CreateEventParams
): Promise<CalendarEvent> {
  const calendar = await getCalendarClient();
  
  // Parse visit time and apply status-based logic
  let startTime = typeof params.visitRequested === 'string' 
    ? new Date(params.visitRequested) 
    : params.visitRequested;
  
  // Determine color and time based on visit_status
  let colorId: string;
  const isToBeScheduled = params.visitStatus === 'To Be Scheduled';
  
  if (isToBeScheduled) {
    // Yellow (To Be Scheduled): Force time to 6:00 AM on the selected date
    colorId = '5'; // Yellow
    startTime = new Date(startTime);
    startTime.setHours(6, 0, 0, 0); // Set to 6:00 AM
    console.log(`[Calendar] To Be Scheduled - Setting time to 6:00 AM: ${startTime.toISOString()}`);
  } else {
    // Green (Confirmed date): Use exact date/time provided by user
    colorId = '10'; // Green
    console.log(`[Calendar] Confirmed date - Using exact time: ${startTime.toISOString()}`);
  }
  
  const endTime = calculateEndTime(startTime);

  // Build event resource
  const eventResource: calendar_v3.Schema$Event = {
    summary: generateEventTitle(params),
    description: generateEventDescription(params),
    location: params.propertyAddress,
    start: {
      dateTime: startTime.toISOString(),
      timeZone: 'America/Edmonton', // Calgary timezone
    },
    end: {
      dateTime: endTime.toISOString(),
      timeZone: 'America/Edmonton',
    },
    // Note: Attendees not added - service accounts cannot invite without Domain-Wide Delegation
    // Client/PM contact info is in the description instead
    // attendees: buildAttendees(params),
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
    visibility: 'default',
    // Enable attachments
    conferenceData: undefined,
  };

  // Create the event (don't send invites - service account limitation)
  const response = await calendar.events.insert({
    calendarId: config.calendar.ghostCalendarId,
    requestBody: eventResource,
    sendUpdates: 'none',  // Don't send invites - requires domain-wide delegation
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
  updates: Partial<calendar_v3.Schema$Event>
): Promise<CalendarEvent> {
  const calendar = await getCalendarClient();

  const response = await calendar.events.patch({
    calendarId: config.calendar.ghostCalendarId,
    eventId,
    requestBody: updates,
    sendUpdates: 'all',  // Notify attendees of changes
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
    sendUpdates: 'all',  // Notify attendees of cancellation
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

  // Merge attendees
  const existingAttendees = existingEvent.attendees || [];
  const allAttendees = [...existingAttendees, ...newAttendees];

  return updateCalendarEvent(eventId, { attendees: allAttendees });
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
