/**
 * Configuration Module
 * Centralizes environment variables and constants
 */

import { defineString, defineSecret } from 'firebase-functions/params';

// Define Firebase params for environment variables
const alloydbPassword = defineSecret('ALLOYDB_PASSWORD');
const gmailServiceAccountKey = defineSecret('GMAIL_SERVICE_ACCOUNT_KEY');
const qboClientId = defineSecret('QBO_CLIENT_ID');
const qboClientSecret = defineSecret('QBO_CLIENT_SECRET');
const qboRealmId = defineSecret('QBO_REALM_ID');
const gcpProjectId = defineString('GCP_PROJECT_ID');
const driveparentFolderId = defineString('GOOGLE_DRIVE_PARENT_FOLDER_ID');
const ghostCalendarId = defineString('GHOST_CALENDAR_ID');
const googleMapsApiKey = defineString('GOOGLE_MAPS_API_KEY');
const clockInBaseUrl = defineString('CLOCK_IN_BASE_URL');

/**
 * Application configuration
 */
export function getQboConfig() {
  const clientId = qboClientId.value() || process.env.QBO_CLIENT_ID;
  const clientSecret = qboClientSecret.value() || process.env.QBO_CLIENT_SECRET;
  const realmId = qboRealmId.value() || process.env.QBO_REALM_ID;

  if (!clientId || !clientSecret) {
    throw new Error('QBO credentials not fully configured');
  }

  if (!realmId) {
    throw new Error('QBO_REALM_ID not set');
  }

  return { clientId, clientSecret, realmId };
}

export const config = {
  // Google Cloud Project
  gcp: {
    get projectId(): string {
      return gcpProjectId.value() || process.env.GCP_PROJECT_ID || '';
    },
  },

  // Google Drive Configuration
  googleDrive: {
    get parentFolderId(): string {
      return driveparentFolderId.value() || process.env.GOOGLE_DRIVE_PARENT_FOLDER_ID || '';
    },
    masterJobHistoryFolderId: '1EfawqR0hsLnpI2ZkgWM3SBRHXOaR6xlj',
  },

  // Google Docs Configuration
  googleDocs: {
    get templateId(): string {
      return process.env.GOOGLE_DOC_TEMPLATE_ID || '';
    },
  },

  // Google Calendar Configuration
  calendar: {
    get ghostCalendarId(): string {
      return ghostCalendarId.value() || process.env.GHOST_CALENDAR_ID || 'c_82f31464fae8eeb8fd1cee1af6675655ffc9456594b656b049cc061323199f35@group.calendar.google.com';
    },
    defaultEventDurationHours: 2,
    defaultTimezone: 'America/Toronto',
  },

  // Google Maps / Location Services
  googleMaps: {
    get apiKey(): string {
      return googleMapsApiKey.value() || process.env.GOOGLE_MAPS_API_KEY || '';
    },
    /** Base URL for technician clock-in verification */
    get clockInBaseUrl(): string {
      return clockInBaseUrl.value() || process.env.CLOCK_IN_BASE_URL || 'https://intake-406471533341.us-central1.run.app';
    },
    /** Maximum distance (metres) a tech can be from the site to clock in */
    proximityThresholdMetres: 200,
  },

  // Google AI / Gemini Configuration
  googleAI: {
    get apiKey(): string {
      return 'AIzaSyDDh5jo-jKZsMxaEsVIJXiHMlViCYwcBWo';
    },
  },

  // Office / company address (used for email footer)
  officeAddress: '153 Crown Ct, Whitby, ON',

  // Job Types Enum
  jobTypes: {
    RESIDENTIAL: 'Residential',
    COMMERCIAL: 'Commercial',
    RES_INSURANCE: 'Res_Insurance',
    COMM_INSURANCE: 'Comm_Insurance',
  } as const,

  // Claim Types Enum
  claimTypes: {
    FLOOD: 'Flood',
    FIRE: 'Fire',
    ABATEMENT: 'Abatement',
    OTHER: 'Other',
  } as const,

  // Lead Status Enum (matches project_blueprint.md state machine)
  leadStatuses: {
    INTAKE: 'intake',
    SCHEDULED: 'scheduled',
    IN_PROGRESS: 'in-progress',
    REPORT_SUBMITTED: 'report-submitted',
    INVOICED: 'invoiced',
  } as const,

  // Access Instructions Enum
  accessInstructions: {
    CONTACT_PM: 'Contact PM',
    CONTACT_CLIENT: 'Contact Client',
  } as const,
} as const;

/**
 * Job Categories organized by claim type
 */
export const jobCategories = {
  flood: [
    'Inspection - Full HVAC Flood',
    'Inspection - Furnace System - Flood',
    'Inspection - Air Conditioner - Flood',
    'Inspection - HWT Flood',
    'Inspection - Boiler System Flood',
  ],
  fire: [
    'Inspection - Full HVAC Fire',
    'Inspection - Furnace System - Fire',
    'Inspection - Air Conditioner Fire',
    'Inspection - HWT Fire',
    'Inspection - Boiler System Fire',
    'Inspection - Emergency Commercial Fire',
    'Inspection - Fireplace',
  ],
  abatement: [
    'Inspection - Ductwork Residential',
    'Inspection - Ductwork Commercial',
    'Cleaning - Residential Duct',
    'Cleaning - Commercial Duct',
    'Re and Re - Ventilation System',
  ],
  replacement: [
    'Re and Re - Full HVAC',
    'Re and Re - Furnace',
    'Re and Re - AC',
    'Re and Re - HWT',
    'Re and Re - Furnace and HWT',
    'Re and Re - Furnace and AC',
    'Re and Re - Boiler unit',
    'Re and Re - Boiler unit and HWT',
  ],
  service: [
    'Troubleshooting - Furnace',
    'Troubleshooting - AC',
    'Troubleshooting - HVAC',
    'Thermostat - Service Call',
    'Miscellaneous',
  ],
} as const;

/**
 * Get all job categories as a flat array
 */
export function getAllJobCategories(): string[] {
  return [
    ...jobCategories.flood,
    ...jobCategories.fire,
    ...jobCategories.abatement,
    ...jobCategories.replacement,
    ...jobCategories.service,
  ];
}

/**
 * Get job categories filtered by claim type
 */
export function getJobCategoriesByClaimType(claimType: string | null): string[] {
  if (!claimType) {
    return getAllJobCategories();
  }

  switch (claimType.toLowerCase()) {
    case 'flood':
      return [...jobCategories.flood, ...jobCategories.replacement, ...jobCategories.service];
    case 'fire':
      return [...jobCategories.fire, ...jobCategories.replacement, ...jobCategories.service];
    case 'abatement':
      return [...jobCategories.abatement, ...jobCategories.replacement, ...jobCategories.service];
    case 'other':
    default:
      return getAllJobCategories();
  }
}

/**
 * Check if a job type is an insurance job
 */
export function isInsuranceJob(jobType: string): boolean {
  return jobType === config.jobTypes.RES_INSURANCE || 
         jobType === config.jobTypes.COMM_INSURANCE;
}

// Export secrets for use in function definitions
export { alloydbPassword, gmailServiceAccountKey, qboClientId, qboClientSecret, qboRealmId };
