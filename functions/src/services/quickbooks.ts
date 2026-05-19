/**
 * QuickBooks Online Service
 * Handles OAuth token management, customer/project/estimate operations
 */

import * as admin from 'firebase-admin';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const OAuthClient = require('intuit-oauth');

export function getQboConfigLocal() {
  const clientId = process.env.QBO_CLIENT_ID;
  const clientSecret = process.env.QBO_CLIENT_SECRET;
  const realmId = process.env.QBO_REALM_ID;

  if (!clientId || !clientSecret) {
    throw new Error('QBO credentials not fully configured in environment variables');
  }

  if (!realmId) {
    throw new Error('QBO_REALM_ID not set in environment variables');
  }

  return { clientId, clientSecret, realmId };
}
const QBO_BASE_URL = 'https://quickbooks.api.intuit.com';
const QBO_SANDBOX_URL = 'https://sandbox-quickbooks.api.intuit.com';

// Use production by default; set to true for sandbox testing
const USE_SANDBOX = false;

function getBaseUrl(): string {
  return USE_SANDBOX ? QBO_SANDBOX_URL : QBO_BASE_URL;
}

// ============================================
// OAuth Token Management
// ============================================

interface QboTokens {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expires_in: number;
  x_refresh_token_expires_in: number;
  updated_at: FirebaseFirestore.Timestamp;
}

/**
 * Create an OAuthClient instance using secrets from environment
 */
function createOAuthClient(): any {
  const { clientId, clientSecret } = getQboConfigLocal();
  return new OAuthClient({
    clientId: clientId.replace(/\s+/g, ''),
    clientSecret: clientSecret.replace(/\s+/g, ''),
    environment: USE_SANDBOX ? 'sandbox' : 'production',
    redirectUri: (process.env.QBO_REDIRECT_URI || '').replace(/\s+/g, ''),
  });
}

/**
 * Get the OAuth authorization URL for initial consent flow
 */
export function getAuthorizationUrl(redirectUri: string): string {
  const { clientId, clientSecret } = getQboConfigLocal();
  const oauthClient = new OAuthClient({
    clientId: clientId.replace(/\s+/g, ''),
    clientSecret: clientSecret.replace(/\s+/g, ''),
    environment: USE_SANDBOX ? 'sandbox' : 'production',
    redirectUri: redirectUri,
  });

  return oauthClient.authorizeUri({
    scope: [
      OAuthClient.scopes.Accounting,
      'com.intuit.quickbooks.accounting',
      'project-management.project',
    ],
    state: 'imr-hvac-qbo',
  });
}

/**
 * Exchange authorization code for tokens and store in Firestore
 */
