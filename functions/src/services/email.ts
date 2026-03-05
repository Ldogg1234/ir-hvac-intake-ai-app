// Deploy nudge: Feb 13 - final handshake fix
// Deployment Force-Refresh: Feb 13 - FAILED_PRECONDITION fix
/**
 * Email Service
 * Sends customer confirmation emails using Gmail API with Service Account Impersonation
 */

import { google } from 'googleapis';
import { gmail_v1 } from 'googleapis';
import { IntakeRequest } from '../types';

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
async function getGmailClient(): Promise<gmail_v1.Gmail> {
  console.log('[Gmail Client] Initializing Gmail API client...');
  console.log(`[Gmail Client] Service Account: ${SERVICE_ACCOUNT}`);
  console.log('--- Using JWT with explicit credentials from Secret Manager ---');
  console.log(`[Gmail Client] Impersonating: ${IMPERSONATED_USER}`);
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
    // JWT constructor parameters: (email, keyFile, key, scopes, subject)
    // 1st: client_email - Service account email
    // 2nd: null - No keyFile path (we're using the key directly)
    // 3rd: private_key - The actual private key
    // 4th: scopes - Gmail API scopes
    // 5th: subject - The user to impersonate (CRITICAL for domain-wide delegation)
    console.log('[Gmail Client] Creating JWT with explicit constructor parameters...');
    const authClient = new google.auth.JWT(
      credentials.client_email,     // 1st: email
      undefined,                     // 2nd: keyFile (null/undefined - not using file)
      privateKey,                    // 3rd: key (the actual private key)
      GMAIL_SCOPES,                  // 4th: scopes
      IMPERSONATED_USER              // 5th: subject (impersonated user)
    );
    
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
 * Create email message in RFC 2822 format with CC support
 */
function createEmailMessage(to: string, subject: string, htmlContent: string, cc?: string): string {
  console.log(`[Email Message] Creating RFC 2822 message...`);
  console.log(`[Email Message] From: Immediate Response HVAC <${IMPERSONATED_USER}>`);
  console.log(`[Email Message] To: ${to}`);
  if (cc) {
    console.log(`[Email Message] CC: ${cc}`);
  }
  console.log(`[Email Message] Subject: ${subject}`);
  
  const headers = [
    `From: Immediate Response HVAC <${IMPERSONATED_USER}>`,
    `To: ${to}`,
  ];
  
  if (cc) {
    headers.push(`Cc: ${cc}`);
  }
  
  headers.push(
    `Subject: ${subject}`,
    'MIME-Version: 1.0',
    'Content-Type: text/html; charset=utf-8',
    '',
    htmlContent
  );
  
  const message = headers.join('\r\n');

  // Encode to base64url
  return Buffer.from(message)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
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
    const encodedMessage = createEmailMessage(
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
// Deploy nudge: 02/13/2026 09:38:44
