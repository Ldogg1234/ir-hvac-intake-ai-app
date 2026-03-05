/**
 * Cloud Functions Entry Point
 * HVAC Lead Intake Automation for Immediate Response HVAC
 */

import { onRequest, onCall, HttpsError } from 'firebase-functions/v2/https';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import * as admin from 'firebase-admin';
import { alloydbPassword, gmailServiceAccountKey, qboClientId, qboClientSecret, qboRealmId } from './config';

// Initialize Firebase Admin
admin.initializeApp();

// Lazy load handlers to avoid initialization timeout
let handlers: typeof import('./handlers/lead-intake') | null = null;
let reportService: typeof import('./services/reportGenerator') | null = null;
let qboSyncHandlers: typeof import('./handlers/qbo-sync') | null = null;
let qboService: typeof import('./services/quickbooks') | null = null;

async function getHandlers() {
  if (!handlers) {
    handlers = await import('./handlers/lead-intake');
  }
  return handlers;
}

async function getReportService() {
  if (!reportService) {
    reportService = await import('./services/reportGenerator');
  }
  return reportService;
}

async function getQboSyncHandlers() {
  if (!qboSyncHandlers) {
    qboSyncHandlers = await import('./handlers/qbo-sync');
  }
  return qboSyncHandlers;
}

async function getQboService() {
  if (!qboService) {
    qboService = await import('./services/quickbooks');
  }
  return qboService;
}

/**
 * Verify Firebase Auth token from request
 * Checks X-Firebase-ID-Token header first (for Cloud Run IAM auth flow),
 * then falls back to Authorization header
 * Returns the decoded token or null if invalid
 */
async function verifyFirebaseToken(req: any): Promise<admin.auth.DecodedIdToken | null> {
  // First check custom header (used when Google access token is in Authorization)
  let token = req.headers['x-firebase-id-token'];

  // Fall back to Authorization header if no custom header
  if (!token) {
    const authHeader = req.headers.authorization;
    if (authHeader && authHeader.startsWith('Bearer ')) {
      token = authHeader.split('Bearer ')[1];
    }
  }

  if (!token) {
    console.log('No Firebase ID token found in headers');
    return null;
  }

  try {
    return await admin.auth().verifyIdToken(token);
  } catch (error) {
    console.error('Token verification failed:', error);
    return null;
  }
}

/**
 * POST /intake
 * Submit a new lead intake form
 */
export const intake = onRequest(
  {
    region: 'us-central1',
    timeoutSeconds: 120,
    memory: '512MiB',
    cors: true,
    vpcConnector: 'hvac-connector',
    vpcConnectorEgressSettings: 'ALL_TRAFFIC',
    secrets: [alloydbPassword, gmailServiceAccountKey],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ success: false, error: 'Method not allowed' });
      return;
    }

    // Verify Firebase Auth token
    const decodedToken = await verifyFirebaseToken(req);
    if (!decodedToken) {
      res.status(401).json({ success: false, error: 'Unauthorized - please sign in' });
      return;
    }

    console.log(`Intake request from user: ${decodedToken.email}`);

    try {
      const { handleLeadIntake } = await getHandlers();
      const result = await handleLeadIntake(req.body);
      res.status(200).json(result);
    } catch (error) {
      console.error('Intake error:', error);
      const message = error instanceof Error ? error.message : 'Unknown error';
      res.status(500).json({ success: false, error: message });
    }
  }
);

/**
 * GET /pmSearch?q={name}
 * Search for PM by name (fuzzy matching)
 */
