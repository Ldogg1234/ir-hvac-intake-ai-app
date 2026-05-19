/**
 * Google Cloud Vision Service
 * Analyzes meter reading photos (CO, Gas Pressure, Temperature Rise)
 * and classifies them with a safety status.
 */

// import { ImageAnnotatorClient } from '@google-cloud/vision';

import * as fs from 'fs';

// ============================================
// Types
// ============================================

export type MeterType = 'CO' | 'Gas Pressure' | 'Temp Rise' | 'Unknown';
export type SafetyStatus = 'Safe' | 'Warning' | 'Dangerous';

export interface MeterReading {
  meterType: MeterType;
  value: number;
  unit: string;
  status: SafetyStatus;
  rawText: string;
}

export interface RatingPlateData {
  brand?: string;
  modelNumber?: string;
  serialNumber?: string;
  manufactureDate?: string;
  btuInput?: string;
  voltage?: string;
  rawText: string;
}

export type ForensicCategory = 
  | 'Rating Plate' 
  | 'Primary Peril Evidence' 
  | 'Secondary Damage' 
  | 'Meter Reading' 
  | 'Contextual Wide-Shot'
  | 'Uncategorized';

export interface VisualAnalysis {
  category: ForensicCategory;
  labels: string[];
  hasTapeMeasure: boolean;
  hasMultimeter: boolean;
  ocrText?: string;
}

// ============================================
// Safety Thresholds (HVAC industry standard)
// ============================================

const CO_THRESHOLDS = {
  /** ppm — Safe upper bound (inclusive) */
  safe: 9,
  /** ppm — Warning upper bound (inclusive); above this is Dangerous */
  warning: 35,
};

const GAS_PRESSURE_THRESHOLDS = {
  /** inches WC — Safe range for residential natural gas */
  safeMin: 3.2,
  safeMax: 3.8,
  /** Outer warning band; outside this is Dangerous */
  warningMin: 2.5,
  warningMax: 4.5,
};

const TEMP_RISE_THRESHOLDS = {
  /** °F across heat exchanger — Safe range */
  safeMin: 30,
  safeMax: 60,
  /** Outer warning band; outside this is Dangerous */
  warningMin: 20,
  warningMax: 70,
};

// ============================================
// Classification helpers
// ============================================

/** Keywords used to identify meter type from OCR text */
const METER_PATTERNS: { type: MeterType; keywords: RegExp }[] = [
  { type: 'CO', keywords: /\b(co|carbon\s*monoxide|co2?[\s-]?detect|ppm)\b/i },
  { type: 'Gas Pressure', keywords: /\b(pressure|wc|w\.c\.|inches|manifold|gas\s*valve|manometer)\b/i },
  { type: 'Temp Rise', keywords: /\b(temp(erature)?\s*rise|delta\s*t|[Δδ]t|rise|supply|return)\b/i },
];

/**
 * Extract the first plausible numeric reading from OCR text.
 * Handles integers and decimals (e.g. "3.5", "45", "0.7").
 */
