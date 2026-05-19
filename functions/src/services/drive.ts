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

// import { google, drive_v3 } from 'googleapis';

import { config } from '../config';
import { analyzeMeterImageFromBuffer, MeterReading } from './vision';
import { generateClockInUrl, checkTravelCompliance } from './location';
import { generateDistanceLogPdf } from './pdfService';

// Types
export interface CreateFolderParams {
  propertyAddress: string;
  pmName?: string | null;
  pmCompany?: string | null;
  clientName: string;
  jobCategories?: string[];
  distanceMetres?: number;
  td4Required?: boolean;
}

export interface DriveFolder {
  folderId: string;
  folderUrl: string;
  inspectionPhotosFolderId: string;
  postJobPhotosFolderId: string;
  videosFolderId: string;
  reportsFolderId: string;
  meterReadingsFolderId: string;
  purchaseOrdersFolderId: string;
  profitAndLossFolderId: string;
  profitAndLossSheetId: string;
  travelComplianceFolderId?: string;
  distanceMetres?: number;
  isSpecialWorkSite?: boolean;
  clockInUrl: string;
}

// User to impersonate for domain-wide delegation
const IMPERSONATE_USER = 'admin@immediateresponsehvac.ca';

import { gmailServiceAccountKey } from '../config';

// Initialize Drive client with domain-wide delegation
export async function getDriveClient(): Promise<any> {
  const { google } = await import('googleapis');
  const secretValue = gmailServiceAccountKey.value() || process.env.GMAIL_SERVICE_ACCOUNT_KEY;

  if (!secretValue) {
    throw new Error('GMAIL_SERVICE_ACCOUNT_KEY secret is not available');
  }

  const creds = JSON.parse(secretValue);

  const client = new google.auth.JWT({
    email: creds.client_email,
    key: creds.private_key,
    scopes: ['https://www.googleapis.com/auth/drive'],
    subject: IMPERSONATE_USER,
  });
  
  return google.drive({ version: 'v3', auth: client as any });
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

import { formatProjectName } from './quickbooks';

/**
 * Generate the folder name based on business rules
 * Uses exactly the same naming format as QBO Projects:
 * [PM/Client Name] - [Short Address] - [Work Requested Categories]
 */
export function generateFolderName(params: CreateFolderParams): string {
  const folderContact = (params.pmName && params.pmCompany) ? params.pmCompany : params.clientName;
  const rawFolderName = formatProjectName(params.propertyAddress, folderContact, params.jobCategories || []);
  return sanitizeFolderName(rawFolderName);
}

/**
 * Create a single folder in Google Drive
 */
async function createFolder(
  drive: any,
  name: string,
  parentId?: string
): Promise<{ id: string; webViewLink: string }> {
  const fileMetadata: any = {
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

/**
 * Ensures a subfolder exists within a given parent folder.
 * Returns the folder ID if it exists, or creates it and returns the new ID.
 */
export async function ensureSubfolder(
  parentFolderId: string,
  folderName: string
): Promise<string> {
  const drive = await getDriveClient();
  
  const response = await drive.files.list({
    q: `'${parentFolderId}' in parents and name='${folderName}' and mimeType='application/vnd.google-apps.folder' and trashed=false`,
    fields: 'files(id, name)',
    spaces: 'drive'
  });

  if (response.data.files && response.data.files.length > 0) {
    return response.data.files[0].id;
  }

  const newFolder = await createFolder(drive, folderName, parentFolderId);
  return newFolder.id;
}

/**
 * Copy an existing file (like a template) into a folder
 */
async function copyFile(
  drive: any,
  sourceFileId: string,
  targetFolderId: string,
  newFileName: string
): Promise<{ id: string; webViewLink: string }> {
  const response = await drive.files.copy({
    fileId: sourceFileId,
    requestBody: {
      name: newFileName,
      parents: [targetFolderId],
    },
    fields: 'id, webViewLink',
  });

  if (!response.data.id || !response.data.webViewLink) {
    throw new Error(`Failed to copy file: ${newFileName}`);
  }

  return {
    id: response.data.id,
    webViewLink: response.data.webViewLink,
  };
}

/**
 * Share folder with a specific email as Reader
 */
async function shareRecordWithEmailAsReader(
  drive: any,
  fileId: string,
  email: string
): Promise<void> {
  await drive.permissions.create({
    fileId: fileId,
    requestBody: {
      role: 'reader',
      type: 'user',
      emailAddress: email,
    },
    sendNotificationEmail: false,
  });
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
  drive: any,
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
  drive: any,
  folderId: string
): Promise<void> {
  // 1. Share with specific team group emails as Editor
  await Promise.all(
    TEAM_EDITOR_EMAILS.map(email => 
      shareFolderWithEmail(drive, folderId, email)
    )
  );

  // 2. Share with the entire domain as Writer
  // This allows all techs (@immediateresponsehvac.ca) to be identified editors
  // which enables them to share photos with external emails.
  await drive.permissions.create({
    fileId: folderId,
    requestBody: {
      role: 'writer',
      type: 'domain',
      domain: 'immediateresponsehvac.ca',
    },
  });

  // 3. Also allow anyone with link to have writer access (for PMs/clients)
  await drive.permissions.create({
    fileId: folderId,
    requestBody: {
      role: 'writer',
      type: 'anyone',
    },
  });

  // 4. Share with the AI Service Account explicitly as a viewer
  await drive.permissions.create({
    fileId: folderId,
    requestBody: {
      role: 'reader',
      type: 'user',
      emailAddress: 'hvac-intake-sa@immediate-response-ai-b18b8.iam.gserviceaccount.com',
    },
    sendNotificationEmail: false,
  });
}

/**
 * Synchronize historical reports by creating shortcuts in the new reports folder.
 * Prevents recursive loops by explicitly skipping the new main folder.
 */
async function syncHistoricalReports(
  drive: any,
  newReportsFolderId: string,
  newMainFolderId: string,
  addressPrefix: string,
  parentFolderId: string
): Promise<void> {
  try {
    console.log(`[Drive] Searching for historical folders starting with: "${addressPrefix}"`);
    
    // 1. Search for main project folders that match the address prefix
    const escapedPrefix = addressPrefix.replace(/'/g, "\\'");
    let pageToken: string | undefined = undefined;
    const historicalFolders: any[] = [];

    do {
      const resp: any = await drive.files.list({
        q: `'${parentFolderId}' in parents and mimeType = 'application/vnd.google-apps.folder' and name contains '${escapedPrefix}' and trashed = false`,
        fields: 'nextPageToken, files(id, name)',
        pageToken: pageToken
      });
      if (resp.data.files) {
        historicalFolders.push(...resp.data.files);
      }
      pageToken = resp.data.nextPageToken || undefined;
    } while (pageToken);

    // Filter out the newly created folder to avoid recursion/self-looping
    const validHistoricalFolders = historicalFolders.filter(f => f.id !== newMainFolderId);

    if (validHistoricalFolders.length === 0) {
      console.log(`[Drive] No other historical folders found for this address.`);
      return;
    }
    
    console.log(`[Drive] Found ${validHistoricalFolders.length} matching historical project folders.`);

    // 2. Find the "Reports" subfolders inside those historical folders
    const reportFilesToShortcut: Array<{id: string, name: string}> = [];

    for (const histFolder of validHistoricalFolders) {
      if (!histFolder.id) continue;
      
      const subFolderResp: any = await drive.files.list({
        q: `'${histFolder.id}' in parents and mimeType = 'application/vnd.google-apps.folder' and name = 'Reports' and trashed = false`,
        fields: 'files(id, name)'
      });

      const reportsSubfolder = subFolderResp.data.files?.[0];
      if (!reportsSubfolder || !reportsSubfolder.id) continue;

      // 3. Get all files inside the historical 'Reports' folder
      let filesPageToken: string | undefined = undefined;
      do {
        const filesResp: any = await drive.files.list({
          q: `'${reportsSubfolder.id}' in parents and mimeType != 'application/vnd.google-apps.folder' and trashed = false`,
          fields: 'nextPageToken, files(id, name)',
          pageToken: filesPageToken
        });
        
        if (filesResp.data.files) {
          for (const file of filesResp.data.files) {
            if (file.id && file.name) {
              reportFilesToShortcut.push({ id: file.id, name: file.name });
            }
          }
        }
        filesPageToken = filesResp.data.nextPageToken || undefined;
      } while (filesPageToken);
    }

    // 4. Create shortcuts in the new "Reports" folder
    if (reportFilesToShortcut.length > 0) {
      console.log(`[Drive] Creating ${reportFilesToShortcut.length} file shortcuts in new Reports folder...`);
      const shortcutPromises = reportFilesToShortcut.map(file => 
        drive.files.create({
          requestBody: {
            name: file.name,
            mimeType: 'application/vnd.google-apps.shortcut',
            shortcutDetails: { targetId: file.id },
            parents: [newReportsFolderId]
          },
          fields: 'id'
        })
      );

      // Run them in chunks of 5 to respect rate limits
      for (let i = 0; i < shortcutPromises.length; i += 5) {
        await Promise.all(shortcutPromises.slice(i, i + 5));
      }
      console.log(`[Drive] Historical reports sync complete.`);
    } else {
      console.log(`[Drive] No historical report files found to shortcut.`);
    }

  } catch (error) {
    console.error(`[Drive] Error syncing historical reports:`, error);
  }
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
 * - Restricted: Purchase Orders
 * - Restricted: Profit and Loss
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

  // Check compliance BEFORE the Promise.all
  let compliance = { isSpecialWorkSite: false, distanceMetres: 0 };
  if (params.distanceMetres !== undefined && params.distanceMetres > 0) {
    compliance.distanceMetres = params.distanceMetres;
    compliance.isSpecialWorkSite = params.distanceMetres > 80000;
    console.log(`[Drive] Using client-provided distance: ${(params.distanceMetres / 1000).toFixed(2)} km`);
  } else {
    compliance = await checkTravelCompliance(params.propertyAddress);
  }

  // Create subfolders in parallel
  const subfolderPromises: Promise<any>[] = [
    createFolder(drive, 'Inspection Photos', mainFolder.id),
    createFolder(drive, 'Post Job Photos', mainFolder.id),
    createFolder(drive, 'Videos', mainFolder.id),
    createFolder(drive, 'Reports', mainFolder.id),
    createFolder(drive, 'Meter Readings', mainFolder.id),
  ];

  let travelFolderId: string | undefined;

  if (compliance.isSpecialWorkSite) {
    subfolderPromises.push(createFolder(drive, '00_Tax-Compliance_Travel_Receipts', mainFolder.id).then(f => {
      travelFolderId = f.id;
      return f;
    }));
  }

  const [inspectionPhotosFolder, postJobPhotosFolder, videosFolder, reportsFolder, meterReadingsFolder] = await Promise.all(subfolderPromises);
  
  if (compliance.isSpecialWorkSite && travelFolderId) {
    try {
      const pdfBuffer = await generateDistanceLogPdf(params.propertyAddress, compliance.distanceMetres, params.td4Required);
      await uploadFileToFolder(travelFolderId, 'CRA_Distance_Log.pdf', pdfBuffer.toString('base64'), 'application/pdf');
      console.log(`[Drive] CRA_Distance_Log.pdf successfully uploaded to Travel Receipts folder.`);
    } catch (e) {
      console.error(`[Drive] Failed to generate/upload CRA distance logging PDF`, e);
    }
  }

  // Create the restricted Purchase Orders folder outside the main folder tree
  const purchaseOrdersFolderName = `04_Purchase_Orders_${folderName}`;
  const purchaseOrdersFolder = await createFolder(
    drive,
    purchaseOrdersFolderName,
    config.googleDrive.parentFolderId
  );

  // Create the restricted Profit and Loss folder outside the main folder tree
  const pnlFolderName = `05_Profit_and_Loss_${folderName}`;
  const pnlFolder = await createFolder(
    drive,
    pnlFolderName,
    config.googleDrive.parentFolderId
  );

  // Create shortcuts inside the main folder
  await drive.files.create({
    requestBody: {
      name: '04_Purchase_Orders',
      mimeType: 'application/vnd.google-apps.shortcut',
      shortcutDetails: { targetId: purchaseOrdersFolder.id },
      parents: [mainFolder.id],
    },
    fields: 'id',
  });

  await drive.files.create({
    requestBody: {
      name: '05_Profit_and_Loss',
      mimeType: 'application/vnd.google-apps.shortcut',
      shortcutDetails: { targetId: pnlFolder.id },
      parents: [mainFolder.id],
    },
    fields: 'id',
  });

  // Set permissions on the main folder (inherits to standard subfolders)
  await setFolderPermissions(drive, mainFolder.id);

  // Explicitly share the Purchase Orders folder with Ops
  await shareFolderWithEmail(drive, purchaseOrdersFolder.id, 'ops@immediateresponsehvac.ca');

  // ALSO share Purchase Orders folder with 'anyone' to ensure QBO sync service can read/download attachments automatically
  await drive.permissions.create({
    fileId: purchaseOrdersFolder.id,
    requestBody: { role: 'writer', type: 'anyone' },
  });

  // Explicitly share the P&L folder ONLY with specified viewers (admin creates it, so it owns it)
  await shareRecordWithEmailAsReader(drive, pnlFolder.id, 'tyler@immediateresponsehvac.ca');
  await shareRecordWithEmailAsReader(drive, pnlFolder.id, 'louise@immediateresponsehvac.ca');

  // Copy the Master Job Template into the new P&L folder
  const MASTER_TEMPLATE_ID = '1X5KJObd9ayBWFnkXEMOloxTyPpHXtOd7AJqWzw9kpBw';
  const newSheetName = `P&L - ${folderName}`;
  const copiedSheet = await copyFile(drive, MASTER_TEMPLATE_ID, pnlFolder.id, newSheetName);

  // Sync historical reports asynchronously into the new Reports folder
  // Extract just the short address without the PM/Company stuff
  const addressPrefix = folderName.includes(' - ') 
    ? folderName.split(' - ')[0].trim() 
    : folderName;
  
  await syncHistoricalReports(
    drive, 
    reportsFolder.id, 
    mainFolder.id, 
    addressPrefix, 
    config.googleDrive.parentFolderId
  );

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
    purchaseOrdersFolderId: purchaseOrdersFolder.id,
    profitAndLossFolderId: pnlFolder.id,
    profitAndLossSheetId: copiedSheet.id,
    travelComplianceFolderId: travelFolderId,
    distanceMetres: compliance.distanceMetres,
    isSpecialWorkSite: compliance.isSpecialWorkSite,
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
 * Upload a file to a specific Drive folder
 * @param parentId - The destination folder ID
 * @param fileName - Name of the file with extension
 * @param base64Data - Base64 encoded file content
 * @param mimeType - File MIME type
 */
export async function uploadFileToFolder(
  parentId: string,
  fileName: string,
  base64Data: string,
  mimeType: string
): Promise<string> {
  const drive = await getDriveClient();
  
  const fileMetadata: any = {
    name: fileName,
    parents: [parentId],
  };
  
  // Convert base64 to stream
  const content = Buffer.from(base64Data, 'base64');
  const media = {
    mimeType,
    body: require('stream').Readable.from(content),
  };
  
  const response = await drive.files.create({
    requestBody: fileMetadata,
    media: media,
    fields: 'id',
  });
  
  return response.data.id!;
}

/**
 * Upload a file to Drive, make it readable to anyone (for Docs API), and return ID + URL
 */
export async function uploadFileAndGetPublicUrl(
  parentId: string,
  fileName: string,
  base64Data: string,
  mimeType: string
): Promise<{ id: string, publicUrl: string }> {
  const drive = await getDriveClient();
  
  const fileMetadata = {
    name: fileName,
    parents: [parentId],
  };
  
  const content = Buffer.from(base64Data, 'base64');
  const media = {
    mimeType,
    body: require('stream').Readable.from(content),
  };
  
  const response = await drive.files.create({
    requestBody: fileMetadata,
    media: media,
    fields: 'id',
  });
  
  const fileId = response.data.id!;
  
  await drive.permissions.create({
    fileId: fileId,
    requestBody: {
      role: 'reader',
      type: 'anyone',
    }
  });

  const file = await drive.files.get({ fileId: fileId, fields: 'webContentLink' });
  return { id: fileId, publicUrl: file.data.webContentLink! };
}


/**
 * Find a file by name (partial match) in a specific folder
 */
export async function findFileInFolder(
  parentId: string,
  fileNamePattern: string
): Promise<any | null> {
  const drive = await getDriveClient();
  const response = await drive.files.list({
    q: `'${parentId}' in parents and name contains '${fileNamePattern}' and trashed = false`,
    fields: 'files(id, name, mimeType)',
    pageSize: 1,
  });

  return response.data.files?.[0] || null;
}

/**
 * Download file content as a Buffer
 */
export async function downloadFileBuffer(fileId: string): Promise<Buffer> {
  const drive = await getDriveClient();
  const response = await drive.files.get(
    { fileId: fileId, alt: 'media' },
    { responseType: 'arraybuffer' }
  );
  return Buffer.from(response.data as ArrayBuffer);
}

/**
 * Delete a folder (for cleanup/rollback purposes)
 */
export async function deleteFolder(folderId: string): Promise<void> {
  const drive = await getDriveClient();
  await drive.files.delete({ fileId: folderId, supportsAllDrives: true });
}

/**
 * Rename an existing folder in Google Drive
 */
export async function renameFolder(folderId: string, newName: string): Promise<void> {
  const drive = await getDriveClient();
  await drive.files.update({
    fileId: folderId,
    requestBody: { name: newName }
  });
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