export const pmSearch = onRequest(
  {
    region: 'us-central1',
    timeoutSeconds: 30,
    memory: '256MiB',
    cors: true,
    vpcConnector: 'hvac-connector',
    vpcConnectorEgressSettings: 'ALL_TRAFFIC',
    secrets: [alloydbPassword],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async (req, res) => {
    if (req.method !== 'GET') {
      res.status(405).json({ success: false, error: 'Method not allowed' });
      return;
    }

    // Verify Firebase Auth token
    const decodedToken = await verifyFirebaseToken(req);
    if (!decodedToken) {
      res.status(401).json({ success: false, error: 'Unauthorized - please sign in' });
      return;
    }

    const query = req.query.q as string;
    if (!query || query.trim().length < 2) {
      res.status(400).json({ success: false, error: 'Query must be at least 2 characters' });
      return;
    }

    try {
      const { handlePMSearch } = await getHandlers();
      const result = await handlePMSearch(query);
      res.status(200).json(result);
    } catch (error) {
      console.error('PM search error:', error);
      const message = error instanceof Error ? error.message : 'Unknown error';
      res.status(500).json({ success: false, error: message });
    }
  }
);

/**
 * Health check endpoint
 */
export const health = onRequest(
  {
    region: 'us-central1',
    cors: true,
  },
  (req, res) => {
    res.status(200).json({
      status: 'healthy',
      service: 'ir-hvac-intake-ai',
      timestamp: new Date().toISOString(),
    });
  }
);

/**
 * Public intake endpoint - NO IAM REQUIRED
 * Uses default compute service account (not hvac-intake-sa) so org policy doesn't block
 * Validates Firebase ID tokens and processes internally
 */
export const intakePublic = onRequest(
  {
    region: 'us-central1',
    timeoutSeconds: 120,
    memory: '512MiB',
    cors: true,
    vpcConnector: 'hvac-connector',
    vpcConnectorEgressSettings: 'ALL_TRAFFIC',
    secrets: [alloydbPassword, gmailServiceAccountKey],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async (req, res) => {
    // Handle CORS preflight
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') {
      res.status(204).send('');
      return;
    }

    if (req.method !== 'POST') {
      res.status(405).json({ success: false, error: 'Method not allowed' });
      return;
    }

    // Validate Firebase ID token
    const decodedToken = await verifyFirebaseToken(req);
    if (!decodedToken) {
      res.status(401).json({ success: false, error: 'Unauthorized - please sign in' });
      return;
    }

    // Check domain
    const email = decodedToken.email || '';
    if (!email.endsWith('@immediateresponsehvac.ca')) {
      res.status(403).json({ success: false, error: 'Access denied - must use company email' });
      return;
    }

    console.log(`intakePublic: Request from ${email}`);
    console.log('intakePublic: Request body:', JSON.stringify(req.body, null, 2));

    try {
      const { handleLeadIntake } = await getHandlers();
      const result = await handleLeadIntake(req.body);
      console.log('intakePublic: Result:', JSON.stringify(result, null, 2));
      res.status(200).json(result);
    } catch (error: any) {
      console.error('intakePublic error:', error);
      console.error('Error stack:', error?.stack);
      const message = error?.message || 'Unknown error';
      res.status(500).json({ success: false, error: message });
    }
  }
);

/**
 * Public PM search endpoint - NO IAM REQUIRED
 */
export const pmSearchPublic = onRequest(
  {
    region: 'us-central1',
    timeoutSeconds: 30,
    memory: '256MiB',
    cors: true,
    vpcConnector: 'hvac-connector',
    vpcConnectorEgressSettings: 'ALL_TRAFFIC',
    secrets: [alloydbPassword],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async (req, res) => {
    // Handle CORS preflight
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') {
      res.status(204).send('');
      return;
    }

    if (req.method !== 'GET') {
      res.status(405).json({ success: false, error: 'Method not allowed' });
      return;
    }

    // Validate Firebase ID token
    const decodedToken = await verifyFirebaseToken(req);
    if (!decodedToken) {
      res.status(401).json({ success: false, error: 'Unauthorized - please sign in' });
      return;
    }

    const email = decodedToken.email || '';
    if (!email.endsWith('@immediateresponsehvac.ca')) {
      res.status(403).json({ success: false, error: 'Access denied - must use company email' });
      return;
    }

    const query = req.query.q as string;
    if (!query || query.trim().length < 2) {
      res.status(400).json({ success: false, error: 'Query must be at least 2 characters' });
      return;
    }

    console.log(`pmSearchPublic: Searching for "${query}" by ${email}`);

    try {
      const { handlePMSearch } = await getHandlers();
      const result = await handlePMSearch(query);
      res.status(200).json(result);
    } catch (error: any) {
      console.error('pmSearchPublic error:', error);
      const message = error?.message || 'Unknown error';
      res.status(500).json({ success: false, error: message });
    }
  }
);

/**
 * POST /api/clockIn
 * Verify technician GPS proximity to job site.
 * No Firebase Auth required — the clock-in URL is shared via calendar invite.
 * Expects JSON body: { lat: number, lng: number, address: string }
 */
export const clockInPublic = onRequest(
  {
    region: 'us-central1',
    timeoutSeconds: 30,
    memory: '256MiB',
    cors: true,
  },
  async (req, res) => {
    // Handle CORS preflight
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.set('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.status(204).send('');
      return;
    }

    if (req.method !== 'POST') {
      res.status(405).json({ success: false, error: 'Method not allowed' });
      return;
    }

    const { lat, lng, address } = req.body || {};

    if (typeof lat !== 'number' || typeof lng !== 'number' || !address) {
      res.status(400).json({ success: false, error: 'Missing required fields: lat (number), lng (number), address (string)' });
      return;
    }

    try {
      const { geocodeAddress, haversineDistance } = await import('./services/location');
      const { config } = await import('./config');

      const targetCoords = await geocodeAddress(address);
      const distanceMetres = haversineDistance({ lat, lng }, targetCoords);
      const threshold = config.googleMaps.proximityThresholdMetres;
      const withinRange = distanceMetres <= threshold;

      console.log(`[ClockIn] Tech (${lat}, ${lng}) is ${Math.round(distanceMetres)}m from "${address}" — ${withinRange ? 'WITHIN' : 'OUTSIDE'} ${threshold}m`);

      res.status(200).json({
        success: true,
        withinRange,
        distanceMetres: Math.round(distanceMetres),
        thresholdMetres: threshold,
      });
    } catch (error: any) {
      console.error('clockInPublic error:', error);
      res.status(500).json({ success: false, error: error?.message || 'Proximity check failed' });
    }
  }
);

/**
 * Firebase Callable: Submit lead intake (handles Firebase Auth automatically)
 */
export const submitIntake = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 120,
    memory: '512MiB',
    vpcConnector: 'hvac-connector',
    vpcConnectorEgressSettings: 'ALL_TRAFFIC',
    secrets: [alloydbPassword, gmailServiceAccountKey],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async (request) => {
    console.log('submitIntake called, auth:', request.auth?.uid || 'none');

    // Check if user is authenticated
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'You must be signed in to submit a lead');
    }

    console.log(`Intake request from user: ${request.auth.token.email}`);
    console.log('Request data:', JSON.stringify(request.data, null, 2));

    try {
      const { handleLeadIntake } = await getHandlers();
      const result = await handleLeadIntake(request.data);
      console.log('Intake result:', JSON.stringify(result, null, 2));
      return result;
    } catch (error: any) {
      console.error('Intake error:', error);
      console.error('Error stack:', error?.stack);
      const message = error instanceof Error ? error.message : 'Unknown error';
      throw new HttpsError('internal', message);
    }
  }
);