export async function exchangeCodeForTokens(
  redirectUri: string,
  url: string
): Promise<void> {
  const oauthClient = new OAuthClient({
    clientId: (process.env.QBO_CLIENT_ID || '').replace(/\s+/g, ''),
    clientSecret: (process.env.QBO_CLIENT_SECRET || '').replace(/\s+/g, ''),
    environment: USE_SANDBOX ? 'sandbox' : 'production',
    redirectUri,
  });

  const authResponse = await oauthClient.createToken(url);
  const tokens = authResponse.getJson();

  await admin.firestore().collection('qbo_tokens').doc('primary').set({
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
    token_type: tokens.token_type,
    expires_in: tokens.expires_in,
    x_refresh_token_expires_in: tokens.x_refresh_token_expires_in,
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log('[QBO] OAuth tokens stored in Firestore');
}

// ============================================
// Permanent Self-Healing Token Management
// ============================================

/**
 * Sends a "Last Stand" Gmail alert to admin when QBO re-auth is required.
 * Non-blocking — logs error if email fails but never prevents function execution.
 */
async function sendQboAuthBrokenAlert(reason: string): Promise<void> {
  try {
    const { sendEmail } = await import('./email');
    await sendEmail({
      to: 'admin@immediateresponsehvac.ca',
      subject: '🚨 URGENT: QuickBooks Re-Authorization Required',
      body: [
        '<h2 style="color:red">QuickBooks Online Authentication Failure</h2>',
        `<p><strong>Time:</strong> ${new Date().toISOString()}</p>`,
        `<p><strong>Reason:</strong> ${reason}</p>`,
        '<p>The QBO refresh token has been revoked or expired. No leads will sync to QuickBooks until re-authorization is completed.</p>',
        '<h3>Action Required:</h3>',
        '<p><a href="https://us-central1-immediate-response-ai-b18b8.cloudfunctions.net/qboAuthCallback/start" style="background:#dc2626;color:white;padding:10px 20px;text-decoration:none;border-radius:4px">Re-Authorize QuickBooks Now</a></p>',
      ].join('\n'),
    });
    console.error('[QBO] 🚨 Auth-broken alert sent to admin');
  } catch (alertErr: any) {
    console.error('[QBO] Failed to send auth-broken alert:', alertErr?.message);
  }
}

/**
 * Get a valid access token, refreshing if needed.
 *
 * ARCHITECTURE:
 * - Uses a Firestore document field `refresh_lock` as a distributed mutex.
 * - Only ONE Cloud Function instance performs the actual HTTP refresh at a time.
 * - Others wait up to 6 seconds for the refreshing instance to finish.
 * - On success, BOTH access_token AND refresh_token are always written back
 *   (Intuit rotates the refresh_token on every use — we MUST always save the new one).
 * - On unrecoverable auth failure, fires a "Last Stand" Gmail alert.
 */
export async function getAccessToken(): Promise<string> {
  const tokenDocRef = admin.firestore().collection('qbo_tokens').doc('primary');

  // --- PHASE 1: Fast read (no transaction) ---
  const snap = await tokenDocRef.get();
  if (!snap.exists) {
    throw new Error('QBO tokens not found. Run the OAuth consent flow via /qboAuthCallback');
  }

  const tok = snap.data() as QboTokens & { refresh_lock?: boolean; locked_at?: admin.firestore.Timestamp; auth_broken?: boolean };
  
  // IMMEDIATELY BREAK if the token is already known to be broken by a previous failure
  if (tok.auth_broken) {
    throw new Error('QBO_AUTH_BROKEN: The Refresh token is invalid, please Authorize again.');
  }

  const updatedAt = tok.updated_at?.toDate() ?? new Date(0);
  // Use 5-minute buffer before expiry
  const expiresAt = new Date(updatedAt.getTime() + ((tok.expires_in ?? 3600) - 300) * 1000);

  if (new Date() < expiresAt && !tok.refresh_lock) {
    return tok.access_token; // Token is fresh — fast path
  }

  // --- PHASE 2: Acquire distributed lock via Firestore transaction ---
  console.log('[QBO] Token needs refresh. Acquiring distributed lock...');

  type LockResult =
    | { status: 'VALID'; token: string }
    | { status: 'LOCKED_BY_OTHER' }
    | { status: 'ACQUIRED_LOCK'; snapshot: QboTokens };

  let lockResult: LockResult;

  try {
    lockResult = await admin.firestore().runTransaction(async (tx) => {
      const d = await tx.get(tokenDocRef);
      if (!d.exists) throw new Error('QBO_TOKENS_DELETED');

      const data = d.data() as QboTokens & { refresh_lock?: boolean; locked_at?: admin.firestore.Timestamp };
      const tUpdatedAt = data.updated_at?.toDate() ?? new Date(0);
      const tExpiresAt = new Date(tUpdatedAt.getTime() + ((data.expires_in ?? 3600) - 300) * 1000);

      // Another instance may have already refreshed while we waited for the transaction
      if (new Date() < tExpiresAt && !data.refresh_lock) {
        return { status: 'VALID', token: data.access_token } as LockResult;
      }

      if (data.refresh_lock) {
        const lockAge = Date.now() - (data.locked_at?.toMillis() ?? 0);
        if (lockAge < 90_000) {
          // Lock is < 90s — another instance is actively refreshing
          return { status: 'LOCKED_BY_OTHER' } as LockResult;
        }
        console.warn('[QBO] Stale lock detected (>90s), breaking it...');
      }

      // Acquire the lock atomically
      tx.update(tokenDocRef, {
        refresh_lock: true,
        locked_at: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { status: 'ACQUIRED_LOCK', snapshot: data } as LockResult;
    });
  } catch (txErr: any) {
    console.error('[QBO] Transaction failed:', txErr.message);
    throw txErr;
  }

  // --- PHASE 3: Handle lock result ---
  if (lockResult.status === 'VALID') {
    return lockResult.token;
  }

  if (lockResult.status === 'LOCKED_BY_OTHER') {
    // Wait 3s and retry — the refreshing instance will have written new tokens
    console.log('[QBO] Waiting for peer instance to finish refreshing...');
    await new Promise((r) => setTimeout(r, 3000));
    return getAccessToken();
  }

  // --- PHASE 4: We hold the lock — perform the HTTP refresh ---
  const oldTok = lockResult.snapshot;
  console.log('[QBO] Lock acquired. Performing token refresh with Intuit...');

  try {
    const oauthClient = createOAuthClient();
    oauthClient.setToken({
      access_token: oldTok.access_token,
      refresh_token: oldTok.refresh_token,
      token_type: oldTok.token_type,
      expires_in: oldTok.expires_in,
      x_refresh_token_expires_in: oldTok.x_refresh_token_expires_in,
      createdAt: oldTok.updated_at?.toMillis() ?? Date.now(),
    });

    await oauthClient.refresh();

    // CRITICAL: Always call getToken() after refresh — Intuit ROTATES the refresh_token
    const newTok = oauthClient.getToken();
    if (!newTok.access_token || !newTok.refresh_token) {
      throw new Error('QBO refresh response missing tokens');
    }

    // Write ALL new tokens back to Firestore and release lock
    await tokenDocRef.set({
      access_token: newTok.access_token,
      refresh_token: newTok.refresh_token,          // ← CRITICAL: always save new refresh token
      token_type: newTok.token_type ?? 'bearer',
      expires_in: newTok.expires_in ?? 3600,
      x_refresh_token_expires_in: newTok.x_refresh_token_expires_in ?? 8726400,
      updated_at: admin.firestore.FieldValue.serverTimestamp(),
      refresh_lock: false,
      locked_at: null,
    });

    console.log('[QBO] ✅ Tokens refreshed and persisted. Lock released.');
    return newTok.access_token;

  } catch (refreshErr: any) {
    // Release lock (best effort) then handle the error
    await tokenDocRef.update({ refresh_lock: false, locked_at: null }).catch(() => {});

    const msg: string = refreshErr?.message ?? '';
    const isRevoked = msg.includes('invalid_grant') || msg.includes('invalid_rapt') || msg.includes('Refresh token');

    if (isRevoked) {
      console.error('[QBO] 🚨 LAST STAND: Refresh token is revoked. Firing admin alert...');
      // Mark Firestore so future calls don't loop
      await tokenDocRef.update({ auth_broken: true, auth_broken_at: admin.firestore.FieldValue.serverTimestamp() }).catch(() => {});
      sendQboAuthBrokenAlert(msg).catch(() => {}); // fire-and-forget
      throw new Error(`QBO_AUTH_BROKEN: ${msg}`);
    }

    throw refreshErr;
  }
}

/**
 * Force a token refresh cycle (used by Doctor AI auto-remedy).
 * Invalidates the local expiry buffer and calls getAccessToken to run the lock.
 */
export async function forceTokenRefresh(): Promise<boolean> {
  console.log('[QBO] Forcing a proactive token refresh cycle...');
  const tokenDocRef = admin.firestore().collection('qbo_tokens').doc('primary');
  await tokenDocRef.update({ expires_in: 0 }).catch(() => {});
  
  try {
    await getAccessToken();
    console.log('[QBO] Proactive token refresh cycle successful.');
    return true;
  } catch (error) {
    console.error('[QBO] Proactive token refresh cycle failed:', error);
    return false;
  }
}

/**
 * Get the QBO Realm ID from environment
 */
function getRealmId(): string {
  const { realmId } = getQboConfigLocal();
  return realmId.replace(/\s+/g, '');
}

// ============================================
// QBO API Helpers
// ============================================

interface QboApiOptions {
  method: 'GET' | 'POST';
  endpoint: string;
  body?: any;
  queryParams?: Record<string, string>;
}

/**
 * Make an authenticated QBO API call.
 * Automatically retries ONCE if the API returns 401 (token expiry race condition).
 */
export async function qboApi<T = any>(options: QboApiOptions): Promise<T> {
  return qboApiWithRetry<T>(options, 0);
}

export async function qboApiWithRetry<T = any>(options: QboApiOptions, retryCount: number = 0): Promise<T> {
  const accessToken = await getAccessToken();
  const realmId = getRealmId();
  const baseUrl = getBaseUrl();

  let url = `${baseUrl}/v3/company/${realmId}/${options.endpoint}`;

  if (options.queryParams) {
    const params = new URLSearchParams(options.queryParams);
    url += `?${params.toString()}`;
  }

  const headers: Record<string, string> = {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
    'Content-Type': 'application/json',
  };

  const fetchOptions: RequestInit = {
    method: options.method,
    headers,
  };

  if (options.body) {
    fetchOptions.body = JSON.stringify(options.body);
  }

  const response = await fetch(url, fetchOptions);

  // Auto-retry on 401: force a token refresh then retry once
  if (response.status === 401 && retryCount === 0) {
    console.warn('[QBO] Got 401 — forcing token refresh and retrying once...');
    // Invalidate the current token so getAccessToken refreshes it
    await admin.firestore().collection('qbo_tokens').doc('primary')
      .update({ expires_in: 0 })
      .catch(() => {});
    return qboApiWithRetry<T>(options, 1);
  }

  // Exponential backoff for 429 ThrottleExceeded (up to 3 retries)
  if (response.status === 429 && retryCount < 3) {
    const delay = Math.pow(2, retryCount) * 2000 + Math.random() * 1000;
    console.warn(`[QBO] Got 429 ThrottleExceeded — retrying in ${Math.round(delay)}ms (attempt ${retryCount + 1}/3)...`);
    await new Promise(resolve => setTimeout(resolve, delay));
    return qboApiWithRetry<T>(options, retryCount + 1);
  }

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`[QBO] API error ${response.status}: ${errorText}`);
    throw new Error(`QBO API ${response.status}: ${errorText}`);
  }

  return response.json() as Promise<T>;
}

/**
 * Execute a GraphQL query against QBO.
 * Required for creating TRUE Projects (Project Management API).
 */
export async function qboGraphQL<T = any>(query: string, variables: any = {}, retryCount: number = 0): Promise<T> {
  const accessToken = await getAccessToken();

  // The GraphQL endpoints
  const graphqlUrl = USE_SANDBOX 
    ? 'https://sandbox.api.intuit.com/graphql' 
    : 'https://qb.api.intuit.com/graphql';

  const headers: Record<string, string> = {
    Authorization: `Bearer ${accessToken}`,
    Accept: 'application/json',
    'Content-Type': 'application/json',
  };

  const body = {
    query,
    variables,
  };

  const response = await fetch(graphqlUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  // Auto-retry on 401: force a token refresh then retry once
  if (response.status === 401 && retryCount === 0) {
    console.warn('[QBO] Got 401 from GraphQL — forcing token refresh and retrying once...');
    await admin.firestore().collection('qbo_tokens').doc('primary')
      .update({ expires_in: 0 })
      .catch(() => {});
    return qboGraphQL<T>(query, variables, 1);
  }

  // Exponential backoff for 429 ThrottleExceeded (up to 3 retries)
  if (response.status === 429 && retryCount < 3) {
    const delay = Math.pow(2, retryCount) * 2000 + Math.random() * 1000;
    console.warn(`[QBO] Got 429 ThrottleExceeded from GraphQL — retrying in ${Math.round(delay)}ms (attempt ${retryCount + 1}/3)...`);
    await new Promise(resolve => setTimeout(resolve, delay));
    return qboGraphQL<T>(query, variables, retryCount + 1);
  }

  const responseText = await response.text();
  let json: any;
  try {
    json = JSON.parse(responseText);
  } catch (err: any) {
    console.error(`[QBO] GraphQL failed to parse JSON. Status: ${response.status}. Response Body:`, responseText);
    throw new Error(`Invalid JSON from GraphQL: ${err.message}`);
  }

  if (response.status !== 200) {
    console.error(`[QBO] GraphQL HTTP error:`, JSON.stringify(json));
    throw new Error(`[QBO] GraphQL failed: ${response.statusText} - ${JSON.stringify(json)}`);
  }

  if (json.errors && json.errors.length > 0) {
    console.error(`[QBO] GraphQL Errors:`, JSON.stringify(json.errors, null, 2));
    throw new Error(`[QBO] GraphQL returned errors: ${json.errors[0].message}`);
  }

  return json.data as T;
}


/**
 * Run a QBO query (SELECT statement)
 */
export async function qboQuery<T = any>(query: string): Promise<T> {
  return qboApi<T>({
    method: 'GET',
    endpoint: 'query',
    queryParams: { query },
  });
}

/**
 * Searches for a Bill or Purchase by exact matching criteria to prevent false-positive deduplication.
 */
export async function findTransactionExactMatch(docNumber: string, amount: number, date: string, vendorName: string): Promise<any | null> {
  if (!docNumber || docNumber === 'N/A' || !amount || !date || !vendorName) return null;
  
  const cleanDoc = String(docNumber).trim().replace(/'/g, "\\'");
  
  try {
    const normalizedName = normalizeVendorName(vendorName);
    const vendor = await findVendorByName(normalizedName);
    if (!vendor) return null;

    // 1. Search Bills
    const billRes = await qboQuery(`SELECT * FROM Bill WHERE DocNumber = '${cleanDoc}' AND VendorRef = '${vendor.Id}' AND TxnDate = '${date}'`);
    const bills = billRes?.QueryResponse?.Bill || [];
    const bMatch = bills.find((b: any) => Math.abs(b.TotalAmt - amount) < 0.01);
    if (bMatch) return { ...bMatch, type: 'Bill' };

    // 2. Search Purchases (Credit Card / Check / Cash)
    const purchaseRes = await qboQuery(`SELECT * FROM Purchase WHERE DocNumber = '${cleanDoc}' AND VendorRef = '${vendor.Id}' AND TxnDate = '${date}'`);
    const purchases = purchaseRes?.QueryResponse?.Purchase || [];
    const pMatch = purchases.find((p: any) => Math.abs(p.TotalAmt - amount) < 0.01);
    if (pMatch) return { ...pMatch, type: 'Purchase' };
  } catch (err: any) {
    console.warn(`[QBO] findTransactionExactMatch failed for '${docNumber}':`, err.message);
  }

  return null;
}

/**
 * Searches for a Bill or Purchase by its DocNumber (Ref No).
 * Useful for finding original bills from credits where amount doesn't match.
 */
export async function findTransactionByDocNumber(docNumber: string): Promise<any | null> {
  if (!docNumber || docNumber === 'N/A') return null;
  
  const cleanDoc = String(docNumber).trim().replace(/'/g, "\\'");
  
  try {
    // 1. Search Bills
    const billRes = await qboQuery(`SELECT * FROM Bill WHERE DocNumber = '${cleanDoc}'`);
    const bills = billRes?.QueryResponse?.Bill || [];
    if (bills.length > 0) return { ...bills[0], type: 'Bill' };

    // 2. Search Purchases (Credit Card / Check / Cash)
    const purchaseRes = await qboQuery(`SELECT * FROM Purchase WHERE DocNumber = '${cleanDoc}'`);
    const purchases = purchaseRes?.QueryResponse?.Purchase || [];
    if (purchases.length > 0) return { ...purchases[0], type: 'Purchase' };
  } catch (err: any) {
    console.warn(`[QBO] findTransactionByDocNumber failed for '${docNumber}':`, err.message);
  }

  return null;
}

/**
 * Secondary verification: search by Amount + Date + Vendor
 */
export async function findTransactionByDetails(amount: number, date: string, vendorName: string): Promise<any | null> {
  if (!amount || !date || !vendorName) return null;
  
  try {
    const normalizedName = normalizeVendorName(vendorName);
    const vendor = await findVendorByName(normalizedName);
    if (!vendor) return null;

    // Search Purchases first (most common for receipts)
    const pRes = await qboQuery(`SELECT * FROM Purchase WHERE TxnDate = '${date}' AND VendorRef = '${vendor.Id}'`);
    const purchases = pRes?.QueryResponse?.Purchase || [];
    const pMatch = purchases.find((p: any) => Math.abs(p.TotalAmt - amount) < 0.01);
    if (pMatch) return { ...pMatch, type: 'Purchase' };

    // Search Bills
    const bRes = await qboQuery(`SELECT * FROM Bill WHERE TxnDate = '${date}' AND VendorRef = '${vendor.Id}'`);
    const bills = bRes?.QueryResponse?.Bill || [];
    const bMatch = bills.find((b: any) => Math.abs(b.TotalAmt - amount) < 0.01);
    if (bMatch) return { ...bMatch, type: 'Bill' };

  } catch (err: any) {
    console.warn(`[QBO] findTransactionByDetails failed:`, err.message);
  }

  return null;
}

/**
 * Fuzzy search: search by Amount + Vendor within a date range (+/- 5 days)
 * Used to catch Payment Receipts that have a different date than the original Bill.
 */
export async function findFuzzyTransaction(amount: number, date: string, vendorName: string): Promise<any | null> {
  if (!amount || !date || !vendorName) return null;
  
  try {
    const normalizedName = normalizeVendorName(vendorName);
    const vendor = await findVendorByName(normalizedName);
    if (!vendor) return null;

    const baseDate = new Date(date);
    if (isNaN(baseDate.getTime())) return null;

    // Calculate window: 5 days before to 5 days after
    const startDate = new Date(baseDate);
    startDate.setDate(baseDate.getDate() - 5);
    const endDate = new Date(baseDate);
    endDate.setDate(baseDate.getDate() + 5);

    const startStr = startDate.toISOString().split('T')[0];
    const endStr = endDate.toISOString().split('T')[0];

    // Search Purchases
    const pRes = await qboQuery(`SELECT * FROM Purchase WHERE TxnDate >= '${startStr}' AND TxnDate <= '${endStr}' AND VendorRef = '${vendor.Id}'`);
    const purchases = pRes?.QueryResponse?.Purchase || [];
    const pMatch = purchases.find((p: any) => Math.abs(p.TotalAmt - amount) < 0.01);
    if (pMatch) return { ...pMatch, type: 'Purchase' };

    // Search Bills
    const bRes = await qboQuery(`SELECT * FROM Bill WHERE TxnDate >= '${startStr}' AND TxnDate <= '${endStr}' AND VendorRef = '${vendor.Id}'`);
    const bills = bRes?.QueryResponse?.Bill || [];
    const bMatch = bills.find((b: any) => Math.abs(b.TotalAmt - amount) < 0.01);
    if (bMatch) return { ...bMatch, type: 'Bill' };

  } catch (err: any) {
    console.warn(`[QBO] findFuzzyTransaction failed:`, err.message);
  }

  return null;
}



// ============================================
// Email Sanitization
// ============================================

/**
 * Strips HTML tags, extracts valid email addresses, and enforces QBO's 100-character limit
 * for email fields (e.g., PrimaryEmailAddr, BillEmail) to prevent Business Validation Errors.
 */
export function sanitizeEmail(email: string | null | undefined): string | null {
  if (!email) return null;
  
  // 1. Strip HTML tags
  let clean = email;
  const match = email.match(/mailto:([^"']+)/) || email.match(/>([^<]+)<\/a>/);
  if (match) {
    clean = match[1].trim();
  } else {
    clean = email.replace(/<[^>]+>/g, '').trim();
  }

  // 2. Extract valid emails to prevent partial truncation of email addresses
  const matches = clean.match(/([a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+\.[a-zA-Z0-9._-]+)/gi);
  if (!matches) {
    return clean.substring(0, 100).trim() || null;
  }

  // 3. Deduplicate and enforce the 100 character limit
  const unique = Array.from(new Set(matches));
  let result = '';
  for (const e of unique) {
    if (!result) {
      result = e.substring(0, 100);
    } else {
      const toAdd = `, ${e}`;
      if (result.length + toAdd.length > 100) {
        break; // Stop adding emails to fit under the 100 character limit
      }
      result += toAdd;
    }
  }

  return result || null;
}

// ============================================
// Customer Operations
// ============================================

/**
 * Search for an existing QBO customer by display name
 */
export async function findCustomer(
  displayName: string
): Promise<{ Id: string; DisplayName: string; SyncToken: string; PrimaryEmailAddr?: { Address: string } } | null> {
  if (!displayName) {
    console.warn('[QBO] findCustomer called with null/undefined displayName');
    return null;
  }
  const escaped = displayName.replace(/'/g, "\\'");
  const result = await qboQuery<any>(
    `SELECT Id, DisplayName, SyncToken, PrimaryEmailAddr FROM Customer WHERE DisplayName = '${escaped}'`
  );

  const customers = result?.QueryResponse?.Customer;
  if (customers && customers.length > 0) {
    return customers[0];
  }
  return null;
}

/**
 * Create a new QBO customer
 */
export async function createCustomer(
  displayName: string,
  phone?: string | null,
  email?: string | null,
  billingAddress?: string | null
): Promise<{ Id: string; DisplayName: string; SyncToken: string; PrimaryEmailAddr?: { Address: string } }> {
  const body: any = {
    DisplayName: displayName,
  };

  if (phone) {
    body.PrimaryPhone = { FreeFormNumber: phone };
  }
  if (email) {
    body.PrimaryEmailAddr = { Address: sanitizeEmail(email) };
  }
  if (billingAddress) {
    // Basic mapping, assuming billingAddress is a raw string. 
    // Usually it's better parsed, but Line1 holds up to 500 chars.
    body.BillAddr = { Line1: billingAddress };
  }

  let result;
  try {
    result = await qboApi<any>({
      method: 'POST',
      endpoint: 'customer',
      body,
    });
  } catch (error: any) {
    if (error.message.includes('6240') || error.message.includes('Duplicate Name')) {
      const suffixGen = Math.floor(1000 + Math.random() * 9000);
      console.warn(`[QBO] Duplicate name '${displayName}' detected (likely a Vendor or inactive). Retrying with suffix...`);
      body.DisplayName = `${displayName} (C-${suffixGen})`; // Append (C-####) for Customer to make it unique
      result = await qboApi<any>({
        method: 'POST',
        endpoint: 'customer',
        body,
      });
      const { logError } = await import('../utils/logger');
      await logError('QBO Duplicate Name Recovered (Customer)', error, {
        is_resolved: true,
        is_critical: false,
        resolution: `Appended suffix C-${suffixGen} and retried successfully`,
        displayName
      });
    } else {
      throw error;
    }
  }

  console.log(`[QBO] Customer created: ${result.Customer.Id} - ${result.Customer.DisplayName}`);
  return result.Customer;
}

/**
 * Get a customer by ID (needed for sparse updates / SyncToken)
 */
export async function getCustomer(
  customerId: string
): Promise<{ Id: string; DisplayName: string; SyncToken: string; PrimaryEmailAddr?: { Address: string } }> {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: `customer/${customerId}`,
  });
  return result.Customer;
}

/**
 * Find or create a QBO customer
 */
export async function findOrCreateCustomer(
  name: string,
  phone?: string | null,
  email?: string | null,
  billingAddress?: string | null
): Promise<{ Id: string; DisplayName: string; SyncToken: string; PrimaryEmailAddr?: { Address: string } }> {
  const existing = await findCustomer(name);
  if (existing) {
    console.log(
      `[QBO] Found existing customer: ${existing.Id} - ${existing.DisplayName}`
    );
    return existing;
  }

  return createCustomer(name, phone, email, billingAddress);
}

/**
 * Search for an existing QBO customer by PM Name and Company Name
 */
export async function findCustomerByPM(
  pmName: string,
  pmCompany: string
): Promise<{ Id: string; DisplayName: string; SyncToken: string; PrimaryEmailAddr?: { Address: string } } | null> {
  if (!pmName && !pmCompany) return null;
  const displayName = pmCompany ? `${pmCompany} - ${pmName}` : pmName;
  const escaped = displayName.replace(/'/g, "\\'");
  const result = await qboQuery<any>(
    `SELECT Id, DisplayName, SyncToken, PrimaryEmailAddr FROM Customer WHERE DisplayName = '${escaped}'`
  );

  const customers = result?.QueryResponse?.Customer;
  if (customers && customers.length > 0) {
    return customers[0];
  }
  return null;
}

/**
 * Find or create a QBO customer for a Project Manager
 */
export async function findOrCreateCustomerByPM(
  pmName: string,
  pmCompany: string,
  phone?: string | null,
  email?: string | null,
  billingAddress?: string | null
): Promise<{ Id: string; DisplayName: string; SyncToken: string; PrimaryEmailAddr?: { Address: string } }> {
  const existing = await findCustomerByPM(pmName, pmCompany);
  if (existing) {
    console.log(
      `[QBO] Found existing PM customer: ${existing.Id} - ${existing.DisplayName}`
    );
    return existing;
  }

  const displayName = `${pmName} - ${pmCompany}`;
  return createCustomer(displayName, phone, email, billingAddress);
}


// ============================================
// Project Operations
// ============================================

/**
 * Search for an existing QBO project by name or property address
/**
 * Helper: Levenshtein distance for fuzzy string matching
 */
function levenshteinDistance(s1: string, s2: string): number {
  if (s1.length === 0) return s2.length;
  if (s2.length === 0) return s1.length;
  const matrix: number[][] = [];
  for (let i = 0; i <= s1.length; i++) matrix[i] = [i];
  for (let j = 0; j <= s2.length; j++) matrix[0][j] = j;
  for (let i = 1; i <= s1.length; i++) {
    for (let j = 1; j <= s2.length; j++) {
      const cost = s1[i - 1] === s2[j - 1] ? 0 : 1;
      matrix[i][j] = Math.min(
        matrix[i - 1][j] + 1,
        matrix[i][j - 1] + 1,
        matrix[i - 1][j - 1] + cost
      );
    }
  }
  return matrix[s1.length][s2.length];
}

export async function findProject(
  customerId: string,
  projectName: string,
  propertyAddress?: string
): Promise<{ Id: string; ProjectName: string } | null> {
  if (!projectName) return null;
  // First, try exact display name match (current standard)
  const escapedName = projectName.replace(/'/g, "\\'");
  const exactResult = await qboQuery<any>(
    `SELECT * FROM Customer WHERE DisplayName = '${escapedName}'`
  );

  const exactProjects = exactResult?.QueryResponse?.Customer;
  if (exactProjects && exactProjects.length > 0) {
    const validExact = exactProjects.find((p: any) => p.Job === true && p.ParentRef?.value === customerId);
    if (validExact) {
      return { Id: validExact.Id, ProjectName: validExact.DisplayName };
    }
  }

  // If no exact match and we have an address, try "Smart" Levenshtein match based on street number
  if (propertyAddress) {
    const searchPart = propertyAddress.trim();
    console.log(`[QBO] Trying smart address match for: "${searchPart}" under customer: ${customerId}`);
    
    const match = searchPart.match(/^(\d+)\s+([a-zA-Z]+)/);
    
    if (match || searchPart.match(/^(\d+)/)) {
      const streetNum = searchPart.match(/^(\d+)/)?.[1] || '';
      const streetWord = match ? match[2] : '';
      
      console.log(`[QBO] Extracted street number "${streetNum}" and word "${streetWord}". Querying...`);
      
      // We run two queries and merge them to be extremely robust. 
      // Query 1: By street number
      const numResult = await qboQuery<any>(
        `SELECT Id, DisplayName, Job, ParentRef, MetaData FROM Customer WHERE DisplayName LIKE '%${streetNum}%' MAXRESULTS 1000`
      ).catch(() => null);

      // Query 2: By street word (if it's at least 4 chars to avoid 'Avenue' or 'St')
      let wordResult = null;
      if (streetWord.length >= 4) {
        wordResult = await qboQuery<any>(
          `SELECT Id, DisplayName, Job, ParentRef, MetaData FROM Customer WHERE DisplayName LIKE '%${streetWord}%' MAXRESULTS 1000`
        ).catch(() => null);
      }

      // Combine and deduplicate candidates
      const candidatesMap = new Map<string, any>();
      
      const p1 = numResult?.QueryResponse?.Customer || [];
      const p2 = wordResult?.QueryResponse?.Customer || [];
      
      for (const p of [...p1, ...p2]) {
        // Enforce that the result IS a project (Job=true) and belongs to our target customer
        if (p.Job === true && p.ParentRef?.value === customerId) {
          candidatesMap.set(p.Id, p);
        }
      }
      
      let candidateProjects = Array.from(candidatesMap.values());
      
      // Sort candidates by newest first so that exact tie breakers favor the most recent project Call Backs
      candidateProjects.sort((a, b) => {
         const timeA = new Date(a.MetaData?.CreateTime || 0).getTime();
         const timeB = new Date(b.MetaData?.CreateTime || 0).getTime();
         return timeB - timeA;
      });

      if (candidateProjects.length > 0) {
        // Find best match via Levenshtein
        let bestMatch = null;
        let lowestDistance = Infinity;
        // Strip spaces/punctuation for comparison
        const targetSearch = searchPart.toLowerCase().replace(/[^a-z0-9]/g, ''); 
        
        // Extract category to ensure we don't merge an Inspection with a Repair leg
        const categoryMatch = projectName.match(/ - ([^-]+)$/);
        const targetCategory = categoryMatch ? categoryMatch[1].trim().toLowerCase() : null;

        for (const proj of candidateProjects) {
          const rawNameLower = proj.DisplayName.toLowerCase();
          
          // PROJECT SEPARATION LOGIC:
          // If we are looking for a specific project leg (e.g. "Inspection"), 
          // and this project is a DIFFERENT leg (e.g. "Repairs"), do NOT match it.
          if (targetCategory && rawNameLower.includes(' - ')) {
              const projCategoryMatch = rawNameLower.match(/ - ([^-]+)$/);
              if (projCategoryMatch) {
                  const projCat = projCategoryMatch[1].trim().toLowerCase();
                  if (projCat !== targetCategory) {
                      // Categories mismatch (e.g. Inspection vs Repairs). Skip this candidate to force a new project leg.
                      continue; 
                  }
              }
          }

          const targetLower = searchPart.toLowerCase().trim();
          
          let dist = Infinity;

          if (rawNameLower.includes(targetLower)) {
            dist = 0;
          } else {
            // Check full name, and each hyphen-separated part to catch "Customer - Address" formats
            const partsToTest = [rawNameLower, ...rawNameLower.split('-')];
            let bestPartDist = Infinity;
            
            for (const part of partsToTest) {
               const cleanPart = part.replace(/[^a-z0-9]/g, '');
               if (cleanPart.length === 0) continue;
               const compareLength = Math.min(cleanPart.length, targetSearch.length + 3);
               const slicedPart = cleanPart.substring(0, compareLength);
               const partDist = levenshteinDistance(targetSearch, slicedPart);
               if (partDist < bestPartDist) bestPartDist = partDist;
            }
            dist = bestPartDist;
          }
          
          if (dist < lowestDistance) {
            lowestDistance = dist;
            bestMatch = proj;
          }
        }
        
        // Allowed threshold: up to 5 typos + length difference allowances for addresses
        if (bestMatch && lowestDistance <= 5) {
          console.log(`[QBO] Levenshtein fuzzy match found: ${bestMatch.DisplayName} (Distance: ${lowestDistance})`);
          return { Id: bestMatch.Id, ProjectName: bestMatch.DisplayName };
        } else {
          console.log(`[QBO] No suitable fuzzy match. Best was ${bestMatch?.DisplayName} with distance ${lowestDistance}.`);
        }
      } else {
         console.log(`[QBO] No projects found containing street number: ${streetNum} or word: ${streetWord}`);
      }
    }
  }

  return null;
}

/**
 * Find ALL QBO projects that match a given address (fuzzy).
 * Used by PO Watcher for smart routing across multiple project legs.
 */
export async function findAllProjectsByAddress(
  propertyAddress: string
): Promise<{ Id: string; ProjectName: string; Status: string }[]> {
  if (!propertyAddress) return [];
  
  const searchPart = propertyAddress.trim();
  const match = searchPart.match(/^(\d+)\s+([a-zA-Z]+)/);
  
  if (match || searchPart.match(/^(\d+)/)) {
    const streetNum = searchPart.match(/^(\d+)/)?.[1] || '';
    const streetWord = match ? match[2] : '';
    
    const numResult = await qboQuery<any>(
      `SELECT Id, DisplayName, Job, Active FROM Customer WHERE DisplayName LIKE '%${streetNum}%' MAXRESULTS 1000`
    ).catch(() => null);

    let wordResult = null;
    if (streetWord.length >= 4) {
      wordResult = await qboQuery<any>(
        `SELECT Id, DisplayName, Job, Active FROM Customer WHERE DisplayName LIKE '%${streetWord}%' MAXRESULTS 1000`
      ).catch(() => null);
    }

    const candidatesMap = new Map<string, any>();
    const p1 = numResult?.QueryResponse?.Customer || [];
    const p2 = wordResult?.QueryResponse?.Customer || [];
    
    for (const p of [...p1, ...p2]) {
      if (p.Job === true) {
        candidatesMap.set(p.Id, p);
      }
    }
    
    const candidateProjects = Array.from(candidatesMap.values());
    const matchedProjects: { Id: string; ProjectName: string; Status: string }[] = [];
    const targetSearch = searchPart.toLowerCase().replace(/[^a-z0-9]/g, '');

    for (const proj of candidateProjects) {
      const rawNameLower = proj.DisplayName.toLowerCase();
      const targetLower = searchPart.toLowerCase().trim();
      let dist = Infinity;

      if (rawNameLower.includes(targetLower)) {
        dist = 0;
      } else {
        const partsToTest = [rawNameLower, ...rawNameLower.split('-')];
        let bestPartDist = Infinity;
        for (const part of partsToTest) {
           const cleanPart = part.replace(/[^a-z0-9]/g, '');
           if (cleanPart.length === 0) continue;
           const compareLength = Math.min(cleanPart.length, targetSearch.length + 3);
           const slicedPart = cleanPart.substring(0, compareLength);
           const partDist = levenshteinDistance(targetSearch, slicedPart);
           if (partDist < bestPartDist) bestPartDist = partDist;
        }
        dist = bestPartDist;
      }
      
      if (dist <= 5) {
        matchedProjects.push({ 
          Id: proj.Id, 
          ProjectName: proj.DisplayName,
          Status: proj.Active ? 'Active' : 'Inactive'
        });
      }
    }
    
    // Sort newest first or something, but we'll return all
    return matchedProjects;
  }

  return [];
}


/**
 * Get a Bill by ID
 */
export async function getBill(billId: string): Promise<any> {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: `bill/${billId}`,
  });
  return result.Bill;
}

/**
 * List all projects (sub-customers) created in the last X months.
 */
export async function listRecentProjects(months = 24): Promise<{ Id: string; DisplayName: string }[]> {
  const cutoffDate = new Date();
  cutoffDate.setMonth(cutoffDate.getMonth() - months);
  const formattedDate = cutoffDate.toISOString().split('T')[0];

  console.log(`[QBO] Fetching active projects updated since ${formattedDate}`);
  
  let allProjects: { Id: string; DisplayName: string }[] = [];
  let startPosition = 1;
  const maxResults = 1000;
  let hasMore = true;

  while (hasMore) {
    const query = `SELECT Id, DisplayName FROM Customer WHERE Job = true AND Active = true AND Metadata.LastUpdatedTime >= '${formattedDate}' STARTPOSITION ${startPosition} MAXRESULTS ${maxResults}`;
    const result = await qboQuery<any>(query);

    const projects = result?.QueryResponse?.Customer || [];
    allProjects = allProjects.concat(projects.map((p: any) => ({
      Id: p.Id,
      DisplayName: p.DisplayName
    })));

    if (projects.length < maxResults) {
      hasMore = false;
    } else {
      startPosition += maxResults;
    }
    
    // Safety break
    if (startPosition > 5000) break;
  }

  console.log(`[QBO] Found total ${allProjects.length} active projects.`);
  return allProjects;
}

/**
 * Create a new TRUE QBO project via REST API using Customer endpoint
 */
export async function createProject(
  customerId: string,
  projectName: string,
  phone?: string | null,
  email?: string | null
): Promise<{ Id: string; ProjectName: string }> {
  const body: any = {
    DisplayName: projectName,
    Job: true,
    IsProject: true,
    ParentRef: { value: customerId },
    BillWithParent: true,
  };

  if (phone) {
    body.PrimaryPhone = { FreeFormNumber: phone };
  }
  if (email) {
    body.PrimaryEmailAddr = { Address: sanitizeEmail(email) };
  }

  let result;
  try {
    result = await qboApi<any>({
      method: 'POST',
      endpoint: 'customer',
      queryParams: { minorversion: '65' },
      body,
    });
  } catch (error: any) {
    if (error.message && (error.message.includes('6240') || error.message.includes('Duplicate Name'))) {
      const suffixGen = Math.floor(1000 + Math.random() * 9000);
      console.warn(`[QBO] Duplicate project name '${projectName}' detected via REST. Retrying with suffix...`);
      body.DisplayName = `${projectName} (P-${suffixGen})`;
      result = await qboApi<any>({
        method: 'POST',
        endpoint: 'customer',
        queryParams: { minorversion: '65' },
        body,
      });
      const { logError } = await import('../utils/logger');
      await logError('QBO Duplicate Name Recovered (Project)', error, {
        is_resolved: true,
        is_critical: false,
        resolution: `Appended suffix P-${suffixGen} and retried successfully`,
        projectName
      });
    } else {
      throw error;
    }
  }

  console.log(`[QBO] TRUE Project created (REST): ${result.Customer.Id} - ${result.Customer.DisplayName}`);
  return { Id: result.Customer.Id, ProjectName: result.Customer.DisplayName };
}

/**
 * Mark a project (sub-customer) as inactive in QBO
 */
export async function markProjectInactive(projectId: string): Promise<boolean> {
  try {
    const proj = await getCustomer(projectId);
    if (!proj) return false;

    const body = {
      sparse: true,
      Id: proj.Id,
      SyncToken: proj.SyncToken,
      Active: false
    };

    await qboApi<any>({
      method: 'POST',
      endpoint: 'customer',
      body
    });

    console.log(`[QBO] Marked project ${projectId} as inactive.`);
    return true;
  } catch (error: any) {
    console.error(`[QBO] Failed to mark project inactive: ${error.message}`);
    return false;
  }
}

/**
 * Lifecycle hook: Checks if an invoice is linked to an Inspection or Quote project, 
 * and marks the project inactive to clean up the dashboard.
 */
export async function checkAndDeactivateProjectOnInvoice(invoiceId: string): Promise<void> {
  try {
    const query = `SELECT CustomerRef FROM Invoice WHERE Id = '${invoiceId}'`;
    const result = await qboQuery<any>(query);
    const invoices = result?.QueryResponse?.Invoice || [];
    if (invoices.length === 0) return;
    
    const customerRef = invoices[0].CustomerRef?.value;
    if (!customerRef) return;
    
    const proj = await getCustomer(customerRef);
    if (proj && proj.DisplayName) {
      const nameLower = proj.DisplayName.toLowerCase();
      if (nameLower.includes('inspection') || nameLower.includes('quote')) {
        console.log(`[QBO Lifecycle] Invoice ${invoiceId} detected on Project '${proj.DisplayName}'. Marking project inactive.`);
        await markProjectInactive(customerRef);
      }
    }
  } catch (e: any) {
    console.warn(`[QBO Lifecycle] Failed to process invoice ${invoiceId} for auto-deactivation:`, e.message);
  }
}

/**
 * Find or create a QBO project under a customer
 */
export async function findOrCreateProject(
  customerId: string,
  projectName: string,
  propertyAddress?: string,
  forceNewProject: boolean = false,
  phone?: string | null,
  email?: string | null,
  isCallBack: boolean = false
): Promise<{ Id: string; ProjectName: string }> {
  if (!forceNewProject) {
    // Try finding by the specific formatted name first
    const existing = await findProject(customerId, projectName, propertyAddress);
    if (existing) {
      console.log(
        `[QBO] Found matching project: ${existing.Id} - ${existing.ProjectName}`
      );
      return existing;
    }
  } else {
    console.log(`[QBO] forceNewProject is true, skipping search for ${projectName}`);
  }

  if (isCallBack) {
    console.warn(`[QBO] Call Back specified, but could not find existing project for ${propertyAddress}. Forcing creation of new project anyway to prevent failure.`);
  }

  // Create new project. If duplicate name exists, createProject handles appending a suffix
  return createProject(customerId, projectName, phone, email);
}

// ============================================
// Service Item Operations
// ============================================

const HVAC_SERVICE_ITEM_NAME = 'HVAC Service';

/**
 * Find or create the generic "HVAC Service" service item
 */
export async function findOrCreateServiceItem(): Promise<{
  Id: string;
  Name: string;
}> {
  // Search for existing item
  const result = await qboQuery<any>(
    `SELECT Id, Name FROM Item WHERE Name = '${HVAC_SERVICE_ITEM_NAME}' AND Type = 'Service'`
  );

  const items = result?.QueryResponse?.Item;
  if (items && items.length > 0) {
    console.log(`[QBO] Found existing service item: ${items[0].Id}`);
    return { Id: items[0].Id, Name: items[0].Name };
  }

  // Create the service item
  const createResult = await qboApi<any>({
    method: 'POST',
    endpoint: 'item',
    body: {
      Name: HVAC_SERVICE_ITEM_NAME,
      Type: 'Service',
      IncomeAccountRef: { value: '82' }, // Sales (Income) account
    },
  });

  console.log(
    `[QBO] Service item created: ${createResult.Item.Id} - ${HVAC_SERVICE_ITEM_NAME}`
  );
  return { Id: createResult.Item.Id, Name: createResult.Item.Name };
}

// ============================================
// Estimate Operations
// ============================================

export interface QboLineItem {
  Amount: number;
  Description: string;
  UnitPrice: number;
  Qty: number;
}

/**
 * Safely truncates descriptions to stay within QBO's 4,000 character limit
 */
export function truncateDescription(val: string | null | undefined): string {
  if (!val) return '';
  return val.length > 4000 ? val.substring(0, 3997) + '...' : val;
}

export interface CreateEstimateParams {
  projectId: string;
  customerRef: string; // The project's ID (sub-customer) acts as CustomerRef
  poNumber?: string | null;
  scopeDetails?: string | null;
  jobCategories: string[];
  applianceCountInput?: number | null;
  claimType?: string | null;
  pmName?: string | null;
  pmCompany?: string | null;
  propertyAddress: string;
  billingAddress?: string | null;
  billEmail?: string | null;
  quotedAmount?: number | null;
  isCallBack?: boolean;
  lineItems?: QboLineItem[];
}

/**
 * Calculate pricing for inspections
 * Base is $385 for the first appliance, +$25 for each additional
 */
export function calculateInspectionPrice(params: {
  jobCategories: string[];
  applianceCountInput?: number | null;
  quotedAmount?: number | null;
}): { unitPrice: number; amount: number } {
  let applianceCount = 0;
  const isWebFormInspection = params.jobCategories.includes('Inspection');

  if (isWebFormInspection) {
    if (params.applianceCountInput && params.applianceCountInput > 0) {
      applianceCount = params.applianceCountInput;
    } else {
      applianceCount = Math.max(0, params.jobCategories.length - 1);
    }
  } else {
    applianceCount = params.jobCategories.filter((c) =>
      c.toLowerCase().includes('inspection')
    ).length;
  }

  let unitPrice = 0;
  let amount = 0;

  if (params.quotedAmount != null && params.quotedAmount > 0) {
    unitPrice = params.quotedAmount;
    amount = params.quotedAmount;
  } else {
    if (applianceCount > 0) {
      unitPrice = 385 + (applianceCount - 1) * 25;
      amount = unitPrice * 1;
    } else if (isWebFormInspection) {
      unitPrice = 385;
      amount = unitPrice * 1;
    }
  }

  return { unitPrice, amount };
}

/**
 * Truncate a custom field value to 31 chars (QBO limit)
 */
export const truncateCustomField = (val: string | null | undefined): string => {
  if (!val) return 'N/A';
  return val.length > 31 ? val.substring(0, 28) + '...' : val;
};

/**
 * Create a QBO Estimate linked to a project
 */
export async function createEstimate(
  params: CreateEstimateParams
): Promise<{ Id: string; SyncToken: string; DocNumber: string }> {
  const serviceItem = await findOrCreateServiceItem();

    // Map custom fields to QBO format
    // Audit of immediate-response-ai-b18b8 Preferences:
    // DefinitionId '1' = "P.O. Number" (User wants to use standard PONumber field, so we'll put Job Type here for now)
    // DefinitionId '2' = "Project Manager" (Desired place for params.pmName)
    // DefinitionId '3' = "sales3" (We'll use this for Claim Type)
    const customFields = [
      { DefinitionId: '1', Name: 'P.O. Number', Type: 'StringType', StringValue: truncateCustomField(params.isCallBack ? `[CALL BACK] ${params.jobCategories.join(' | ')}` : params.jobCategories.join(' | ')) },
      { DefinitionId: '2', Name: 'Project Manager', Type: 'StringType', StringValue: truncateCustomField(params.pmName) },
      { DefinitionId: '3', Name: 'sales3', Type: 'StringType', StringValue: truncateCustomField(params.claimType) },
      { DefinitionId: '4', Name: 'Technician', Type: 'StringType', StringValue: 'Pending' },
    ];

    // Calculate pricing for inspections
    const { unitPrice, amount } = calculateInspectionPrice({
      jobCategories: params.jobCategories,
      applianceCountInput: params.applianceCountInput,
      quotedAmount: params.quotedAmount
    });

    console.log(`[QBO] Estimate Price Calculation: applianceCountInput=${params.applianceCountInput}, unitPrice=${unitPrice}, amount=${amount}`);

    // Build Estimate object
    const estimate: any = {
      AutoDocNumber: true,
      // Link to the project (sub-customer)
      CustomerRef: { value: params.customerRef },
      // PO Number from form - Use standard QBO field
      PONumber: params.poNumber || '',
      CustomerMemo: undefined, // Remove redundant PO from memo as it was "misplaced" at bottom left
      AcceptedBy: params.poNumber ? params.poNumber.substring(0, 30) : undefined,
      // Line items
      Line: params.lineItems && params.lineItems.length > 0 
        ? params.lineItems.map(item => ({
            DetailType: 'SalesItemLineDetail',
            Amount: item.Amount,
            Description: truncateDescription(item.Description),
            SalesItemLineDetail: {
              ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
              Qty: item.Qty,
              UnitPrice: item.UnitPrice,
              TaxCodeRef: { value: '12' }, // Default HST (H) code found in the project
            },
          }))
        : [
            {
              DetailType: 'SalesItemLineDetail',
              Amount: amount,
              Description: truncateDescription(params.scopeDetails),
              SalesItemLineDetail: {
                ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
                Qty: 1,
                UnitPrice: unitPrice,
                TaxCodeRef: { value: '12' }, // Default HST (H) code found in the project
              },
            },
          ],
      GlobalTaxCalculation: 'TaxExcluded',
      CustomField: customFields,
      // Bill-to address optionally stacks PM Name, Company, and Address
      BillAddr: (() => {
        const lines: string[] = [];
        if (params.pmName) lines.push(params.pmName);
        if (params.pmCompany) lines.push(params.pmCompany);
        lines.push(params.billingAddress || params.propertyAddress);
        
        return {
          Line1: lines[0] || '',
          Line2: lines[1] || '',
          Line3: lines[2] || '',
        };
      })(),
      // Ship-to address = property address
      ShipAddr: {
        Line1: params.propertyAddress,
      },
    };

    if (params.billEmail) {
      estimate.BillEmail = { Address: sanitizeEmail(params.billEmail) };
    }

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'estimate',
    body: estimate,
  });

  console.log(
    `[QBO] Estimate created: ${result.Estimate.Id} (Doc# ${result.Estimate.DocNumber})`
  );
  return {
    Id: result.Estimate.Id,
    SyncToken: result.Estimate.SyncToken,
    DocNumber: result.Estimate.DocNumber,
  };
}

/**
 * Get an estimate by ID (needed for sparse updates)
 */
export async function getEstimate(
  estimateId: string
): Promise<any> {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: `estimate/${estimateId}`,
  });
  return result.Estimate;
}

/**
 * Find an active estimate for a given project ID
 */
export async function findEstimateByProject(
  projectId: string
): Promise<{ Id: string; SyncToken: string; DocNumber: string } | null> {
  const result = await qboQuery<any>(
    `SELECT Id, SyncToken, DocNumber FROM Estimate WHERE CustomerRef = '${projectId}'`
  );

  const estimates = result?.QueryResponse?.Estimate;
  if (estimates && estimates.length > 0) {
    // Return the latest one if multiple exist
    return estimates[estimates.length - 1];
  }
  return null;
}

/**
 * Format project name for QBO (Max 100 chars)
 * New Format: [Person Name] - [Short Address] - [Work Requested Categories]
 */
export function formatProjectName(
  address: string,
  clientName: string,
  categories: string[]
): string {
  const shortAddress = truncateAddress(address);
  
  // Extract just the primary high-level action (e.g. "Inspection", "Troubleshooting", "Re and Re")
  // by taking the first category and grabbing the word before any dash or comma
  let primaryCategory = 'General Work';
  if (categories && categories.length > 0) {
    primaryCategory = categories[0].split(' - ')[0].split(',')[0].trim();
  }
  
  // Base name: "1843 Hunters Run Dr, Orleans ON - Leam Hamilton"
  const baseName = `${shortAddress} - ${clientName}`;
  const MAX_QBO_NAME = 100;

  // Add category: "1843 Hunters Run Dr, Orleans ON - Leam Hamilton - Inspection"
  let fullName = `${baseName} - ${primaryCategory}`;
  if (fullName.length > MAX_QBO_NAME) {
    const allowedForCategories = MAX_QBO_NAME - baseName.length - 6; // " - ..." needs 6 chars
    if (allowedForCategories > 5) {
      const truncatedCats = primaryCategory.substring(0, allowedForCategories) + '...';
      return `${baseName} - ${truncatedCats}`;
    } else {
      // Just return base if no room
      return baseName.substring(0, MAX_QBO_NAME);
    }
  }

  return fullName;
}

/**
 * Truncate address to street, city, and province only
 */
function truncateAddress(address: string): string {
  if (!address) return 'No Address';
  let truncated = address.split(', Canada')[0];
  // Remove postal code
  truncated = truncated.replace(/,?\s*[A-Z]\d[A-Z]\s*\d[A-Z]\d$/i, '');
  // Remove common province codes
  truncated = truncated.replace(/,?\s*(ON|AB|BC|MB|NB|NL|NS|NT|NU|PE|QC|SK|YT)$/i, '');
  return truncated.trim();
}

/**
 * Sparse update: update Customer name, phone, and/or email
 */
export async function updateCustomer(opts: {
  customerId: string;
  syncToken: string | undefined;
  displayName?: string;
  phone?: string | null;
  email?: string | null;
  billingAddress?: string | null;
  billingAddressLine2?: string | null;
  shippingAddress?: string | null;
  printOnCheckName?: string | null;
}): Promise<{ SyncToken: string }> {
  let actualSyncToken = opts.syncToken;
  if (!actualSyncToken) {
    const getResult = await qboApi<any>({ method: 'GET', endpoint: `customer/${opts.customerId}` });
    actualSyncToken = getResult.Customer.SyncToken;
  }

  const body: any = {
    Id: opts.customerId,
    SyncToken: actualSyncToken,
    sparse: true,
  };

  if (opts.displayName !== undefined) {
    body.DisplayName = opts.displayName;
  }
  if (opts.phone !== undefined) {
    body.PrimaryPhone = { FreeFormNumber: opts.phone || '' };
  }
  if (opts.email !== undefined) {
    body.PrimaryEmailAddr = { Address: sanitizeEmail(opts.email) || '' };
  }
  if (opts.billingAddress !== undefined) {
    body.BillAddr = {
      Line1: opts.billingAddress || '',
      Line2: opts.billingAddressLine2 || '',
      Line3: '',
      Line4: '',
      Line5: ''
    };
  }
  if (opts.shippingAddress !== undefined) {
    body.ShipAddr = {
      Line1: opts.shippingAddress || '',
      Line2: '',
      Line3: '',
      Line4: '',
      Line5: ''
    };
  }
  if (opts.printOnCheckName !== undefined) {
    body.PrintOnCheckName = opts.printOnCheckName || '';
  }

  try {
    const result = await qboApi<any>({
      method: 'POST',
      endpoint: 'customer',
      body,
    });
    console.log(`[QBO] Customer ${opts.customerId} updated (sparse)`);
    return { SyncToken: result.Customer.SyncToken };
  } catch (err: any) {
    if (err.message && err.message.includes('Stale Object Error')) {
      console.warn(`[QBO] Stale Object Error for Customer ${opts.customerId}. Fetching latest SyncToken and retrying...`);
      const getResult = await qboApi<any>({ method: 'GET', endpoint: `customer/${opts.customerId}` });
      body.SyncToken = getResult.Customer.SyncToken;
      const retryResult = await qboApi<any>({
        method: 'POST',
        endpoint: 'customer',
        body,
      });
      console.log(`[QBO] Customer ${opts.customerId} updated (sparse) (after retry)`);
      return { SyncToken: retryResult.Customer.SyncToken };
    }
    throw err;
  }
}

/**
 * Sparse update: rename a Project (sub-customer)
 */
export async function updateProject(opts: {
  projectId: string;
  syncToken: string | undefined;
  displayName: string;
}): Promise<{ SyncToken: string }> {
  let actualSyncToken = opts.syncToken;
  if (!actualSyncToken) {
    const getResult = await qboApi<any>({ method: 'GET', endpoint: `customer/${opts.projectId}` });
    actualSyncToken = getResult.Customer.SyncToken;
  }

  const body: any = {
    Id: opts.projectId,
    SyncToken: actualSyncToken,
    sparse: true,
    DisplayName: opts.displayName,
  };

  try {
    const result = await qboApi<any>({
      method: 'POST',
      endpoint: 'customer',
      body,
    });
    console.log(`[QBO] Project ${opts.projectId} renamed to "${opts.displayName}"`);
    return { SyncToken: result.Customer.SyncToken };
  } catch (err: any) {
    if (err.message && err.message.includes('Stale Object Error')) {
      console.warn(`[QBO] Stale Object Error for Project ${opts.projectId}. Fetching latest SyncToken and retrying...`);
      const getResult = await qboApi<any>({ method: 'GET', endpoint: `customer/${opts.projectId}` });
      body.SyncToken = getResult.Customer.SyncToken;
      const retryResult = await qboApi<any>({
        method: 'POST',
        endpoint: 'customer',
        body,
      });
      console.log(`[QBO] Project ${opts.projectId} renamed to "${opts.displayName}" (after retry)`);
      return { SyncToken: retryResult.Customer.SyncToken };
    } else if (err.message && (err.message.includes('6240') || err.message.includes('Duplicate Name'))) {
      const suffixGen = Math.floor(1000 + Math.random() * 9000);
      console.warn(`[QBO] Duplicate project name '${opts.displayName}' detected on update. Retrying with suffix...`);
      body.DisplayName = `${opts.displayName} (P-${suffixGen})`;
      const retryResult = await qboApi<any>({
        method: 'POST',
        endpoint: 'customer',
        body,
      });
      console.log(`[QBO] Project ${opts.projectId} renamed to "${body.DisplayName}" (after duplicate name retry)`);
      
      const { logError } = await import('../utils/logger');
      await logError('QBO Duplicate Name Recovered (Project Update)', err, {
        is_resolved: true,
        is_critical: false,
        resolution: `Appended suffix P-${suffixGen} and retried successfully`,
        projectId: opts.projectId,
        originalName: opts.displayName
      });

      return { SyncToken: retryResult.Customer.SyncToken };
    }
    throw err;
  }
}

/**
 * Sparse update: update Estimate ShipAddr (property address)
 */
export async function updateEstimateAddress(
  estimateId: string,
  syncToken: string | undefined,
  propertyAddress: string
): Promise<{ SyncToken: string }> {
  let actualSyncToken = syncToken;
  if (!actualSyncToken) {
    const getResult = await qboApi<any>({ method: 'GET', endpoint: `estimate/${estimateId}` });
    actualSyncToken = getResult.Estimate.SyncToken;
  }

  const body: any = {
    Id: estimateId,
    SyncToken: actualSyncToken,
    sparse: true,
    ShipAddr: { Line1: propertyAddress },
  };

  try {
    const result = await qboApi<any>({
      method: 'POST',
      endpoint: 'estimate',
      body,
    });
    console.log(`[QBO] Estimate ${estimateId} ShipAddr updated`);
    return { SyncToken: result.Estimate.SyncToken };
  } catch (err: any) {
    if (err.message && err.message.includes('Stale Object Error')) {
      console.warn(`[QBO] Stale Object Error for Estimate ${estimateId}. Fetching latest SyncToken and retrying...`);
      const getResult = await qboApi<any>({ method: 'GET', endpoint: `estimate/${estimateId}` });
      body.SyncToken = getResult.Estimate.SyncToken;
      const retryResult = await qboApi<any>({
        method: 'POST',
        endpoint: 'estimate',
        body,
      });
      console.log(`[QBO] Estimate ${estimateId} ShipAddr updated (after retry)`);
      return { SyncToken: retryResult.Estimate.SyncToken };
    }
    throw err;
  }
}

/**
 * Sparse update: set the Technician custom field on an existing estimate
 */
export async function updateEstimateTechnician(
  estimateId: string,
  syncToken: string,
  techName: string
): Promise<void> {
  // QBO requires SyncToken for updates to prevent conflicts
  const body: any = {
    Id: estimateId,
    SyncToken: syncToken,
    sparse: true,
    // Use DefinitionId: '4' for Technician (sales4 field) based on project mapping
    CustomField: [
      {
        DefinitionId: '4',
        Name: 'sales4',
        Type: 'StringType',
        StringValue: techName,
      },
    ],
  };

  try {
    await qboApi({
      method: 'POST',
      endpoint: 'estimate',
      body,
    });
    console.log(
      `[QBO] Estimate ${estimateId} updated with Technician: ${techName}`
    );
  } catch (err: any) {
    if (err.message && err.message.includes('Stale Object Error')) {
      console.warn(`[QBO] Stale Object Error for Estimate ${estimateId}. Fetching latest SyncToken and retrying (Technician)...`);
      const getResult = await qboApi<any>({ method: 'GET', endpoint: `estimate/${estimateId}` });
      body.SyncToken = getResult.Estimate.SyncToken;
      await qboApi({
        method: 'POST',
        endpoint: 'estimate',
        body,
      });
      console.log(`[QBO] Estimate ${estimateId} updated with Technician: ${techName} (after retry)`);
      return;
    }
    throw err;
  }
}

/**
 * Sparse update: set the PO Number on an existing estimate
 */
export async function updateEstimatePONumber(
  estimateId: string,
  syncToken: string | undefined,
  poNumber: string
): Promise<void> {
  // QBO Estimates don't natively support PONumber on standard plans natively, 
  // so we use AcceptedBy and CustomerMemo to ensure it prints on the PDF.
  const updates: any = { 
    PONumber: poNumber || "", // Standard QBO field
  };
  await updateEstimate(estimateId, syncToken, updates);
}

/**
 * Generic sparse update for an Estimate
 */
export async function updateEstimate(
  estimateId: string,
  syncToken: string | undefined,
  updates: any
): Promise<{ Id: string; SyncToken: string }> {
  let actualSyncToken = syncToken;
  if (!actualSyncToken) {
    const getResult = await qboApi<any>({
      method: 'GET',
      endpoint: `estimate/${estimateId}`,
    });
    if (!getResult?.Estimate) throw new Error(`Estimate ${estimateId} not found in QBO`);
    actualSyncToken = getResult.Estimate.SyncToken;
  }

  try {
    const result = await qboApi<any>({
      method: 'POST',
      endpoint: 'estimate',
      body: {
        Id: estimateId,
        SyncToken: actualSyncToken,
        sparse: true,
        ...updates,
      },
    });
    console.log(`[QBO] Estimate ${estimateId} updated (sparse)`);
    return { Id: result.Estimate.Id, SyncToken: result.Estimate.SyncToken };
  } catch (err: any) {
    if (err.message && err.message.includes('Stale Object Error')) {
      console.warn(`[QBO] Stale Object Error for Estimate ${estimateId}. Fetching latest SyncToken and retrying...`);
      const getResult = await qboApi<any>({ method: 'GET', endpoint: `estimate/${estimateId}` });
      const retryResult = await qboApi<any>({
        method: 'POST',
        endpoint: 'estimate',
        body: {
          Id: estimateId,
          SyncToken: getResult.Estimate.SyncToken,
          sparse: true,
          ...updates,
        },
      });
      console.log(`[QBO] Estimate ${estimateId} updated (sparse) (after retry)`);
      return { Id: retryResult.Estimate.Id, SyncToken: retryResult.Estimate.SyncToken };
    }
    throw err;
  }
}

/**
 * Finds all Invoices associated with a CustomerRef (e.g. Project ID)
 */
export async function findInvoicesByCustomer(customerRef: string): Promise<any[]> {
  const query = `SELECT * FROM Invoice WHERE CustomerRef = '${customerRef}'`;
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: `query?query=${encodeURIComponent(query)}`,
  });
  return result.QueryResponse?.Invoice || [];
}

/**
 * Sparse update: set the PO Number on an existing invoice
 */
export async function updateInvoicePONumber(
  invoiceId: string,
  syncToken: string | undefined,
  poNumber: string
): Promise<void> {
  let actualSyncToken = syncToken;
  if (!actualSyncToken) {
    const getResult = await qboApi<any>({
      method: 'GET',
      endpoint: `invoice/${invoiceId}`,
    });
    if (!getResult?.Invoice) throw new Error(`Invoice ${invoiceId} not found in QBO`);
    actualSyncToken = getResult.Invoice.SyncToken;
  }

  await qboApi<any>({
    method: 'POST',
    endpoint: 'invoice',
    body: {
      Id: invoiceId,
      SyncToken: actualSyncToken,
      sparse: true,
      PONumber: poNumber || ""
    },
  });
  console.log(`[QBO] Invoice ${invoiceId} updated with PONumber: ${poNumber}`);
}

// ============================================
// Named Service Item Operations
// ============================================

/**
 * Find or create a QBO Service item by name.
 * Used for "Drive Time", "Labor Time", etc.
 */
export async function findOrCreateNamedServiceItem(
  itemName: string
): Promise<{ Id: string; Name: string }> {
  if (!itemName) throw new Error('itemName is required for findOrCreateNamedServiceItem');
  const escaped = itemName.replace(/'/g, "\\'");
  const result = await qboQuery<any>(
    `SELECT Id, Name FROM Item WHERE Name = '${escaped}' AND Type = 'Service'`
  );

  const items = result?.QueryResponse?.Item;
  if (items && items.length > 0) {
    console.log(`[QBO] Found service item "${itemName}": ${items[0].Id}`);
    return { Id: items[0].Id, Name: items[0].Name };
  }

  const createResult = await qboApi<any>({
    method: 'POST',
    endpoint: 'item',
    body: {
      Name: itemName,
      Type: 'Service',
      IncomeAccountRef: { value: '82' },
    },
  });

  console.log(`[QBO] Service item created: ${createResult.Item.Id} - ${itemName}`);
  return { Id: createResult.Item.Id, Name: createResult.Item.Name };
}

// ============================================
// Time Activity Operations (Drive Time / Labor Time)
// ============================================

export interface CreateTimeActivityParams {
  /** QBO project ID (sub-customer) — used as CustomerRef */
  projectId: string;
  /** "Drive Time", "Labor Time", or "Non-Billable Drive" (company-absorbed return trip / cancelled jobs) */
  activityType: 'Drive Time' | 'Labor Time' | 'Non-Billable Drive';
  /** ISO 8601 start time */
  startTime: string;
  /** ISO 8601 end time (optional — set later via update) */
  endTime?: string;
  /** Free-text description */
  description?: string;
  /** Tech display name */
  techName?: string;
}

/**
 * Create a QBO TimeActivity record linked to a project.
 *
 * If endTime is provided, Hours/Minutes are computed from the duration.
 * If not, the activity is created with 0 hours (updated later when the
 * tech clocks in or submits their report).
 */
export async function createTimeActivity(
  params: CreateTimeActivityParams
): Promise<{ Id: string; SyncToken: string }> {
  const serviceItem = await findOrCreateNamedServiceItem(params.activityType);

  const start = new Date(params.startTime);
  let hours = 0;
  let minutes = 0;

  if (params.endTime) {
    const end = new Date(params.endTime);
    const diffMs = end.getTime() - start.getTime();
    const totalMinutes = Math.max(0, Math.round(diffMs / 60000));
    hours = Math.floor(totalMinutes / 60);
    minutes = totalMinutes % 60;
  }

  // --- Resolve Employee ---
  let employeeId = '';
  if (params.techName) {
    const employee = await findEmployeeByName(params.techName);
    if (employee) {
      employeeId = employee.Id;
    } else {
      console.warn(`[QBO] Employee "${params.techName}" not found for TimeActivity. Falling back to 'Other'.`);
    }
  }

  const isNonBillable = params.activityType === 'Non-Billable Drive';

  const body: any = {
    NameOf: employeeId ? 'Employee' : 'Other',
    ...(employeeId ? { EmployeeRef: { value: employeeId } } : { OtherName: params.techName }),
    CustomerRef: { value: params.projectId },
    ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
    BillableStatus: isNonBillable ? 'NotBillable' : 'Billable',
    TxnDate: start.toISOString().split('T')[0],
    StartTime: params.startTime,
    Hours: hours,
    Minutes: minutes,
    Description: truncateDescription(
      params.description ||
      `${params.activityType} — ${params.techName || 'Technician'}`
    ),
  };

  if (params.endTime) {
    body.EndTime = params.endTime;
  }

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'timeactivity',
    body,
  });

  console.log(
    `[QBO] TimeActivity created: ${result.TimeActivity.Id} (${params.activityType})`
  );
  return {
    Id: result.TimeActivity.Id,
    SyncToken: result.TimeActivity.SyncToken,
  };
}

/**
 * Sparse-update a TimeActivity with an end time and computed duration.
 */
export async function updateTimeActivity(opts: {
  timeActivityId: string;
  syncToken: string;
  endTime: string;
  startTime: string;
}): Promise<void> {
  const start = new Date(opts.startTime);
  const end = new Date(opts.endTime);
  const diffMs = end.getTime() - start.getTime();
  const totalMinutes = Math.max(0, Math.round(diffMs / 60000));
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;

  await qboApi({
    method: 'POST',
    endpoint: 'timeactivity',
    body: {
      Id: opts.timeActivityId,
      SyncToken: opts.syncToken,
      sparse: true,
      EndTime: opts.endTime,
      Hours: hours,
      Minutes: minutes,
    },
  });

  console.log(
    `[QBO] TimeActivity ${opts.timeActivityId} updated: ${hours}h ${minutes}m`
  );
}

/**
 * Get a TimeActivity by ID (to fetch current SyncToken).
 */
export async function getTimeActivity(
  timeActivityId: string
): Promise<any> {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: `timeactivity/${timeActivityId}`,
  });
  return result.TimeActivity;
}