function extractNumericValue(text: string): number | null {
  // Look for numbers with optional decimal, possibly followed by a unit
  const match = text.match(/(\d{1,5}(?:\.\d{1,3})?)\s*(?:ppm|"|wc|w\.c\.|°?f|in)?/i);
  return match ? parseFloat(match[1]) : null;
}

/**
 * Determine meter type from OCR text.
 */
function classifyMeterType(text: string): MeterType {
  for (const pattern of METER_PATTERNS) {
    if (pattern.keywords.test(text)) {
      return pattern.type;
    }
  }
  return 'Unknown';
}

/**
 * Determine unit string for a given meter type.
 */
function unitForType(meterType: MeterType): string {
  switch (meterType) {
    case 'CO': return 'ppm';
    case 'Gas Pressure': return '"WC';
    case 'Temp Rise': return '°F';
    default: return '';
  }
}

/**
 * Evaluate safety status based on meter type and value.
 */
function evaluateStatus(meterType: MeterType, value: number): SafetyStatus {
  switch (meterType) {
    case 'CO':
      if (value <= CO_THRESHOLDS.safe) return 'Safe';
      if (value <= CO_THRESHOLDS.warning) return 'Warning';
      return 'Dangerous';

    case 'Gas Pressure':
      if (value >= GAS_PRESSURE_THRESHOLDS.safeMin && value <= GAS_PRESSURE_THRESHOLDS.safeMax) return 'Safe';
      if (value >= GAS_PRESSURE_THRESHOLDS.warningMin && value <= GAS_PRESSURE_THRESHOLDS.warningMax) return 'Warning';
      return 'Dangerous';

    case 'Temp Rise':
      if (value >= TEMP_RISE_THRESHOLDS.safeMin && value <= TEMP_RISE_THRESHOLDS.safeMax) return 'Safe';
      if (value >= TEMP_RISE_THRESHOLDS.warningMin && value <= TEMP_RISE_THRESHOLDS.warningMax) return 'Warning';
      return 'Dangerous';

    default:
      return 'Warning'; // Unknown meter type — flag for human review
  }
}

// ============================================
// Public API
// ============================================

/** Shared Vision client (re-used across invocations within the same instance) */
let client: any = null;

async function getVisionClient() {
  if (!client) {
    const { ImageAnnotatorClient } = await import('@google-cloud/vision');
    client = new ImageAnnotatorClient();
  }
  return client;
}


/**
 * Analyze a meter image and return the reading with safety status.
 *
 * @param imagePath - Local file path (e.g. /tmp/meter.jpg) or GCS URI (gs://…)
 * @returns Parsed meter reading with type, value, unit, and safety status
 */
export async function analyzeMeterImage(imagePath: string): Promise<MeterReading> {
  const visionClient = await getVisionClient();

  // Use TEXT_DETECTION for OCR on the meter photo
  const [result] = await visionClient.textDetection(imagePath);
  const detections = result.textAnnotations;
  const rawText = detections?.[0]?.description ?? '';

  console.log(`[Vision] Raw OCR text for ${imagePath}: "${rawText}"`);

  // Classify the reading type
  const meterType = classifyMeterType(rawText);

  // Extract the numeric value
  const value = extractNumericValue(rawText);
  if (value === null) {
    console.warn(`[Vision] Could not extract numeric value from: "${rawText}"`);
    return {
      meterType,
      value: 0,
      unit: unitForType(meterType),
      status: 'Warning',
      rawText,
    };
  }

  const status = evaluateStatus(meterType, value);
  const unit = unitForType(meterType);

  console.log(`[Vision] Result — Type: ${meterType}, Value: ${value}${unit}, Status: ${status}`);

  return { meterType, value, unit, status, rawText };
}

/**
 * Analyze meter image from a Buffer (used by Drive integration where
 * file content is downloaded directly rather than read from disk).
 *
 * Writes a temporary file under /tmp, delegates to analyzeMeterImage,
 * then cleans up.
 */
export async function analyzeMeterImageFromBuffer(
  buffer: Buffer,
  fileName: string
): Promise<MeterReading> {
  const tmpPath = `/tmp/${fileName}`;
  fs.writeFileSync(tmpPath, buffer);
  try {
    return await analyzeMeterImage(tmpPath);
  } finally {
    try { fs.unlinkSync(tmpPath); } catch { /* best-effort cleanup */ }
  }
}

/**
 * Extract Brand, Model Number, and Serial Number from a Rating Plate image.
 */
export async function extractRatingPlateData(buffer: Buffer): Promise<RatingPlateData> {
  console.log(`[Vision] Extracting rating plate data using Gemini 2.5 Flash...`);
  
  // Detect basic mime type from magic bytes
  let mimeType = 'image/jpeg';
  if (buffer.length > 8) {
    if (buffer[0] === 0xFF && buffer[1] === 0xD8 && buffer[2] === 0xFF) mimeType = 'image/jpeg';
    else if (buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4E && buffer[3] === 0x47) mimeType = 'image/png';
    else if (buffer[4] === 0x66 && buffer[5] === 0x74 && buffer[6] === 0x79 && buffer[7] === 0x70) mimeType = 'image/heic';
    else if (buffer[0] === 0x52 && buffer[1] === 0x49 && buffer[2] === 0x46 && buffer[3] === 0x46) mimeType = 'image/webp';
  }

  try {
    const { getGenerativeModel, getText } = await import('./ai');
    const aiModel = await getGenerativeModel({
      modelName: 'gemini-2.5-flash',
      responseMimeType: 'application/json',
      systemInstruction: `You are an expert HVAC technician and forensic auditor. Your task is to extract the EXACT technical details from an HVAC equipment rating plate image.
      
      FIELDS TO EXTRACT:
      - brand: The manufacturer name (e.g., Carrier, Lennox, Goodman).
      - modelNumber: The primary model identifier. Look for 'MOD', 'M/N', or 'Model'.
      - serialNumber: The unique serial identifier. Look for 'SER', 'S/N', or 'Serial'.
      - manufactureDate: The date of manufacture. Often formatted as MM/YY, WW/YY, or YYYY.
      - btuInput: The heating/cooling capacity (e.g., 80,000 BTU, 2.5 Ton).
      - voltage: The electrical requirements (e.g., 115V, 208/230V, 1 PH).

      CRITICAL RULES:
      1. If a field is present but slightly blurry, use your technical knowledge to provide the most likely reading.
      2. If a field is missing or completely illegible, leave it as an empty string.
      3. Return ONLY valid JSON.
      4. DO NOT hallucinate numbers that are not visible.`
    });

    const result = await aiModel.generateContent([
      { text: "Extract rating plate details." },
      { inlineData: { data: buffer.toString('base64'), mimeType } }
    ]);

    const jsonText = getText(result);
    console.log(`[Vision] Gemini Rating Plate OCR Result: ${jsonText}`);
    
    let parsed: any = {};
    try {
      parsed = JSON.parse(jsonText);
    } catch (e) {
      console.warn('[Vision] Failed to parse Gemini JSON output', e);
    }

    return {
      brand: parsed.brand || undefined,
      modelNumber: parsed.modelNumber || undefined,
      serialNumber: parsed.serialNumber || undefined,
      manufactureDate: parsed.manufactureDate || undefined,
      btuInput: parsed.btuInput || undefined,
      voltage: parsed.voltage || undefined,
      rawText: jsonText
    };
  } catch (error) {
    console.error(`[Vision] Gemini extraction failed, falling back to basic Vision API:`, error);
    
    // Fallback to old Cloud Vision regex
    const visionClient = await getVisionClient();
    const [result] = await visionClient.textDetection(buffer);
    const rawText = result.textAnnotations?.[0]?.description ?? '';
    
    const brands = ['Carrier', 'Lennox', 'Goodman', 'York', 'Bryant', 'Trane', 'American Standard', 'Rheem', 'Ruud', 'KeepRite', 'Tempstar', 'Heil'];
    const brandMatch = brands.find(b => new RegExp(`\\b${b}\\b`, 'i').test(rawText));
    const modelMatch = rawText.match(/\b(?:MOD|M\/N|MODEL|MODEL\s*NO\.?)\s*:?\s*([A-Z0-9-]{5,20})\b/i);
    const serialMatch = rawText.match(/\b(?:SER|S\/N|SERIAL|SERIAL\s*NO\.?)\s*:?\s*([A-Z0-9]{7,15})\b/i);
    const mfgMatch = rawText.match(/\b(?:MFG|DATE|MANUFACTURED)\s*:?\s*(\d{2}\/\d{2,4}|\d{4})\b/i);
    const btuMatch = rawText.match(/\b(\d{2,3},000|\d{2,3}\s*MBH)\s*(?:BTU|INPUT)?\b/i);
    const voltageMatch = rawText.match(/\b(\d{3}\s*V|\d{3}\s*VOLTS|208[/-]230\s*V|115\s*V|460\s*V)\b/i);

    return {
      brand: brandMatch,
      modelNumber: modelMatch?.[1],
      serialNumber: serialMatch?.[1],
      manufactureDate: mfgMatch?.[1],
      btuInput: btuMatch?.[1],
      voltage: voltageMatch?.[1],
      rawText
    };
  }
}

/**
 * Detect Visual Anchors and categorize the photo for forensic integrity.
 */
export async function analyzeForensicPhoto(buffer: Buffer): Promise<VisualAnalysis> {
  const visionClient = await getVisionClient();
  
  const [result] = await visionClient.annotateImage({
    image: { content: buffer },
    features: [
      { type: 'LABEL_DETECTION', maxResults: 15 },
      { type: 'OBJECT_LOCALIZATION' },
      { type: 'TEXT_DETECTION' }
    ]
  });

  const labels = result.labelAnnotations?.map((l: any) => l.description?.toLowerCase() || '') || [];
  const objects = result.localizedObjectAnnotations?.map((o: any) => o.name?.toLowerCase() || '') || [];
  const rawText = result.textAnnotations?.[0]?.description || '';

  const hasTapeMeasure = objects.includes('measuring instrument') || labels.includes('tape measure') || labels.includes('ruler');
  const hasMultimeter = objects.includes('electronic device') || labels.includes('multimeter') || labels.includes('voltmeter');
  const hasRatingPlate = rawText.includes('MODEL') || rawText.includes('SERIAL') || rawText.includes('M/N');

  let category: ForensicCategory = 'Uncategorized';

  if (hasRatingPlate) {
    category = 'Rating Plate';
  } else if (hasMultimeter) {
    category = 'Meter Reading';
  } else if (labels.some((l: string) => ['flood', 'water', 'fire', 'soot', 'smoke', 'damage', 'impact'].includes(l))) {
    category = 'Primary Peril Evidence';
  } else if (labels.some((l: string) => ['rust', 'corrosion', 'crack', 'leak'].includes(l))) {
    category = 'Secondary Damage';
  } else if (labels.some((l: string) => ['room', 'house', 'building', 'basement', 'exterior'].includes(l))) {
    category = 'Contextual Wide-Shot';
  }

  return {
    category,
    labels,
    hasTapeMeasure,
    hasMultimeter,
    ocrText: hasRatingPlate ? rawText : undefined
  };
}