/**
 * Firebase Callable: Search PMs (handles Firebase Auth automatically)
 */
export const searchPM = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 30,
    memory: '256MiB',
    vpcConnector: 'hvac-connector',
    vpcConnectorEgressSettings: 'ALL_TRAFFIC',
    secrets: [alloydbPassword],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async (request) => {
    // Check if user is authenticated
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'You must be signed in');
    }

    const query = request.data?.query as string;
    if (!query || query.trim().length < 2) {
      throw new HttpsError('invalid-argument', 'Query must be at least 2 characters');
    }

    try {
      const { handlePMSearch } = await getHandlers();
      const result = await handlePMSearch(query);
      return result;
    } catch (error) {
      console.error('PM search error:', error);
      const message = error instanceof Error ? error.message : 'Unknown error';
      throw new HttpsError('internal', message);
    }
  }
);

/**
 * Scheduled function: Move unscheduled events
 * Runs daily at 6 AM Mountain Time (13:00 UTC in winter, 12:00 UTC in summer)
 * 
 * Finds all events from yesterday with [UNSCHEDULED] in the title
 * and moves them to today at the same time.
 */
export const moveUnscheduledEvents = onSchedule(
  {
    schedule: '0 6 * * *', // 6 AM Mountain Time
    timeZone: 'America/Edmonton',
    region: 'us-central1',
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async () => {
    const { moveUnscheduledEvents: moveEvents } = await import('./services/calendar');

    console.log('Starting daily unscheduled events cleanup...');
    const result = await moveEvents();
    console.log(`Completed: ${result.moved} events moved, ${result.errors} errors`);
  }
);
/**
 * Firebase Callable: Generate a professional report using Gemini 1.5 Flash
 */
export const getProfessionalReport = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 30, // Report generation should be quick with Flash
    memory: '256MiB',
    secrets: [alloydbPassword], // In case it's needed for other parts
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', 'You must be signed in');
    }

    const { notes } = request.data || {};
    if (!notes) {
      throw new HttpsError('invalid-argument', 'Technician notes are required');
    }

    try {
      const { generateProfessionalReport } = await getReportService();
      const report = await generateProfessionalReport(notes);
      return report;
    } catch (error: any) {
      console.error('Report generation error:', error);
      throw new HttpsError('internal', error?.message || 'Failed to generate report');
    }
  }
);