/**
 * Download a QBO Estimate as a PDF buffer.
 * Uses the /estimate/{id}/pdf Intuit endpoint.
 */
export async function getEstimatePdfBuffer(estimateId: string): Promise<Buffer> {
  const accessToken = await getAccessToken();
  const realmId = getRealmId();
  const baseUrl = getBaseUrl();
  const url = `${baseUrl}/v3/company/${realmId}/estimate/${estimateId}/pdf`;

  const response = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      Accept: 'application/pdf',
    },
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`QBO PDF download failed ${response.status}: ${errorText}`);
  }

  const arrayBuffer = await response.arrayBuffer();
  return Buffer.from(arrayBuffer);
}

/**
 * Upload an attachment to QBO and link it to an entity (e.g., Estimate, Employee)
 */
export async function uploadAttachment(opts: {
  entityType: 'Estimate' | 'Invoice' | 'Customer' | 'Bill' | 'Purchase' | 'Employee' | 'VendorCredit';
  entityId: string;
  fileName: string;
  fileBuffer: Buffer;
  contentType?: string;
}): Promise<void> {
  const accessToken = await getAccessToken();
  const realmId = getRealmId();
  const baseUrl = getBaseUrl();
  const url = `${baseUrl}/v3/company/${realmId}/upload`;

  const mimeType = opts.contentType || 'application/pdf';

  // QBO file upload requires a multipart request
  const boundary = '--------------------------' + Date.now().toString(16);
  const metadata = JSON.stringify({
    AttachableRef: [
      {
        EntityRef: {
          type: opts.entityType,
          value: opts.entityId,
        },
      },
    ],
    FileName: opts.fileName,
    ContentType: mimeType,
  });

  const header = 
    `--${boundary}\r\n` +
    `Content-Disposition: form-data; name="file_metadata_01"; filename="metadata.json"\r\n` +
    `Content-Type: application/json\r\n\r\n` +
    `${metadata}\r\n` +
    `--${boundary}\r\n` +
    `Content-Disposition: form-data; name="file_content_01"; filename="${opts.fileName}"\r\n` +
    `Content-Type: ${mimeType}\r\n\r\n`;

  const footer = `\r\n--${boundary}--\r\n`;

  const body = Buffer.concat([
    Buffer.from(header, 'utf8'),
    opts.fileBuffer,
    Buffer.from(footer, 'utf8'),
  ]);

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
      Accept: 'application/json',
    },
    body: body as any, // fetch handles Buffer in Node.js
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`[QBO] Upload error ${response.status}: ${errorText}`);
    throw new Error(`QBO Upload error ${response.status}: ${errorText}`);
  }

  console.log(`[QBO] Attachment uploaded and linked to ${opts.entityType} ${opts.entityId}`);
}

