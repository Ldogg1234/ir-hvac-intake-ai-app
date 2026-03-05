/**
 * QuickBooks Online Service
 * Handles OAuth token management, customer/project/estimate operations
 */

import * as admin from 'firebase-admin';
// eslint-disable-next-line @typescript-eslint/no-var-requires
const OAuthClient = require('intuit-oauth');

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
  return new OAuthClient({
    clientId: process.env.QBO_CLIENT_ID,
    clientSecret: process.env.QBO_CLIENT_SECRET,
    environment: USE_SANDBOX ? 'sandbox' : 'production',
    redirectUri: process.env.QBO_REDIRECT_URI || '',
  });
}

/**
 * Get the OAuth authorization URL for initial consent flow
 */
export function getAuthorizationUrl(redirectUri: string): string {
  const oauthClient = new OAuthClient({
    clientId: process.env.QBO_CLIENT_ID,
    clientSecret: process.env.QBO_CLIENT_SECRET,
    environment: USE_SANDBOX ? 'sandbox' : 'production',
    redirectUri,
  });

  return oauthClient.authorizeUri({
    scope: [OAuthClient.scopes.Accounting],
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
    clientId: process.env.QBO_CLIENT_ID,
    clientSecret: process.env.QBO_CLIENT_SECRET,
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

/**
 * Get a valid access token, refreshing if needed
 */
async function getAccessToken(): Promise<string> {
  const doc = await admin
    .firestore()
    .collection('qbo_tokens')
    .doc('primary')
    .get();

  if (!doc.exists) {
    throw new Error(
      'QBO tokens not found. Run the OAuth consent flow first via /qboAuthCallback'
    );
  }

  const tokens = doc.data() as QboTokens;
  const updatedAt = tokens.updated_at?.toDate() || new Date(0);
  const expiresAt = new Date(
    updatedAt.getTime() + (tokens.expires_in - 60) * 1000
  );

  // Token still valid
  if (new Date() < expiresAt) {
    return tokens.access_token;
  }

  // Refresh the token
  console.log('[QBO] Access token expired, refreshing...');
  const oauthClient = createOAuthClient();
  oauthClient.setToken({
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
    token_type: tokens.token_type,
  });

  const refreshResponse = await oauthClient.refresh();
  const newTokens = refreshResponse.getJson();

  await admin.firestore().collection('qbo_tokens').doc('primary').set({
    access_token: newTokens.access_token,
    refresh_token: newTokens.refresh_token,
    token_type: newTokens.token_type,
    expires_in: newTokens.expires_in,
    x_refresh_token_expires_in: newTokens.x_refresh_token_expires_in,
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  console.log('[QBO] Tokens refreshed successfully');
  return newTokens.access_token;
}

/**
 * Get the QBO Realm ID from environment
 */
function getRealmId(): string {
  const realmId = process.env.QBO_REALM_ID;
  if (!realmId) {
    throw new Error('QBO_REALM_ID not set');
  }
  return realmId;
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
 * Make an authenticated QBO API call
 */
async function qboApi<T = any>(options: QboApiOptions): Promise<T> {
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

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`[QBO] API error ${response.status}: ${errorText}`);
    throw new Error(`QBO API ${response.status}: ${errorText}`);
  }

  return response.json() as Promise<T>;
}

/**
 * Run a QBO query (SELECT statement)
 */
async function qboQuery<T = any>(query: string): Promise<T> {
  return qboApi<T>({
    method: 'GET',
    endpoint: 'query',
    queryParams: { query },
  });
}

// ============================================
// Customer Operations
// ============================================

/**
 * Search for an existing QBO customer by display name
 */
export async function findCustomer(
  displayName: string
): Promise<{ Id: string; DisplayName: string; SyncToken: string } | null> {
  const escaped = displayName.replace(/'/g, "\\'");
  const result = await qboQuery<any>(
    `SELECT Id, DisplayName, SyncToken FROM Customer WHERE DisplayName = '${escaped}'`
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
  email?: string | null
): Promise<{ Id: string; DisplayName: string; SyncToken: string }> {
  const body: any = {
    DisplayName: displayName,
  };

  if (phone) {
    body.PrimaryPhone = { FreeFormNumber: phone };
  }
  if (email) {
    body.PrimaryEmailAddr = { Address: email };
  }

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'customer',
    body,
  });

  console.log(`[QBO] Customer created: ${result.Customer.Id} - ${displayName}`);
  return result.Customer;
}

/**
 * Find or create a QBO customer
 */
export async function findOrCreateCustomer(
  name: string,
  phone?: string | null,
  email?: string | null
): Promise<{ Id: string; DisplayName: string; SyncToken: string }> {
  const existing = await findCustomer(name);
  if (existing) {
    console.log(
      `[QBO] Found existing customer: ${existing.Id} - ${existing.DisplayName}`
    );
    return existing;
  }

  return createCustomer(name, phone, email);
}

// ============================================
// Project Operations
// ============================================

/**
 * Search for an existing QBO project by name under a customer
 */
export async function findProject(
  customerId: string,
  projectName: string
): Promise<{ Id: string; ProjectName: string } | null> {
  // QBO Projects API: GET /v3/company/{realmId}/query with project query
  // Projects are sub-customers with Job=true in the older API,
  // or use the dedicated /project endpoint
  const escaped = projectName.replace(/'/g, "\\'");
  const result = await qboQuery<any>(
    `SELECT Id, DisplayName, SyncToken FROM Customer WHERE DisplayName = '${escaped}' AND Job = true`
  );

  const projects = result?.QueryResponse?.Customer;
  if (projects && projects.length > 0) {
    return { Id: projects[0].Id, ProjectName: projects[0].DisplayName };
  }
  return null;
}

/**
 * Create a new QBO project (sub-customer with Job=true)
 */
export async function createProject(
  customerId: string,
  projectName: string
): Promise<{ Id: string; ProjectName: string }> {
  const body = {
    DisplayName: projectName,
    Job: true,
    ParentRef: { value: customerId },
  };

  const result = await qboApi<any>({
    method: 'POST',
    endpoint: 'customer',
    body,
  });

  console.log(
    `[QBO] Project created: ${result.Customer.Id} - ${projectName}`
  );
  return { Id: result.Customer.Id, ProjectName: result.Customer.DisplayName };
}

/**
 * Find or create a QBO project under a customer
 */
export async function findOrCreateProject(
  customerId: string,
  projectName: string
): Promise<{ Id: string; ProjectName: string }> {
  const existing = await findProject(customerId, projectName);
  if (existing) {
    console.log(
      `[QBO] Found existing project: ${existing.Id} - ${existing.ProjectName}`
    );
    return existing;
  }

  return createProject(customerId, projectName);
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
      IncomeAccountRef: { value: '1' }, // Default income account — may need adjustment
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

export interface CreateEstimateParams {
  projectId: string;
  customerRef: string; // The project's ID (sub-customer) acts as CustomerRef
  poNumber?: string | null;
  scopeDetails?: string | null;
  jobCategories: string[];
  claimType?: string | null;
  pmName?: string | null;
  propertyAddress: string;
}

/**
 * Create a QBO Estimate linked to a project
 *
 * Custom fields (must be pre-created in QBO UI):
 *  - Job Type (index 1): job_categories joined by |
 *  - Claim Type (index 2): claim_type
 *  - Project Manager (index 3): pm.full_name
 *  - Technician (index 4): blank (updated later)
 */
export async function createEstimate(
  params: CreateEstimateParams
): Promise<{ Id: string; SyncToken: string; DocNumber: string }> {
  const serviceItem = await findOrCreateServiceItem();

  const estimate: any = {
    // Link to the project (sub-customer)
    CustomerRef: { value: params.customerRef },
    // PO Number from form
    PONumber: params.poNumber || '',
    // Line items
    Line: [
      {
        DetailType: 'SalesItemLineDetail',
        Amount: 0,
        Description: params.scopeDetails || '',
        SalesItemLineDetail: {
          ItemRef: { value: serviceItem.Id, name: serviceItem.Name },
          Qty: 1,
          UnitPrice: 0,
        },
      },
    ],
    // Custom fields — indices depend on your QBO setup
    // These must already exist in QBO Settings → Custom Fields
    CustomField: [
      {
        DefinitionId: '1',
        Name: 'Job Type',
        Type: 'StringType',
        StringValue: params.jobCategories.join(' | '),
      },
      {
        DefinitionId: '2',
        Name: 'Claim Type',
        Type: 'StringType',
        StringValue: params.claimType || '',
      },
      {
        DefinitionId: '3',
        Name: 'Project Manager',
        Type: 'StringType',
        StringValue: params.pmName || '',
      },
      {
        DefinitionId: '4',
        Name: 'Technician',
        Type: 'StringType',
        StringValue: '', // Filled later via calendar sync
      },
    ],
    // Ship-to address = property address
    ShipAddr: {
      Line1: params.propertyAddress,
    },
  };

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
    CustomField: [
      {
        DefinitionId: '4',
        Name: 'Technician',
        Type: 'StringType',
        StringValue: techName,
      },
    ],
  };

  await qboApi({
    method: 'POST',
    endpoint: 'estimate',
    body,
  });

  console.log(
    `[QBO] Estimate ${estimateId} updated with Technician: ${techName}`
  );
}