// ============================================
// QBO Integration Functions
// ============================================

/**
 * QBO OAuth Callback — one-time setup
 *
 * 1. Visit this function's URL with no query params → redirects to Intuit consent screen
 * 2. After consent, Intuit redirects back with ?code=... → exchanges for tokens
 * 3. Tokens are stored in Firestore qbo_tokens/primary
 *
 * After first use, you can leave this deployed (harmless) or delete it.
 */
export const qboAuthCallback = onRequest(
  {
    region: 'us-central1',
    timeoutSeconds: 30,
    secrets: [qboClientId, qboClientSecret, qboRealmId],
  },
  async (req, res) => {
    const qbo = await getQboService();

    // Must match exactly what's registered in Intuit Developer Portal
    const redirectUri = 'https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/qboAuthCallback';

    // If there's a code param, we're in the callback phase
    if (req.query.code) {
      try {
        await qbo.exchangeCodeForTokens(redirectUri, req.url);
        res.status(200).send(
          '<h1>QBO Connected!</h1><p>OAuth tokens have been stored. You can close this tab.</p>'
        );
      } catch (error: any) {
        console.error('QBO OAuth error:', error);
        res.status(500).send(`<h1>OAuth Error</h1><pre>${error?.message}</pre>`);
      }
      return;
    }

    // No code — redirect to Intuit consent screen
    const authUrl = qbo.getAuthorizationUrl(redirectUri);
    res.redirect(authUrl);
  }
);

/**
 * Firestore Trigger: New lead → QBO sync
 * Creates QBO Customer, Project, and Estimate when a lead is written to Firestore.
 */
export const onLeadCreated = onDocumentCreated(
  {
    document: 'leads/{leadId}',
    region: 'us-central1',
    timeoutSeconds: 60,
    memory: '256MiB',
    secrets: [qboClientId, qboClientSecret, qboRealmId],
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      console.warn('onLeadCreated: No data in event');
      return;
    }

    const leadId = event.params.leadId;
    const leadData = snapshot.data();

    console.log(`onLeadCreated: Processing lead ${leadId}`);

    try {
      const { handleLeadToQbo } = await getQboSyncHandlers();
      await handleLeadToQbo(leadId, leadData);
    } catch (error: any) {
      console.error(`onLeadCreated: Failed for lead ${leadId}:`, error?.message);
      // Error is already recorded in Firestore by handleLeadToQbo
    }
  }
);

/**
 * Scheduled function: Sync technician assignments from Google Calendar to QBO
 * Runs every 5 minutes. Checks for calendar events with new attendees and
 * updates the corresponding QBO Estimate's "Technician" custom field.
 */
export const syncCalendarTechnicians = onSchedule(
  {
    schedule: 'every 5 minutes',
    region: 'us-central1',
    timeoutSeconds: 60,
    memory: '256MiB',
    secrets: [qboClientId, qboClientSecret, qboRealmId],
    serviceAccount: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
  },
  async () => {
    const { handleCalendarTechSync } = await getQboSyncHandlers();
    const result = await handleCalendarTechSync();
    console.log(
      `syncCalendarTechnicians: ${result.processed} processed, ${result.updated} updated, ${result.errors} errors`
    );
  }
);