export async function checkQboPreferences() {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: 'preferences',
  });
  return result;
}

/**
 * Normalizes vendor names to prevent duplicates in QBO (e.g., "Noble" vs "Noble Corporation")
 */
export function normalizeVendorName(name: string): string {
  if (!name || name === 'Unknown') return 'Unknown';
  
  const clean = name.trim();
  const lower = clean.toLowerCase();

  // Mapping of common variations to canonical names
  const mapping: { [key: string]: string } = {
    'noble': 'Noble',
    'noble corporation': 'Noble',
    'noble canada': 'Noble',
    'noble group': 'Noble',
    'the noble group': 'Noble',
    'the home depot': 'Home Depot',
    'home depot': 'Home Depot',
    'homedepot': 'Home Depot',
    'wolseley': 'Wolseley',
    'wolseley canada': 'Wolseley',
    'wwg': 'WWG',
    'western water & gas': 'WWG',
    'the master group': 'Master',
    'master group': 'Master',
    'master': 'Master',
    'lowes': "Lowe's",
    'lowe\'s': "Lowe's",
    'emco': 'Emco',
    'emco corporation': 'Emco',
    'emco hvac': 'Emco',
    'eh price': 'E.H. Price',
    'e.h. price': 'E.H. Price',
    'e.h price': 'E.H. Price',
    'eh price solutions': 'E.H. Price',
    'e.h. price solutions': 'E.H. Price',
    'air': 'Air',
    'nadca': 'NADCA',
    'apple self storage': 'Apple SelfStorage',
    'apple selfstorage': 'Apple SelfStorage'
  };

  if (mapping[lower]) {
    return mapping[lower];
  }

  // Generic patterns: remove common suffixes and prefixes
  let normalized = clean
    .replace(/^the\s+/i, '')
    .replace(/,?\s+(inc\.?|ltd\.?|corp\.?|corporation|canada|hvac|supply|group|canada inc\.?|systems|solutions)\s*$/i, '')
    .trim();

  // Title-case every word for consistency to prevent artificial duplicates (e.g. "mcb plumbing" -> "Mcb Plumbing")
  if (normalized.length > 0 && !/^[0-9]+$/.test(normalized)) {
    normalized = normalized.split(' ').map(word => {
      if (word.length === 0) return '';
      return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase();
    }).join(' ');
  }

  return normalized || clean;
}

