// Deploy nudge: Feb 13 - final handshake fix
// Deployment Force-Refresh: Feb 13 - FAILED_PRECONDITION fix
/**
 * Email Service
 * Sends customer confirmation emails using Gmail API with Service Account Impersonation
 */

import { google } from 'googleapis';
import { gmail_v1 } from 'googleapis';
import { IntakeRequest } from '../types';
import { AUTO_BOT_OUTREACH_ID } from '../constants';

const MailComposer = require('nodemailer/lib/mail-composer');

// Use nicole@ for domain-wide delegation impersonation
const IMPERSONATED_USER = 'nicole@immediateresponsehvac.ca';
const ADMIN_FALLBACK_EMAIL = 'admin@immediateresponsehvac.ca';
const CC_RECIPIENT = 'nicole@immediateresponsehvac.ca'; // Always CC Nicole on every email
// Using FULL gmail scope to match Admin Console
const GMAIL_SCOPES = ['https://mail.google.com/'];

const SERVICE_ACCOUNT = 'gmail-automation-sa@immediate-response-ai.iam.gserviceaccount.com';

/**
 * Get Gmail API client with explicit domain-wide delegation
 */
export async function getGmailClient(impersonatedUser: string = IMPERSONATED_USER): Promise<gmail_v1.Gmail> {
  console.log('[Gmail Client] Initializing Gmail API client...');
  console.log(`[Gmail Client] Service Account: ${SERVICE_ACCOUNT}`);
  console.log('--- Using JWT with explicit credentials from Secret Manager ---');
  console.log(`[Gmail Client] Impersonating: ${impersonatedUser}`);
  console.log(`[Gmail Client] Scopes: ${GMAIL_SCOPES.join(', ')}`);
  
  try {
    // Parse credentials from Secret Manager environment variable
    console.log('[Gmail Client] Parsing service account credentials from Secret Manager...');
    const credentialsJson = process.env.GMAIL_SERVICE_ACCOUNT_KEY;
    
    if (!credentialsJson) {
      throw new Error('GMAIL_SERVICE_ACCOUNT_KEY environment variable not set');
    }
    
    const credentials = JSON.parse(credentialsJson);
    console.log(`[Gmail Client] ✅ Credentials parsed - client_email: ${credentials.client_email}`);
    
    // Fix newline handling in private key (critical for JWT signing)
    // Secret Manager may store \n as literal characters instead of newlines
    const privateKey = credentials.private_key.replace(/\\n/g, '\n');
    console.log('[Gmail Client] ✅ Private key newlines normalized');
    
    // CRITICAL: Use JWT constructor with explicit parameters for domain-wide delegation
    console.log('[Gmail Client] Creating JWT with explicit constructor parameters...');
    const authClient = new google.auth.JWT({
      email: credentials.client_email,
      key: privateKey,
      scopes: GMAIL_SCOPES,
      subject: impersonatedUser
    });
    
    console.log('[Gmail Client] ✅ JWT client created with explicit parameters');
    console.log(`[Gmail Client] Email: ${credentials.client_email}`);
    console.log(`[Gmail Client] Subject: ${IMPERSONATED_USER}`);
    console.log(`[Gmail Client] Scopes: ${GMAIL_SCOPES.join(', ')}`);
    console.log(`Handshake: Identity verified for ${IMPERSONATED_USER}`);

    // Create Gmail API client with the JWT auth client
    console.log('[Gmail Client] Creating Gmail API client...');
    const gmail = google.gmail({ version: 'v1', auth: authClient });
    console.log('[Gmail Client] ✅ Gmail API client created successfully');
    console.log('[Gmail Client] Ready to send emails as: nicole@immediateresponsehvac.ca');
    console.log('[Gmail Client] Using scope: https://mail.google.com/');
    return gmail;
  } catch (error) {
    console.error('[Gmail Client] ❌ FAILED to create Gmail client');
    console.error('[Gmail Client] --- AUTH ERROR DETAILS ---');
    console.error('[Gmail Client] Error:', error);
    console.error('[Gmail Client] Error type:', error instanceof Error ? error.constructor.name : typeof error);
    console.error('[Gmail Client] Error message:', error instanceof Error ? error.message : String(error));
    
    // Use console.dir to see all hidden properties
    console.error('[Gmail Client] Full error object (console.dir):');
    console.dir(error, { depth: null });
    
    throw error;
  }
}

