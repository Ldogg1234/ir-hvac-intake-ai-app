/**
 * Google Drive Service
 * Handles folder creation for HVAC lead intake
 * 
 * Folder structure:
 * [Property Address]_[PM Name or Client Name]/
 * ├── Inspection Photos/
 * ├── Post Job Photos/
 * ├── Videos/
 * ├── Reports/
 * └── Meter Readings/
 */

import { google, drive_v3 } from 'googleapis';
import { config } from '../config';
import { analyzeMeterImageFromBuffer, MeterReading } from './vision';
import { generateClockInUrl } from './location';

// Types
export interface CreateFolderParams {
  propertyAddress: string;
  pmName?: string | null;
  clientName: string;
}

export interface DriveFolder {
  folderId: string;
  folderUrl: string;
  inspectionPhotosFolderId: string;
  postJobPhotosFolderId: string;
  videosFolderId: string;
  reportsFolderId: string;
  meterReadingsFolderId: string;
  clockInUrl: string;
}

// User to impersonate for domain-wide delegation
const IMPERSONATE_USER = 'admin@immediateresponsehvac.ca';

// Initialize Drive client with domain-wide delegation
async function getDriveClient(): Promise<drive_v3.Drive> {
  const auth = new google.auth.GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/drive'],
  });
  
  const client = await auth.getClient();
  
  // Use domain-wide delegation to impersonate the admin user
  if ('subject' in client) {
    (client as any).subject = IMPERSONATE_USER;
  }
  
  return google.drive({ version: 'v3', auth: client as any });
}

/**
 * Truncate address to street, city, and province only
 * Removes postal code and ", Canada" from Google Maps formatted addresses
 * Example: "123 Main St, Calgary, AB T2P 1J9, Canada" → "123 Main St, Calgary, AB"
 */
function truncateAddress(address: string): string {
  // Remove ", Canada" suffix
  let truncated = address.split(', Canada')[0];
  // Remove Canadian postal code pattern (A1A 1A1 or A1A1A1)
  truncated = truncated.replace(/,?\s*[A-Z]\d[A-Z]\s*\d[A-Z]\d$/i, '');
  return truncated.trim();
}

/**
 * Sanitize folder name by removing/replacing invalid characters
 */