export async function findVendorByName(name: string): Promise<any> {
  if (!name) return null;
  const normalizedName = normalizeVendorName(name);
  const safeName = (normalizedName || '').replace(/'/g, "\\'");
  
  let query = `select * from Vendor where DisplayName = '${safeName}'`;
  let result = await qboApi<any>({
    method: 'GET',
    endpoint: `query?query=${encodeURIComponent(query)}`,
  });
  let vendors = result?.QueryResponse?.Vendor || [];
  
  if (vendors.length === 0) {
    // Fallback to LIKE match
    query = `select * from Vendor where DisplayName LIKE '%${safeName}%'`;
    result = await qboApi<any>({
      method: 'GET',
      endpoint: `query?query=${encodeURIComponent(query)}`,
    });
    vendors = result?.QueryResponse?.Vendor || [];
  }

  // --- SECONDARY FUZZY PASS ---
  // If still no match, try searching for just the first word (or first 4 chars) to catch dot/space variations
  if (vendors.length === 0 && safeName.length >= 4) {
    const prefix = safeName.substring(0, 4).replace(/[^a-zA-Z0-9]/g, '');
    if (prefix.length >= 3) {
      console.log(`[QBO] Exact vendor match failed for "${safeName}". Trying prefix search: "${prefix}%"`);
      query = `select * from Vendor where DisplayName LIKE '${prefix}%' MAXRESULTS 100`;
      result = await qboApi<any>({
        method: 'GET',
        endpoint: `query?query=${encodeURIComponent(query)}`,
      });
      const candidates = result?.QueryResponse?.Vendor || [];
      
      if (candidates.length > 0) {
        // Find best match via Levenshtein on alphanumeric-only strings
        let bestMatch = null;
        let lowestDist = Infinity;
        const targetClean = safeName.toLowerCase().replace(/[^a-z0-9]/g, '');

        for (const cand of candidates) {
          const candClean = cand.DisplayName.toLowerCase().replace(/[^a-z0-9]/g, '');
          // If one is a prefix of the other (alphanumeric only), it's a very strong match
          if (candClean.startsWith(targetClean) || targetClean.startsWith(candClean)) {
             return cand;
          }
          
          const dist = levenshteinDistance(targetClean, candClean);
          if (dist < lowestDist) {
            lowestDist = dist;
            bestMatch = cand;
          }
        }

        // If distance is low (e.g. within 3 characters of each other after cleaning), accept it
        if (bestMatch && lowestDist <= 3) {
          console.log(`[QBO] Fuzzy vendor match found: "${bestMatch.DisplayName}" for input "${name}" (Dist: ${lowestDist})`);
          return bestMatch;
        }
      }
    }
  }
  
  return vendors.length > 0 ? vendors[0] : null;
}

export async function createVendor(name: string): Promise<any> {
  const normalizedName = normalizeVendorName(name);
  
  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'vendor',
    body: {
      DisplayName: normalizedName.slice(0, 100), // QBO requires DisplayName, max 100 chars
    }
  });
  return result?.Vendor || null;
}