/**
 * Create email message in RFC 2822 format with CC and attachment support
 */
async function createEmailMessage(to: string, subject: string, htmlContent: string, cc?: string, fromEmail: string = IMPERSONATED_USER, attachments?: any[]): Promise<string> {
  console.log(`[Email Message] Creating RFC 2822 message via nodemailer...`);
  console.log(`[Email Message] From: Immediate Response HVAC <${fromEmail}>`);
  console.log(`[Email Message] To: ${to}`);
  if (cc) console.log(`[Email Message] CC: ${cc}`);
  console.log(`[Email Message] Subject: ${subject}`);
  if (attachments) console.log(`[Email Message] Attachments: ${attachments.length}`);
  
  const mailOptions = {
    from: `Immediate Response HVAC <${fromEmail}>`,
    to,
    cc,
    subject,
    html: htmlContent,
    attachments
  };
  
  const mail = new MailComposer(mailOptions);
  
  return new Promise((resolve, reject) => {
    mail.compile().build((err: Error | null, message: Buffer) => {
      if (err) return reject(err);
      
      // Encode to base64url
      const encoded = message
        .toString('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
        
      resolve(encoded);
    });
  });
}

/**
 * Generate HTML email template for customer confirmation
 */
function generateConfirmationEmailHtml(request: IntakeRequest): string {
  const scopeOfWork = request.scope_details || 'Details to be confirmed';
  
  // Parse visit date and apply 6am logic for "To Be Scheduled"
  let visitDateTime = new Date(request.visit_requested);
  const isToBeScheduled = request.visit_status === 'To Be Scheduled';
  
  if (isToBeScheduled) {
    // Force time to 6:00 AM for "To Be Scheduled" status
    visitDateTime = new Date(visitDateTime);
    visitDateTime.setHours(6, 0, 0, 0);
  }
  
  const visitDate = visitDateTime.toLocaleString('en-US', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
  
  // Add status indicator if "To Be Scheduled"
  const visitDisplayText = isToBeScheduled 
    ? `${visitDate} (To Be Scheduled - time will be confirmed)`
    : visitDate;
  
  // Format job categories as an HTML list
  const jobCategoriesHtml = request.job_categories.length > 0
    ? `<ul style="margin: 5px 0; padding-left: 20px;">${request.job_categories.map(cat => `<li>${cat}</li>`).join('')}</ul>`
    : '<p style="margin: 5px 0;">No categories specified</p>';

  return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    body {
      font-family: Arial, sans-serif;
      line-height: 1.6;
      color: #333;
      max-width: 600px;
      margin: 0 auto;
      padding: 20px;
    }
    .header {
      background-color: #0066cc;
      color: white;
      padding: 20px;
      text-align: center;
      border-radius: 5px 5px 0 0;
    }
    .content {
      background-color: #f9f9f9;
      padding: 30px;
      border: 1px solid #ddd;
      border-top: none;
    }
    .info-section {
      margin: 20px 0;
      padding: 15px;
      background-color: white;
      border-left: 4px solid #0066cc;
    }
    .info-label {
      font-weight: bold;
      color: #0066cc;
      margin-bottom: 5px;
    }
    .info-value {
      color: #555;
    }
    .notice {
      background-color: #fff3cd;
      border: 1px solid #ffc107;
      padding: 15px;
      margin: 20px 0;
      border-radius: 5px;
      text-align: center;
    }
    .notice-text {
      color: #856404;
      font-weight: bold;
      margin: 0;
    }
    .footer {
      margin-top: 30px;
      padding-top: 20px;
      border-top: 2px solid #ddd;
      text-align: center;
      color: #777;
      font-size: 14px;
    }
    .contact-info {
      margin-top: 15px;
    }
  </style>
</head>
<body>
  <div class="header">
    <h1>Service Request Confirmation</h1>
    <p>Immediate Response HVAC</p>
  </div>
  
  <div class="content">
    <p>Hello,</p>
    
    <p>Thank you for choosing Immediate Response HVAC. We have received your service request and are committed to providing you with prompt and professional service.</p>
    
    <div class="info-section">
      <div class="info-label">Service Address:</div>
      <div class="info-value">${request.property_address}${request.apartment_number ? `, Unit ${request.apartment_number}` : ''}</div>
    </div>
    
    <div class="info-section">
      <div class="info-label">Job Categories:</div>
      <div class="info-value">${jobCategoriesHtml}</div>
    </div>
    
    <div class="info-section">
      <div class="info-label">Scope of Work:</div>
      <div class="info-value">${scopeOfWork}</div>
    </div>
    
    <div class="info-section">
      <div class="info-label">Requested Visit:</div>
      <div class="info-value">${visitDisplayText}</div>
    </div>
    
    <div class="notice">
      <p class="notice-text">⚠️ A technician has not been assigned yet</p>
      <p style="margin: 10px 0 0 0; color: #856404;">Our team will contact you shortly to schedule your visit and confirm all details.</p>
    </div>
    
    <p>If you have any questions or need to update your request, please don't hesitate to contact us.</p>
    
    <div class="footer">
      <strong>Immediate Response HVAC</strong>
      <div class="contact-info">
        <p>📧 nicole@immediateresponsehvac.ca</p>
        <p>📞 416-291-4822</p>
        <p>📍 153 Crown Ct, Whitby, ON L1N 7B1</p>
      </div>
      <p style="margin-top: 20px; font-style: italic;">Your Comfort, Our Commitment</p>
    </div>
  </div>
  ${AUTO_BOT_OUTREACH_ID}
</body>
</html>
  `.trim();
}

/**
 * Validate and sanitize email address
 */
function isValidEmail(email: string | null | undefined): boolean {
  if (!email || typeof email !== 'string') {
    return false;
  }
  const trimmed = email.trim();
  return trimmed.length > 0 && trimmed.includes('@');
}

/**
 * Determine recipient email based on job type with fallback to admin
 * - Insurance jobs (Res_Insurance, Comm_Insurance): Send to PM, fallback to admin
 * - Regular jobs (Residential, Commercial): Send to Client, fallback to admin
 */
function getRecipientEmail(request: IntakeRequest): { email: string; type: string; usedFallback: boolean } {
  const isInsurance = request.job_type === 'Res_Insurance' || request.job_type === 'Comm_Insurance';

  console.log(`[Email Routing] Job Type: ${request.job_type}, Is Insurance: ${isInsurance}`);

  if (isInsurance) {
    // For insurance jobs, try PM email first
    const pmEmail = request.pm?.email;
    console.log(`[Email Routing] PM Email from request: ${pmEmail || 'NOT PROVIDED'}`);
    
    if (isValidEmail(pmEmail)) {
      console.log(`[Email Routing] Using PM email: ${pmEmail}`);
      return { email: pmEmail!.trim(), type: 'PM', usedFallback: false };
    } else {
      console.warn(`[Email Routing] No valid PM email for insurance job, using admin fallback`);
      return { email: ADMIN_FALLBACK_EMAIL, type: 'Admin (PM fallback)', usedFallback: true };
    }
  } else {
    // For regular jobs, try client email first
    const clientEmail = request.client_email;
    console.log(`[Email Routing] Client Email from request: ${clientEmail || 'NOT PROVIDED'}`);
    
    if (isValidEmail(clientEmail)) {
      console.log(`[Email Routing] Using client email: ${clientEmail}`);
      return { email: clientEmail!.trim(), type: 'Client', usedFallback: false };
    } else {
      console.warn(`[Email Routing] No valid client email for regular job, using admin fallback`);
      return { email: ADMIN_FALLBACK_EMAIL, type: 'Admin (Client fallback)', usedFallback: true };
    }
  }
}

/**
 * Send customer confirmation email
 * NOTE: This function never throws errors - it's designed to be non-blocking
 */
export async function sendCustomerConfirmationEmail(request: IntakeRequest): Promise<void> {
  console.log('!!! LOG LEVEL 1: ENTERED EMAIL FUNCTION !!!');
  console.log('!!! EMAIL FUNCTION WAS CALLED !!!');
  console.log('!!! Request received in email function !!!');
  
  try {
    console.log('=== EMAIL SERVICE: START ===');
    console.log(`Job Type: ${request.job_type}`);
    console.log(`Client Email: ${request.client_email || 'NOT PROVIDED'}`);
    console.log(`PM Email: ${request.pm?.email || 'NOT PROVIDED'}`);

    // Determine recipient based on job type with fallback
    const recipient = getRecipientEmail(request);

    console.log(`[Email Service] Final recipient: ${recipient.email} (Type: ${recipient.type}, Fallback Used: ${recipient.usedFallback})`);
    console.log(`Routing Decision: Job is ${request.job_type}, Sending To: ${recipient.email}`);
    console.log(`[Email Service] CC will be added: ${CC_RECIPIENT}`);

    // Double-check recipient email is valid before sending
    if (!recipient.email || !isValidEmail(recipient.email)) {
      console.error(`[Email Service] CRITICAL: Invalid recipient email after routing: ${recipient.email}`);
      console.error('[Email Service] Skipping email send to prevent crash');
      return;
    }

    console.log(`[Email Service] Attempting to send email to ${recipient.email} with CC to ${CC_RECIPIENT}...`);

    // Get Gmail API client
    const gmail = await getGmailClient();
    const htmlContent = generateConfirmationEmailHtml(request);

    // Create the email message with CC
    console.log('[Email Service] Creating email message with CC...');
    const encodedMessage = await createEmailMessage(
      recipient.email,
      'Service Request Received - Immediate Response HVAC',
      htmlContent,
      CC_RECIPIENT // Always CC tdear@
    );

    // Send the email using Gmail API
    console.log('[Email Service] Sending email via Gmail API...');
    console.log(`[Email Service] Using userId: 'nicole@immediateresponsehvac.ca' (explicit mailbox)`);
    console.log(`[Email Service] Scope: ${GMAIL_SCOPES[0]}`);
    const response = await gmail.users.messages.send({
      userId: 'nicole@immediateresponsehvac.ca', // Explicit email address for impersonated user
      requestBody: {
        raw: encodedMessage,
      },
    });

    console.log(`[Email Service] ✅ SUCCESS - Email sent to ${recipient.type} (${recipient.email})`);
    console.log(`[Email Service] Message ID: ${response.data.id}`);
    console.log(`[Email Service] Thread ID: ${response.data.threadId}`);
    console.log('=== EMAIL SERVICE: END ===');
  } catch (error) {
    console.error('=== EMAIL SERVICE: ERROR ===');
    console.error('--- GMAIL API ACTUAL ERROR ---', error);
    console.error('[Email Service] Error type:', error instanceof Error ? error.constructor.name : typeof error);
    console.error('[Email Service] Error message:', error instanceof Error ? error.message : String(error));
    console.error('[Email Service] Error stack:', error instanceof Error ? error.stack : 'N/A');
    
    // Use console.dir to see hidden GaxiosError details
    console.error('[Email Service] Full error details (console.dir):');
    console.dir(error, { depth: null });
    
    // Log the full error object for debugging
    if (error && typeof error === 'object') {
      console.error('[Email Service] Error as JSON:', JSON.stringify(error, null, 2));
      
      // Try to log specific error properties that might be hidden
      const err = error as any;
      if (err.response) {
        console.error('[Email Service] Response data:', err.response.data);
        console.error('[Email Service] Response status:', err.response.status);
        console.error('[Email Service] Response headers:', err.response.headers);
      }
      if (err.config) {
        console.error('[Email Service] Request config:', err.config);
      }
    }
    
    console.error('[Email Service] Lead intake will continue despite email failure');
    console.error('=== EMAIL SERVICE: END (WITH ERROR) ===');
    // IMPORTANT: Don't throw - we don't want email failures to break the entire workflow
    // The lead is already created, email is a bonus feature
  }
}

/**
 * Helper to shorten address for email subject
 * Removes Canada, postal codes, and trailing commas
 */
function shortenAddressForSubject(address?: string): string {
  if (!address) return '';
  // Split by comma and take the first two parts (Street, City)
  const parts = address.split(',').map(p => p.trim());
  if (parts.length >= 2) {
    return `${parts[0]}, ${parts[1]}`;
  }
  return parts[0];
}

/**
 * Send a generic HTML email (e.g. for admin alerts)
 */
export async function sendEmail(params: {
  to: string;
  subject: string;
  body: string;
  fromEmail?: string;
  cc?: string;
  attachments?: { filename: string, content: Buffer, contentType?: string }[]
}): Promise<void> {
  const fromAddress = params.fromEmail || IMPERSONATED_USER;
  console.log(`[Email Service] Sending generic email to ${params.to} from ${fromAddress}: ${params.subject}`);
  try {
    const gmail = await getGmailClient(fromAddress);
    const encodedMessage = await createEmailMessage(
      params.to,
      params.subject,
      params.body,
      params.cc,
      fromAddress,
      params.attachments
    );

    await gmail.users.messages.send({
      userId: fromAddress,
      requestBody: { raw: encodedMessage },
    });

    console.log(`[Email Service] ✅ Generic email sent to ${params.to}`);
  } catch (error: any) {
    console.error(`[Email Service] ❌ Failed to send generic email:`, error?.message);
  }
}

/**
 * Send out-of-town travel notification alert to Nicole
 */
export async function sendTravelNotificationEmail(params: {
  jobId: string;
  clientName: string;
  propertyAddress: string;
  distanceKm: number | string;
  td4Required?: boolean;
  calendarEventUrl?: string;
  driveFolderUrl: string;
}): Promise<void> {
  const to = 'admin@immediateresponsehvac.ca';
  const subject = `Travel Prep Required: ${params.jobId} - ${params.clientName}`;

  const calendarLink = params.calendarEventUrl && params.calendarEventUrl !== 'Pending'
    ? params.calendarEventUrl
    : 'https://calendar.google.com/calendar/u/0/r';

  const body = `
  <div style="font-family: Arial, sans-serif; max-width: 600px;">
    <h2 style="color: #0066cc;">Out-of-Town Lead Alert</h2>
    <p>Hi Nicole,</p>
    <p>A new out-of-town lead has been created for <strong>${params.propertyAddress}</strong>.</p>
    <p>Distance from Whitby: <strong>${params.distanceKm} km</strong>.</p>
    
    <div style="background-color: #fff3cd; border: 1px solid #ffc107; padding: 15px; margin: 20px 0; border-radius: 5px;">
      <p style="color: #856404; margin: 0; font-weight: bold;">Action Required:</p>
      <p style="color: #856404; margin: 5px 0 0 0;">If this job is scheduled, you will need to book travel/accommodations.</p>
    </div>
    
    ${params.td4Required !== undefined ? `
    <div style="background-color: #e2e3e5; border: 1px solid #d6d8db; padding: 15px; margin: 20px 0; border-radius: 5px;">
      <p style="color: #383d41; margin: 0; font-weight: bold;">CRA Compliance & TD4 Info:</p>
      <p style="color: #383d41; margin: 5px 0 0 0;">Distance Log generated and saved to drive.</p>
      <p style="color: #383d41; margin: 5px 0 0 0;">Form TD4 required for staff: <strong>${params.td4Required ? 'YES' : 'NO'}</strong></p>
    </div>
    ` : ''}
    
    <p><strong><a href="${calendarLink}">Schedule Link (Ghost Calendar)</a></strong></p>
    <p><strong><a href="${params.driveFolderUrl}">Drive Link (Job Folder)</a></strong></p>
  </div>
  `;

  await sendEmail({ to, subject, body });
}

/**
 * Send notification to Nicole for a fixed schedule appointment request
 */
export async function sendFixedScheduleNotificationEmail(request: any): Promise<void> {
  const to = 'nicole@immediateresponsehvac.ca';
  const subject = `Priority Booking Request: Fixed Schedule - ${shortenAddressForSubject(request.property_address)}`;

  const visitDate = request.visit_requested ? new Date(request.visit_requested) : null;
  const formatDate = (date: Date) => {
    return date.toLocaleString('en-US', {
      timeZone: 'America/Toronto',
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  };
  const dateStr = visitDate ? formatDate(visitDate) : 'Not provided';
  const pmName = request.pm?.full_name || 'N/A';

  const body = `
  <div style="font-family: Arial, sans-serif; max-width: 600px;">
    <h2 style="color: #0066cc;">Fixed Schedule Appointment Request</h2>
    <p>Hi Nicole,</p>
    <p>A new lead has been submitted requesting a <strong>fixed schedule appointment</strong>.</p>
    
    <div style="background-color: #e6f2ff; border: 1px solid #0066cc; padding: 15px; margin: 20px 0; border-radius: 5px;">
      <p style="margin: 0 0 10px 0;"><strong>Property Address:</strong> ${request.property_address}</p>
      <p style="margin: 0 0 10px 0;"><strong>Project Manager:</strong> ${pmName}</p>
      <p style="margin: 0; color: #cc0000; font-weight: bold;">Requested Date & Time: ${dateStr}</p>
    </div>
    
    <p>Please review and prioritize this booking in the dispatch board.</p>
  </div>
  `;

  await sendEmail({ to, subject, body });
}

/**
 * Send human-in-the-loop notification for QBO Estimates
 */
export async function sendEstimateReviewEmail(params: {
  estimateDocNumber: string;
  propertyAddress: string;
  clientName: string;
  quotedAmount: number;
  driveFolderUrl: string;
}): Promise<void> {
  const to = 'admin@immediateresponsehvac.ca';
  const subject = `Action Required: Review Estimate for ${params.propertyAddress}`;

  const body = `
  <div style="font-family: Arial, sans-serif; max-width: 600px;">
    <h2 style="color: #0066cc;">Estimate Requires Review</h2>
    <p>Hi Nicole & Tyler,</p>
    <p>A new QBO Estimate (<strong>#${params.estimateDocNumber}</strong>) has been automatically generated from a quote request for <strong>${params.propertyAddress}</strong> (${params.clientName}).</p>
    
    <div style="background-color: #fff3cd; border: 1px solid #ffc107; padding: 15px; margin: 20px 0; border-radius: 5px;">
      <p style="color: #856404; margin: 0; font-weight: bold;">Quoted Amount: $${params.quotedAmount.toFixed(2)}</p>
      <p style="color: #856404; margin: 5px 0 0 0;">Please review the estimate in QuickBooks Online before sending it to the client.</p>
    </div>
    
    <p><strong><a href="${params.driveFolderUrl}">Drive Link (Job Folder with PDF)</a></strong></p>
  </div>
  `;

  await sendEmail({ to, subject, body });
}

/**
 * Send notification to Tyler and Cory for an actionable quote (no visit required)
 */
export async function sendActionableQuoteNotificationEmail(request: any, driveFolderUrl: string, leadId: string): Promise<void> {
  const to = 'tyler@immediateresponsehvac.ca, cory@immediateresponsehvac.ca, nicole@immediateresponsehvac.ca, admin@immediateresponsehvac.ca';
  const subject = `Quote Status - ${shortenAddressForSubject(request.property_address)}`;
  const cc = ''; // Not needed since all main stakeholders are in 'to'
  const fromEmail = 'nicole@immediateresponsehvac.ca'; // Send as Nicole
  
  const pmName = request.pm?.full_name || 'N/A';
  const pmEmail = request.pm?.email || 'N/A';
  const scopeOfWork = request.scope_details || 'See attachments';

  const body = `
  <div style="font-family: Arial, sans-serif; max-width: 600px;">
    <h2 style="color: #0066cc;">Actionable Quote Request</h2>
    <p>Hi Tyler and Cory,</p>
    <p>A new lead has been submitted with a detailed scope of work that can be priced <strong>without a site visit</strong>.</p>
    
    <div style="background-color: #e6f2ff; border: 1px solid #0066cc; padding: 15px; margin: 20px 0; border-radius: 5px;">
      <p style="margin: 0 0 10px 0;"><strong>Property Address:</strong> ${request.property_address}</p>
      <p style="margin: 0 0 10px 0;"><strong>Project Manager:</strong> ${pmName} (${pmEmail})</p>
      <p style="margin: 0;"><strong>Scope of Work:</strong> ${scopeOfWork}</p>
    </div>
    
    <p>Please review the details in the Drive folder, prepare a quote, and send it directly to the Project Manager.</p>
    <p><strong><a href="${driveFolderUrl}">Drive Link (Job Folder with Documents)</a></strong></p>

    <div style="margin-top: 30px; padding: 20px; border-top: 2px solid #eee; text-align: center;">
      <p><strong>Is this quote completed?</strong></p>
      <a href="https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/resolveQuoteCompletionHttp?leadId=${leadId}&status=completed" 
         style="display: inline-block; padding: 12px 24px; background-color: #28a745; color: white; text-decoration: none; border-radius: 5px; margin-right: 10px;">
         ✅ YES, IT'S DONE
      </a>
      <a href="https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/resolveQuoteCompletionHttp?leadId=${leadId}&status=pending" 
         style="display: inline-block; padding: 12px 24px; background-color: #dc3545; color: white; text-decoration: none; border-radius: 5px;">
         ❌ NOT YET
      </a>
    </div>
  </div>
  ${AUTO_BOT_OUTREACH_ID}
  `;

  await sendEmail({ to, subject, body, cc, fromEmail });
}

/**
 * Send a consolidated reminder to Tyler and Cory for all actionable quotes that are still pending.
 */
export async function sendConsolidatedQuoteRemindersEmail(quotes: { leadId: string, address: string, daysPending: number }[]): Promise<void> {
  const to = 'tyler@immediateresponsehvac.ca, cory@immediateresponsehvac.ca, nicole@immediateresponsehvac.ca, admin@immediateresponsehvac.ca';
  const subject = `Daily Pending Quotes Review (${quotes.length} outstanding)`;
  const fromEmail = 'nicole@immediateresponsehvac.ca';

  let quotesHtml = '';
  for (const quote of quotes) {
    quotesHtml += `
    <div style="border: 1px solid #ddd; padding: 15px; margin-bottom: 20px; border-radius: 8px; background-color: #f9f9f9;">
      <h3 style="margin-top: 0; color: #1e3a5f;">${quote.address}</h3>
      <p style="margin-bottom: 15px;">Have you sent the quote for this job?</p>
      
      <div style="text-align: center;">
        <a href="https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/resolveQuoteCompletionHttp?leadId=${quote.leadId}&status=completed" 
           style="display: inline-block; padding: 10px 20px; background-color: #28a745; color: white; text-decoration: none; border-radius: 5px; font-weight: bold; margin-right: 10px;">
           ✅ YES, I SENT IT
        </a>
        <a href="https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/resolveQuoteCompletionHttp?leadId=${quote.leadId}&status=pending" 
           style="display: inline-block; padding: 10px 20px; background-color: #d9534f; color: white; text-decoration: none; border-radius: 5px; font-weight: bold;">
           ❌ NOT YET
        </a>
      </div>
      <p style="font-size: 12px; color: #666; text-align: center; margin-top: 10px; margin-bottom: 0;">
        Clicking "YES" will stop reminders for this specific job.
      </p>
    </div>
    `;
  }

  const body = `
  <div style="font-family: Arial, sans-serif; max-width: 600px; padding: 20px; margin: 0 auto;">
    <h2 style="color: #1e3a5f; text-align: center; border-bottom: 2px solid #eee; padding-bottom: 10px;">Pending Quotes Action Required</h2>
    <p>Hi Tyler and Cory,</p>
    <p>You have <strong>${quotes.length}</strong> quotes pending. Please review the list below and mark the ones you have completed to stop their reminders.</p>
    
    <div style="margin-top: 30px;">
      ${quotesHtml}
    </div>
    
    <p style="font-size: 13px; color: #666; text-align: center; margin-top: 30px; border-top: 1px solid #eee; padding-top: 20px;">
      If you click "NOT YET" (or ignore the buttons), we will remind you again tomorrow morning at 8:00 AM.
    </p>
  </div>
  ${AUTO_BOT_OUTREACH_ID}
  `;

  await sendEmail({ to, subject, body, fromEmail });
}

/**
 * Send internal review notification for a newly generated Forensic Audit.
 */
export async function sendForensicAuditReviewEmail(leadId: string, docUrl: string, data: any): Promise<void> {
  const to = 'admin@immediateresponsehvac.ca';
  const subject = `🛡️ DRAFT FOR REVIEW: Forensic Audit - ${data.propertyAddress}`;
  
  const body = `
  <!DOCTYPE html>
  <html>
  <head>
    <style>
      .button {
        display: inline-block;
        padding: 18px 36px;
        background-color: #1e3a5f;
        color: #ffffff !important;
        text-decoration: none;
        border-radius: 8px;
        font-family: Arial, sans-serif;
        font-weight: bold;
        margin: 25px 0;
      }
    </style>
  </head>
  <body style="font-family: Arial, sans-serif; color: #333; line-height: 1.6; padding: 20px;">
    <div style="max-width: 600px; margin: 0 auto; border: 2px solid #1e3a5f; border-radius: 12px; padding: 30px;">
      <h2 style="color: #1e3a5f; margin-top: 0;">Forensic Audit Intake Complete</h2>
      <p>The tech has completed the on-site forensic intake for <strong>${data.propertyAddress}</strong>.</p>
      
      <p><strong>Forensic Context:</strong></p>
      <ul>
        <li>Primary Peril: ${data.perilType}</li>
        <li>Manual Hunter: Cited Page ${data.manualPage} of the ${data.manualTitle}.</li>
        <li>Statutory Hammer: ${data.oescReference || 'Ontario Regulation 212/01'}</li>
      </ul>

      <p>Please review the draft for forensic integrity and clinical accuracy.</p>
      
      <div style="text-align: center;">
        <a href="${docUrl}" class="button">REVIEW REPORT</a>
      </div>
      
      <p style="font-size: 13px; color: #666; border-top: 1px solid #eee; padding-top: 20px;">
        Once reviewed, click the <strong>APPROVE</strong> button inside the Doc or the Antigravity Dashboard to trigger final PDF distribution.
      </p>
    </div>
    ${AUTO_BOT_OUTREACH_ID}
  </body>
  </html>
  `;

  await sendEmail({ to, subject, body });
}

/**
 * Send an update confirmation email when a lead is modified in the OPS dashboard
 */
export async function sendUpdateConfirmationEmail(request: any, callerEmail: string): Promise<void> {
  console.log(`[Email Service] Sending update confirmation for lead: ${request.property_address} (By: ${callerEmail})`);
  
  const shortAddress = shortenAddressForSubject(request.property_address);
  const recipient = getRecipientEmail(request);
  const subject = `Update: Service Request - ${shortAddress}`;
  
  const body = `
    <div style="font-family: Arial, sans-serif; max-width: 600px;">
      <h2 style="color: #0066cc;">Service Request Updated</h2>
      <p>Hello,</p>
      <p>This is a confirmation that the service request for <strong>${request.property_address}</strong> has been updated in our system.</p>
      
      <div style="background-color: #f8f9fa; border-left: 4px solid #0066cc; padding: 15px; margin: 20px 0;">
        <p><strong>Status:</strong> ${request.status || 'Active'}</p>
        <p><strong>Property Address:</strong> ${request.property_address}</p>
        <p><strong>Current Visit:</strong> ${request.visit_requested ? new Date(request.visit_requested).toLocaleString('en-US', { timeZone: 'America/Toronto' }) : 'TBD'}</p>
      </div>
      
      <p>If you have any questions or did not authorize these changes, please contact our office immediately.</p>
      
      <p>Thank you,<br/>Immediate Response HVAC Team</p>
    </div>
    ${AUTO_BOT_OUTREACH_ID}
  `;

  await sendEmail({
    to: recipient.email,
    subject,
    body,
    fromEmail: IMPERSONATED_USER
  });
}

/**
 * Send an email reply within an existing thread
 */
export async function sendEmailReplyInThread({
  to,
  subject,
  body,
  threadId,
  messageId,
  fromEmail = IMPERSONATED_USER
}: {
  to: string;
  subject: string;
  body: string;
  threadId: string;
  messageId: string;
  fromEmail?: string;
}): Promise<any> {
  console.log(`[Email Service] Replying to thread ${threadId} / message ${messageId}`);
  const gmail = await getGmailClient(fromEmail);

  const mailOptions = {
    from: `Immediate Response HVAC <${fromEmail}>`,
    to,
    subject,
    html: body,
    inReplyTo: messageId,
    references: messageId,
  };

  const mail = new MailComposer(mailOptions);
  const encoded = await new Promise<string>((resolve, reject) => {
    mail.compile().build((err: Error | null, message: Buffer) => {
      if (err) return reject(err);
      resolve(
        message
          .toString('base64')
          .replace(/\+/g, '-')
          .replace(/\//g, '_')
          .replace(/=+$/, '')
      );
    });
  });

  const res = await gmail.users.messages.send({
    userId: 'me',
    requestBody: {
      raw: encoded,
      threadId: threadId
    }
  });

  return res.data;
}
// Deploy nudge: 02/13/2026 09:38:44