function sanitizeFolderName(name: string): string {
  // Remove or replace characters that are invalid in Drive folder names
  return name
    .replace(/[<>:"/\\|?*]/g, '-')  // Replace invalid chars with dash
    .replace(/\s+/g, ' ')           // Normalize whitespace
    .trim();
}

/**
 * Generate the folder name based on business rules
 * - Insurance jobs: [Property Address]_[PM Name]
 * - Non-insurance jobs: [Property Address]_[Client Name]
 */
function generateFolderName(params: CreateFolderParams): string {
  const ownerName = params.pmName || params.clientName;
  const shortAddress = truncateAddress(params.propertyAddress);
  const folderName = `${shortAddress}_${ownerName}`;
  return sanitizeFolderName(folderName);
}

/**
 * Create a single folder in Google Drive
 */
async function createFolder(
  drive: drive_v3.Drive,
  name: string,
  parentId?: string
): Promise<{ id: string; webViewLink: string }> {
  const fileMetadata: drive_v3.Schema$File = {
    name,
    mimeType: 'application/vnd.google-apps.folder',
  };

  if (parentId) {
    fileMetadata.parents = [parentId];
  }

  const response = await drive.files.create({
    requestBody: fileMetadata,
    fields: 'id, webViewLink',
  });

  if (!response.data.id || !response.data.webViewLink) {
    throw new Error(`Failed to create folder: ${name}`);
  }

  return {
    id: response.data.id,
    webViewLink: response.data.webViewLink,
  };
}

// Team emails that get Editor access to all lead folders
const TEAM_EDITOR_EMAILS = [
  'ops@immediateresponsehvac.ca',
  'techs@immediateresponsehvac.ca',
];

/**
 * Share folder with a specific email as Editor
 */
async function shareFolderWithEmail(
  drive: drive_v3.Drive,
  folderId: string,
  email: string
): Promise<void> {
  await drive.permissions.create({
    fileId: folderId,
    requestBody: {
      role: 'writer',
      type: 'user',
      emailAddress: email,
    },
    sendNotificationEmail: false,
  });
}

/**
 * Set folder permissions:
 * - Share with team emails (ops@, techs@) as Editor
 * - Allow anyone with link to view (for PM/client access)
 */
async function setFolderPermissions(
  drive: drive_v3.Drive,
  folderId: string
): Promise<void> {
  // Share with team emails as Editor
  await Promise.all(
    TEAM_EDITOR_EMAILS.map(email => 
      shareFolderWithEmail(drive, folderId, email)
    )
  );

  // Also allow anyone with link to have writer access (for PMs/clients)
  await drive.permissions.create({
    fileId: folderId,
    requestBody: {
      role: 'writer',
      type: 'anyone',
    },
  });
}

/**
 * Create the complete folder structure for a lead
 * 
 * Creates:
 * - Main folder: [Property Address]_[PM/Client Name]
 * - Subfolder: Inspection Photos
 * - Subfolder: Post Job Photos
 * - Subfolder: Videos
 * - Subfolder: Reports
 * - Subfolder: Meter Readings
 * 
 * @param params - Folder creation parameters
 * @returns DriveFolder object with all folder IDs and URLs
 */
export async function createLeadFolderStructure(
  params: CreateFolderParams
): Promise<DriveFolder> {
  const drive = await getDriveClient();
  const folderName = generateFolderName(params);
  
  // Create main folder under the configured parent folder
  const mainFolder = await createFolder(
    drive,
    folderName,
    config.googleDrive.parentFolderId
  );

  // Create subfolders in parallel
  const [inspectionPhotosFolder, postJobPhotosFolder, videosFolder, reportsFolder, meterReadingsFolder] = await Promise.all([
    createFolder(drive, 'Inspection Photos', mainFolder.id),
    createFolder(drive, 'Post Job Photos', mainFolder.id),
    createFolder(drive, 'Videos', mainFolder.id),
    createFolder(drive, 'Reports', mainFolder.id),
    createFolder(drive, 'Meter Readings', mainFolder.id),
  ]);

  // Set permissions on the main folder (inherits to subfolders)
  await setFolderPermissions(drive, mainFolder.id);

  // Generate clock-in URL for technician on-site verification
  const clockInUrl = generateClockInUrl(params.propertyAddress);

  return {
    folderId: mainFolder.id,
    folderUrl: mainFolder.webViewLink,
    inspectionPhotosFolderId: inspectionPhotosFolder.id,
    postJobPhotosFolderId: postJobPhotosFolder.id,
    videosFolderId: videosFolder.id,
    reportsFolderId: reportsFolder.id,
    meterReadingsFolderId: meterReadingsFolder.id,
    clockInUrl,
  };
}

/**
 * Get the web URL for a Drive folder
 */
export function getDriveFolderUrl(folderId: string): string {
  return `https://drive.google.com/drive/folders/${folderId}`;
}

/**
 * Delete a folder (for cleanup/rollback purposes)
 */
export async function deleteFolder(folderId: string): Promise<void> {
  const drive = await getDriveClient();
  await drive.files.delete({ fileId: folderId });
}

/**
 * Check if a folder exists
 */
export async function folderExists(folderId: string): Promise<boolean> {
  const drive = await getDriveClient();
  try {
    await drive.files.get({ fileId: folderId, fields: 'id' });
    return true;
  } catch {
    return false;
  }
}

// ============================================
// Meter Readings Processing
// ============================================

/** Image MIME types we will attempt to analyze */
const IMAGE_MIME_TYPES = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/tiff',
];

/** Prefix added to processed files so we don't re-analyze them */
const PROCESSED_PREFIX = /^(CO|Gas_Pressure|Temp_Rise|Unknown)_/;

export interface MeterReadingResult {
  fileId: string;
  originalName: string;
  newName: string;
  reading: MeterReading;
}

/**
 * Scan the Meter Readings folder for new (unprocessed) images,
 * analyze each with the Vision API, and rename the file in Drive
 * to include the reading and safety status.
 *
 * Example rename: IMG_1234.jpg → CO_45ppm_DANGER.jpg
 *
 * Uses the existing IMPERSONATE_USER (admin@immediateresponsehvac.ca)
 * so it has permission to list and rename files in the team Drive.
 *
 * @param folderId - The ID of the 'Meter Readings' subfolder in Drive
 * @returns Array of processed reading results
 */
export async function processMeterReadings(
  folderId: string
): Promise<MeterReadingResult[]> {
  const drive = await getDriveClient();

  // List image files in the Meter Readings folder
  const listResponse = await drive.files.list({
    q: `'${folderId}' in parents and trashed = false`,
    fields: 'files(id, name, mimeType)',
    pageSize: 100,
  });

  const files = listResponse.data.files ?? [];
  console.log(`[MeterReadings] Found ${files.length} file(s) in folder ${folderId}`);

  const results: MeterReadingResult[] = [];

  for (const file of files) {
    if (!file.id || !file.name || !file.mimeType) continue;

    // Skip non-image files
    if (!IMAGE_MIME_TYPES.includes(file.mimeType)) {
      console.log(`[MeterReadings] Skipping non-image: ${file.name} (${file.mimeType})`);
      continue;
    }

    // Skip already-processed files
    if (PROCESSED_PREFIX.test(file.name)) {
      console.log(`[MeterReadings] Already processed: ${file.name}`);
      continue;
    }

    console.log(`[MeterReadings] Analyzing: ${file.name}`);

    try {
      // Download file content from Drive
      const downloadResponse = await drive.files.get(
        { fileId: file.id, alt: 'media' },
        { responseType: 'arraybuffer' }
      );
      const buffer = Buffer.from(downloadResponse.data as ArrayBuffer);

      // Analyze with Vision API
      const reading = await analyzeMeterImageFromBuffer(buffer, file.name);

      // Build the new file name:  Type_Value+Unit_STATUS.ext
      const ext = file.name.includes('.') ? file.name.substring(file.name.lastIndexOf('.')) : '.jpg';
      const typeLabel = reading.meterType.replace(/\s+/g, '_');
      const statusLabel = reading.status.toUpperCase();
      const valueLabel = `${reading.value}${reading.unit}`.replace(/"/g, 'in');
      const newName = `${typeLabel}_${valueLabel}_${statusLabel}${ext}`;

      // Rename the file in Drive
      await drive.files.update({
        fileId: file.id,
        requestBody: { name: newName },
      });

      console.log(`[MeterReadings] Renamed: ${file.name} → ${newName}`);

      results.push({
        fileId: file.id,
        originalName: file.name,
        newName,
        reading,
      });
    } catch (err) {
      console.error(`[MeterReadings] Failed to process ${file.name}:`, err);
      // Continue with remaining files
    }
  }

  console.log(`[MeterReadings] Processed ${results.length} image(s)`);
  return results;
}