export async function findAccountByName(name: string): Promise<any> {
  if (!name) return null;
  const safeName = name.replace(/'/g, "\\'");
  let query = `select * from Account where Name = '${safeName}'`;
  let result = await qboApi<any>({
    method: 'GET',
    endpoint: `query?query=${encodeURIComponent(query)}`,
  });
  let accounts = result?.QueryResponse?.Account || [];
  
  if (accounts.length === 0) {
    // Fallback to LIKE match
    query = `select * from Account where Name LIKE '%${safeName}%'`;
    result = await qboApi<any>({
      method: 'GET',
      endpoint: `query?query=${encodeURIComponent(query)}`,
    });
    accounts = result?.QueryResponse?.Account || [];
  }
  
  return accounts.length > 0 ? accounts[0] : null;
}

export async function findAccountFuzzy(name: string): Promise<any> {
    const rawMatch = await findAccountByName(name);
    if (rawMatch) return rawMatch;

    let query = `select * from Account where AccountType IN ('Expense', 'Other Expense', 'Cost of Goods Sold', 'Fixed Asset', 'Other Current Asset') MAXRESULTS 1000`;
    let result = await qboApi<any>({
      method: 'GET',
      endpoint: `query?query=${encodeURIComponent(query)}`,
    });
    let accounts = result?.QueryResponse?.Account || [];

    const normalize = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
    const tokenize = (s: string) => s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(Boolean);

    const sTokens = tokenize(name);
    for (const acc of accounts) {
        if (normalize(acc.Name) === normalize(name)) return acc;
        
        const aTokens = tokenize(acc.Name);
        if (sTokens.length > 0 && sTokens.length === aTokens.length) {
             const allFound = sTokens.every(t => aTokens.includes(t));
             if (allFound) return acc;
        }
    }
    return null;
}

export async function createBill(opts: {
  vendorId: string;
  docNumber?: string;
  txnDate?: string;
  dueDate?: string;
  memo?: string;
  taxInclusive?: boolean;
  totalAmount: number;
  taxAmount?: number;
  lines: Array<{
    amount: number;
    description?: string;
    accountId: string;
    customerId?: string; // Project/Customer ref
    taxCodeId?: string;
  }>;
}) {
  const payload = {
    VendorRef: { value: opts.vendorId },
    DocNumber: String(opts.docNumber || '').trim() || undefined,
    TxnDate: opts.txnDate,
    DueDate: opts.dueDate,
    PrivateNote: opts.memo,
    GlobalTaxCalculation: 'TaxInclusive',
    Line: opts.lines.map(l => ({
      DetailType: 'AccountBasedExpenseLineDetail',
      Amount: Number(l.amount.toFixed(2)),
      Description: truncateDescription(l.description),
      AccountBasedExpenseLineDetail: {
        AccountRef: { value: l.accountId },
        TaxCodeRef: { value: l.taxCodeId || '12' }, // Default HST code for Ontario purchases
        ...(l.customerId ? { CustomerRef: { value: l.customerId } } : {})
      }
    }))
  };

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'bill',
    body: payload
  });
  return result.Bill;
}

