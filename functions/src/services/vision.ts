/**
 * Google Cloud Vision Service
 * Analyzes meter reading photos (CO, Gas Pressure, Temperature Rise)
 * and classifies them with a safety status.
 */

import { ImageAnnotatorClient } from '@google-cloud/vision';
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
let client: ImageAnnotatorClient | null = null;

function getVisionClient(): ImageAnnotatorClient {
  if (!client) {
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
  const visionClient = getVisionClient();

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