export async function createVendorCredit(opts: {
  vendorId: string;
  docNumber?: string;
  txnDate?: string;
  memo?: string;
  taxInclusive?: boolean;
  totalAmount: number;
  taxAmount?: number;
  lines: Array<{
    amount: number;
    description?: string;
    accountId: string;
    customerId?: string; // Project/Customer ref
    taxCodeId?: string;
  }>;
}) {
  const payload = {
    VendorRef: { value: opts.vendorId },
    DocNumber: String(opts.docNumber || '').trim() || undefined,
    TxnDate: opts.txnDate,
    PrivateNote: opts.memo,
    GlobalTaxCalculation: 'TaxInclusive',
    Line: opts.lines.map(l => ({
      DetailType: 'AccountBasedExpenseLineDetail',
      Amount: Number(Math.abs(l.amount).toFixed(2)), // Vendor credits use positive amounts in QBO
      Description: truncateDescription(l.description),
      AccountBasedExpenseLineDetail: {
        AccountRef: { value: l.accountId },
        TaxCodeRef: { value: l.taxCodeId || '12' }, // Default HST code for Ontario purchases
        ...(l.customerId ? { CustomerRef: { value: l.customerId } } : {})
      }
    }))
  };

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'vendorcredit',
    body: payload
  });
  return result.VendorCredit;
}


export async function createPurchase(opts: {
  vendorId: string;
  paymentAccountId: string; // The bank/credit card account paying for it
  paymentType: 'Cash' | 'Check' | 'CreditCard';
  docNumber?: string;
  txnDate?: string;
  taxInclusive?: boolean;
  totalAmount: number;
  lines: Array<{
    amount: number;
    description?: string;
    accountId: string;
    customerId?: string; // Project/Customer ref
    taxCodeId?: string;
  }>;
}) {
  const payload = {
    AccountRef: { value: opts.paymentAccountId },
    PaymentType: opts.paymentType,
    EntityRef: { value: opts.vendorId, type: 'Vendor' },
    DocNumber: opts.docNumber,
    TxnDate: opts.txnDate,
    GlobalTaxCalculation: 'TaxInclusive',
    Line: opts.lines.map(l => ({
      DetailType: 'AccountBasedExpenseLineDetail',
      // Convert to exclusive Subtotal if taxInclusive is true, otherwise use exact amount
      Amount: Number(l.amount.toFixed(2)),
      Description: truncateDescription(l.description),
      AccountBasedExpenseLineDetail: {
        AccountRef: { value: l.accountId },
        TaxCodeRef: { value: l.taxCodeId || '12' }, // Default HST code for Ontario purchases
        ...(l.customerId ? { CustomerRef: { value: l.customerId } } : {})
      }
    }))
  };

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'purchase',
    body: payload
  });
  return result.Purchase;
}

export interface CreateInvoiceParams {
  customerRef: string; // The project's ID (sub-customer) acts as CustomerRef
  poNumber?: string | null;
  pmName?: string | null;
  pmCompany?: string | null;
  propertyAddress: string;
  billingAddress?: string | null;
  claimType?: string | null;
  technician?: string | null;
  jobCategories?: string[];
  isCallBack?: boolean;
  lines: Array<{
    amount: number;
    description: string;
    qty: number;
  }>;
}

/**
 * Creates a QBO Invoice based on approved items
 */
export async function createInvoice(
  params: CreateInvoiceParams
): Promise<{ Id: string; SyncToken: string; DocNumber: string }> {
  // We use the same service item as Estimate (usually HVAC Service or similar)
  const serviceItem = await findOrCreateServiceItem();

  const jobCats = params.jobCategories || [];
  const jobTypeStr = params.isCallBack ? `[CALL BACK] ${jobCats.join(' | ')}` : jobCats.join(' | ');

  const customFields = [
    { DefinitionId: '1', Name: 'P.O. Number', Type: 'StringType', StringValue: truncateCustomField(jobTypeStr) },
    { DefinitionId: '2', Name: 'Project Manager', Type: 'StringType', StringValue: truncateCustomField(params.pmName) },
    { DefinitionId: '3', Name: 'sales3', Type: 'StringType', StringValue: truncateCustomField(params.claimType) },
    { DefinitionId: '4', Name: 'Technician', Type: 'StringType', StringValue: truncateCustomField(params.technician) },
  ];

  const invoiceLines = params.lines.map(line => {
    // If amount is negative, QBO requires the line Amount to be negative but Qty to be positive generally,
    // though typically invoices are positive amounts. We'll ensure it respects standard SalesItemLineDetails.
    return {
      DetailType: 'SalesItemLineDetail',
      Amount: line.amount * line.qty,
      Description: truncateDescription(line.description),
      SalesItemLineDetail: {
        ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
        Qty: line.qty,
        UnitPrice: line.amount,
        TaxCodeRef: { value: '12' }, // Default HST (H) code found in the project
      },
    };
  });

  const invoice: any = {
    AutoDocNumber: true,
    CustomerRef: { value: params.customerRef },
    PONumber: params.poNumber || '',
    Line: invoiceLines,
    GlobalTaxCalculation: 'TaxInclusive',
    CustomField: customFields,
    BillAddr: (() => {
      const lines: string[] = [];
      if (params.pmName) lines.push(params.pmName);
      if (params.pmCompany) lines.push(params.pmCompany);
      lines.push(params.billingAddress || params.propertyAddress);
      
      return {
        Line1: lines[0] || '',
        Line2: lines[1] || '',
        Line3: lines[2] || '',
      };
    })(),
    ShipAddr: {
      Line1: params.propertyAddress,
    },
  };

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'invoice',
    body: invoice,
  });

  console.log(
    `[QBO] Invoice created: ${result.Invoice.Id} (Doc# ${result.Invoice.DocNumber})`
  );
  return {
    Id: result.Invoice.Id,
    SyncToken: result.Invoice.SyncToken,
    DocNumber: result.Invoice.DocNumber,
  };
}

export interface CreateEmployeeParams {
  givenName: string;
  familyName: string;
  email: string;
  phone: string;
  hireDate: string;
  address: string;
  sin?: string;
  birthDate?: string;
  payRate?: string | number;
}

/**
 * Creates an Employee record in QBO for Module 3
 */
export async function createEmployee(params: CreateEmployeeParams): Promise<{ Id: string; SyncToken: string }> {
  // Extract digits for SSN, ensuring it is 9 digits exactly and valid via Luhn algorithm
  const sinDigits = params.sin ? params.sin.replace(/\D/g, '') : '';
  let finalSin = undefined;
  
  if (sinDigits.length === 9) {
    // Validate SIN using Luhn algorithm
    let sum = 0;
    for (let i = 0; i < 9; i++) {
      let digit = parseInt(sinDigits.charAt(i));
      if (i % 2 === 1) { // 2nd, 4th, 6th, 8th digits (0-indexed 1, 3, 5, 7)
        digit *= 2;
        if (digit > 9) digit -= 9;
      }
      sum += digit;
    }
    if (sum % 10 === 0) {
      finalSin = sinDigits;
    } else {
      console.warn(`[QBO] Invalid SIN detected (failed Luhn check): ${sinDigits}. Excluding from payload.`);
    }
  }

  
  // Extract parts from the raw address string (e.g. "123 Main St, Toronto, ON, M5V 1J2")
  const addressParts = (params.address && params.address !== 'N/A' ? params.address : '123 Default St').split(',');
  const line1 = addressParts[0].trim().substring(0, 255);
  
  let cityStr = "Toronto";
  let stateStr = "ON";
  let zipStr = "";

  if (addressParts.length > 1) {
    cityStr = addressParts[1].trim().substring(0, 255);
  }
  
  if (addressParts.length > 2) {
    const part2 = addressParts[2].trim();
    if (part2.length === 2) {
      stateStr = part2;
    }
  }

  // Look for a Postal Code pattern (A1B 2C3 or A1B2C3) in any part or specifically at the end
  const postalCodeMatch = params.address.match(/[A-Z][0-9][A-Z]\s?[0-9][A-Z][0-9]/i);
  if (postalCodeMatch) {
    zipStr = postalCodeMatch[0].toUpperCase();
  }

  const employeeData: any = {
    GivenName: params.givenName.substring(0, 25),
    FamilyName: params.familyName.substring(0, 25),
    PrimaryEmailAddr: { Address: sanitizeEmail(params.email) || '' },
    PrimaryPhone: { FreeFormNumber: params.phone },
    HiredDate: params.hireDate,
    BirthDate: params.birthDate,
    EmployeeType: 'Hourly',
    CostRate: params.payRate,
    HourlyRate: params.payRate,
    BillableTime: true, // Enables time tracking entry in QBO Time
    PrimaryAddr: {
      Line1: line1,
      City: cityStr,
      CountrySubDivisionCode: stateStr,
      PostalCode: zipStr,
      Country: "Canada"
    }
  };

  if (finalSin) {
    // QBO expects SSN formatted as XXX-XX-XXXX
    employeeData.SSN = `${finalSin.substring(0,3)}-${finalSin.substring(3,5)}-${finalSin.substring(5,9)}`;
  }

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'employee',
    body: employeeData,
  }).catch(async (err: any) => {
    // If name already exists (Error code 6240), try to find and update
    if (err.message && err.message.includes('6240')) {
      console.log(`[QBO] Employee "${params.givenName} ${params.familyName}" already exists. Attempting update instead...`);
      const existing = await findEmployeeByName(`${params.givenName} ${params.familyName}`.trim());
      if (existing) {
        return await updateEmployee(existing.Id, existing.SyncToken, params);
      }
    }
    throw err;
  });

  if (result.Employee) {
    console.log(`[QBO] Employee ${result.Employee.Id} synchronized (Created/Updated).`);
    return {
      Id: result.Employee.Id,
      SyncToken: result.Employee.SyncToken
    };
  }

  // Fallback for updateEmployee result format
  return {
    Id: result.Id || result.Employee?.Id,
    SyncToken: result.SyncToken || result.Employee?.SyncToken
  };
}

/**
 * Finds an employee by their exact DisplayName
 */
export async function findEmployeeByName(displayName: string): Promise<{ Id: string; SyncToken: string } | null> {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: `query?query=SELECT * FROM Employee WHERE DisplayName = '${displayName.replace(/'/g, "\\'")}'`
  });
  
  const employees = result.QueryResponse.Employee || [];
  if (employees.length > 0) {
    return {
      Id: employees[0].Id,
      SyncToken: employees[0].SyncToken
    };
  }
  return null;
}

/**
 * Updates an existing Employee record in QBO
 */
export async function updateEmployee(id: string, syncToken: string, params: CreateEmployeeParams): Promise<{ Id: string; SyncToken: string }> {
  // Extract digits for SSN, ensuring it is 9 digits exactly and valid via Luhn algorithm
  const sinDigits = params.sin ? params.sin.replace(/\D/g, '') : '';
  let finalSin = undefined;
  
  if (sinDigits.length === 9) {
    let sum = 0;
    for (let i = 0; i < 9; i++) {
      let digit = parseInt(sinDigits.charAt(i));
      if (i % 2 === 1) { 
        digit *= 2;
        if (digit > 9) digit -= 9;
      }
      sum += digit;
    }
    if (sum % 10 === 0) {
      finalSin = sinDigits;
    }
  }

  const addressParts = (params.address && params.address !== 'N/A' ? params.address : '123 Default St').split(',');
  const line1 = addressParts[0].trim().substring(0, 255);
  let cityStr = "Toronto";
  let stateStr = "ON";
  let zipStr = "";
  if (addressParts.length > 1) cityStr = addressParts[1].trim().substring(0, 255);
  if (addressParts.length > 2) {
    const part2 = addressParts[2].trim();
    if (part2.length === 2) stateStr = part2;
  }
  const postalCodeMatch = params.address.match(/[A-Z][0-9][A-Z]\s?[0-9][A-Z][0-9]/i);
  if (postalCodeMatch) zipStr = postalCodeMatch[0].toUpperCase();

  const employeeData: any = {
    Id: id,
    SyncToken: syncToken,
    sparse: true,
    GivenName: params.givenName.substring(0, 25),
    FamilyName: params.familyName.substring(0, 25),
    PrimaryEmailAddr: { Address: sanitizeEmail(params.email) || '' },
    PrimaryPhone: { FreeFormNumber: params.phone },
    HiredDate: params.hireDate,
    BirthDate: params.birthDate,
    EmployeeType: 'Hourly',
    CostRate: params.payRate,
    HourlyRate: params.payRate,
    BillableTime: true,
    PrimaryAddr: {
      Line1: line1,
      City: cityStr,
      CountrySubDivisionCode: stateStr,
      PostalCode: zipStr,
      Country: "Canada"
    }
  };

  if (finalSin) {
    employeeData.SSN = `${finalSin.substring(0,3)}-${finalSin.substring(3,5)}-${finalSin.substring(5,9)}`;
  }

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'employee',
    body: employeeData,
  });

  return {
    Id: result.Employee.Id,
    SyncToken: result.Employee.SyncToken
  };
}

/**
 * Fetches all Active Employees from QBO as the source of truth for the Staff Dashboard.
 */
export async function getActiveStaffFromQBO(): Promise<any[]> {
  const result = await qboApi<any>({
    method: 'GET',
    endpoint: "query?query=SELECT * FROM Employee WHERE Active = true"
  });
  return result.QueryResponse.Employee || [];
}

/**
 * Suspends/deactivates an Employee record in QBO for Module 4 Offboarding
 */
export async function updateEmployeeStatus(employeeId: string, active: boolean, syncToken?: string): Promise<void> {
  let actualSyncToken = syncToken;
  if (!actualSyncToken) {
    const getResult = await qboApi<any>({
      method: 'GET',
      endpoint: `employee/${employeeId}`,
    });
    if (!getResult?.Employee) throw new Error(`Employee ${employeeId} not found in QBO`);
    actualSyncToken = getResult.Employee.SyncToken;
  }

  await qboApi<any>({
    method: 'POST',
    endpoint: 'employee',
    body: {
      Id: employeeId,
      SyncToken: actualSyncToken,
      sparse: true,
      Active: active
    },
  });

  console.log(`[QBO] Employee ${employeeId} Active status set to ${active}`);
}



