/**
 * Professional Report Generator Service
 * Uses Vertex AI (Gemini) to rewrite messy technician notes into
 * a structured, professional HVAC report suitable for a branded PDF.
 */

import { FURNACE_INSPECTION_MATRIX_MD } from '../config/inspectionMatrix';
import { TSSA_HVAC_STANDARDS_MD } from '../config/tssaMatrix';
import { OBC_HVAC_STANDARDS_MD } from '../config/obcMatrix';

// ============================================
// Types
// ============================================

export interface TechnicalMetric {
  /** e.g. 'Gas Pressure', 'CO Level', 'Temp Rise', 'Flame Sensor' */
  metric: string;
  /** Measured value */
  value: number;
  /** e.g. 'in w.c.', 'ppm', '°F', 'µA' */
  unit: string;
  /** safe | warning | dangerous */
  status: 'safe' | 'warning' | 'dangerous';
  /** Manufacturer-recommended or industry-standard value */
  recommended: number;
  /** URL of the inspection photo this metric was extracted from (Source Evidence) */
  sourcePhotoUrl: string;
  /** Specific manual page, TSSA code, or standard refutation when metric is warning/dangerous */
  citation?: string;
}

export type SystemStatus = 'Salvageable' | 'Partial Repair' | 'Total Loss';

export interface TechnicalJustification {
  /** Component requiring action (e.g. 'Heat Exchanger', 'Control Board') */
  component: string;
  /** Why replacement/repair is required — reference TSSA code or manufacturer spec */
  justification: string;
  /** TSSA code, CSA standard, or manufacturer bulletin that mandates the action */
  standard: string;
}

export interface ProfessionalReport {
  executiveSummary: string;
  systemFindings: string;
  recommendations: string[];
  safetyNotes: string;
  /** Structured metrics extracted from technician notes + inspection photos */
  technicalMetrics: TechnicalMetric[];
  /** Equipment identification from inspection photos */
  equipmentId: {
    brand: string;
    model: string;
    serial: string;
    age: string;
    refrigerant: string;
  };
  // --- Insurance Adjuster Fields ---
  /** Overall system verdict: Salvageable, Partial Repair, or Total Loss */
  systemStatus: SystemStatus;
  /** Root cause of damage (e.g. 'Flood submersion', 'Fire/smoke exposure', 'Age-related failure') */
  causeOfLoss: string;
  /** Full scope of work required to bring system to code-compliant operation */
  scopeOfRemediation: string;
  /** Per-component TSSA/manufacturer-backed justification for each replacement */
  technicalJustifications: TechnicalJustification[];
  /** Manual quote extracted from OEM documentation */
  manualQuote?: {
    quote: string;
    pageNumber: number | string;
    manualTitle: string;
  };
  /** Structured line items for QuickBooks Online estimates */
  qboLineItems?: {
    Description: string;
    Amount: number;
    UnitPrice: number;
    Qty: number;
  }[];
  /** AI-selected photos to include in the report with descriptions */
  relevantPhotos?: {
    url: string;
    caption: string;
  }[];
}

// ============================================
// AI Prompt & Schema
// ============================================

const SYSTEM_PROMPT = `
You are an expert HVAC Technical Writer producing reports for INSURANCE ADJUSTERS in the Canadian market.
The primary audience is NOT a homeowner — it is an Insurance Adjuster evaluating a claim.

PRIORITIES (in order):
1. CAUSE OF LOSS — Clearly state the root cause of damage (e.g., flood submersion, fire/smoke
   exposure, storm damage, age-related catastrophic failure). This must be specific and defensible.
2. SCOPE OF REMEDIATION — Detail every component that must be replaced or repaired to restore
   the system to code-compliant, safe operation. Be exhaustive.
3. SAFETY & CODE VIOLATIONS — Cite specific TSSA regulations, CSA standards (e.g., CSA B149.1),
   OBC (Ontario Building Code) rules, or manufacturer service bulletins that mandate each action. An adjuster needs to see WHY
   a component cannot be salvaged — not marketing fluff.

CRITICAL RULES:
- NO FLUFF. Every recommendation must include a 'Technical Justification' citing a specific
  TSSA code, CSA standard, OBC rule, or manufacturer specification that requires the action.
- Do NOT use generic sales language. The adjuster needs technical evidence, not upselling.
- If a component is reusable, say so explicitly to build credibility.

TSSA & OBC CODES MATRIX:
You MUST prioritize citing these specific rules when writing technical justifications:
${TSSA_HVAC_STANDARDS_MD}

${OBC_HVAC_STANDARDS_MD}


SYSTEM STATUS DETERMINATION:
- "Salvageable": System can be returned to safe operation with minor repairs (<30% of replacement cost).
- "Partial Repair": Some components are destroyed but the core unit can be repaired (30-70% of replacement).
- "Total Loss": System cannot be economically or safely repaired. Triggers include:
  * Cracked heat exchanger * Submerged electronics/control board * Fire-damaged gas valve
  * Compressor failure on obsolete refrigerant * Structural damage to cabinet/frame
  If ANY of these are detected in the technician notes, set systemStatus to "Total Loss".

KINETIC ENERGY & IMPACT LOGIC:
If the technician mentions "Impact", "Crushed", "Collapsed", or "Fallen" (Secondary Peril):
1. MANDATORY PARAGRAPH: Include the following refutation in the 'systemFindings' or 'executiveSummary' if Impact is identified during a Fire/Flood event:
   "Beyond thermal exposure, the appliance has suffered a Kinetic Energy Transfer resulting in structural enclosure failure. Even if the unit could be cleaned of soot, the mechanical deformation of the chassis voids the UL/CSA Listing as internal electrical clearances are no longer within manufacturer-specified tolerances. Per OESC Rule 2-200, an electrical enclosure that cannot maintain its original geometry is unserviceable."
2. TECHNICAL JUSTIFICATION: Add a justification entry for "Cabinet/Enclosure" citing "OESC Rule 2-200".

TECHNICAL METRICS EXTRACTION:
Extract EVERY measurable reading into the technicalMetrics array:
- Gas Pressure (manifold/inlet) — in w.c. — safe range: 3.2–3.8
- CO Level — ppm — safe: ≤9, warning: 10–35, dangerous: >35
- Temperature Rise (delta T) — °F — safe range: 30–60
- Flame Sensor (rectification signal) — µA — safe: ≥2.0
- Static Pressure (supply/return) — in w.c. — safe: ≤0.5 each
- Refrigerant Charge — psi — varies by system
- Capacitor Rating — µF — compare to nameplate
- Motor Amperage — A — compare to FLA rating
Classify each as 'safe', 'warning', or 'dangerous'. Reference sourcePhotoUrl if provided.
IMPORTANT: When referencing readings that suggest something is wrong (warning or dangerous), you MUST quote or reference the page in the equipment manual, the TSSA code, the Ontario Building Code, or the applicable standard that demonstrates this metric is out of bounds. Place this reference in the "citation" field.

EQUIPMENT IDENTIFICATION:
Extract Brand, Model, Serial, approximate Age, and Refrigerant type.
Use "Not visible" or "Not specified" for any value that cannot be determined.

TECHNICAL JUSTIFICATIONS:
For EACH component that needs replacement or repair, provide a technicalJustification entry with:
- component: the specific part (e.g., "Heat Exchanger", "Control Board", "Inducer Motor")
- justification: WHY it must be replaced — cite measurements, visual evidence, or failure mode
- standard: the specific TSSA/CSA/manufacturer standard that mandates the action
  (e.g., "TSSA O.Reg. 212/01 s.14", "CSA B149.1-15 cl.6.19", "Trane SB-2019-04")
CRITICAL: If duct cleaning, sanitizing, or remediation is recommended or mentioned, you MUST provide a relevant NADCA (National Air Duct Cleaners Association) standard citation as a technical justification. You MUST cite specific language, the exact section number, and the specific page number of the NADCA standard (e.g., ACR 2021, Section 4.1, Page 12) explaining exactly what the standard dictates. Do NOT use generic referencing like "check the manual" or "refer to NADCA standards".

QUICKBOOKS LINE ITEMS (CRITICAL):
Logically separate the work into distinct billable line items.
- Line 1 should usually be the primary replacement or repair (e.g. "Remove and Replace existing furnace with a comparable Furnace (includes material and labor)").
- Line 2 should be secondary work like cleaning, sanitizing, or venting (e.g. "Complete Cleaning and Sanitizing of both the furnace and ventilation System").
- Extract the dollar amounts from the technician notes. If they say "$6118.00 plus H.S.T.", the Amount is 6118.
- UnitPrice should equal Amount (Qty is typically 1).
- Use professional phrasing like: "Remove and Replace...", "Complete Cleaning and Sanitizing...", "Troubleshooting and Service...".

Tone: Authoritative, evidence-based, insurance-grade. No marketing language.
Efficiency: Replacement recommendations must be 96%+ AFUE per Canadian market requirements.
Structure: Output JSON matching the provided schema.

REQUIRED JSON OUTPUT FORMAT:
{
  "executiveSummary": "...",
  "systemFindings": "...",
  "recommendations": ["...", "..."],
  "safetyNotes": "...",
  "technicalMetrics": [
    {
      "metric": "...",
      "value": 123.4,
      "status": "safe|warning|dangerous",
      "recommended": 123.4,
      "sourcePhotoUrl": "...",
      "citation": "..."
    }
  ],
  "equipmentId": {
    "brand": "...",
    "model": "...",
    "serial": "...",
    "age": "...",
    "refrigerant": "..."
  },
  "systemStatus": "Salvageable|Partial Repair|Total Loss",
  "causeOfLoss": "...",
  "scopeOfRemediation": "...",
  "technicalJustifications": [
    {
      "component": "...",
      "justification": "...",
      "standard": "..."
    }
  ],
  "qboLineItems": [
    {
      "Description": "...",
      "Amount": 123.45,
      "UnitPrice": 123.45,
      "Qty": 1
    }
  ],
  "relevantPhotos": [
    {
      "url": "...",
      "caption": "..."
    }
  ]
}
`;
const COMPLETION_SYSTEM_PROMPT = `
You are an expert HVAC Technical Writer producing a Job Completion Report for a project management and administrative audience.
The primary audience is the project manager reviewing the completed work.

PRIORITIES (in order):
1. WORK PERFORMED — Clearly and exhaustively document the exact work that was completed by the technician based on their notes.
2. MATERIALS & EQUIPMENT USED — List all materials, parts, or equipment installed or replaced.
3. FOLLOW-UP / PENDING WORK — Note if anything was left incomplete or requires a return visit.

CRITICAL RULES:
- NO FLUFF. Be objective and clear.
- Do NOT fabricate technical justifications or TSSA codes unless explicitly mentioned by the technician.
- This is NOT an insurance inspection. Do not try to determine "Cause of Loss", "System Status" (Salvageable/Total Loss) or "Repair vs Replace" unless relevant.
- Do NOT include citations to manuals or codes unless the technician explicitly provided them.

TECHNICAL METRICS EXTRACTION:
Extract any measurable readings taken after the repair/installation (e.g., Gas Pressure, CO Level) into the technicalMetrics array.

EQUIPMENT IDENTIFICATION:
Extract Brand, Model, Serial of any new equipment installed or existing equipment serviced.

QUICKBOOKS LINE ITEMS:
Extract any dollar amounts or distinct billable tasks mentioned as qboLineItems.

Tone: Professional, administrative, clear documentation of work performed.
Structure: Output JSON matching the provided schema.

REQUIRED JSON OUTPUT FORMAT:
{
  "executiveSummary": "A concise 1-2 sentence summary of the completed work.",
  "systemFindings": "Detailed description of the work performed, steps taken, and materials used.",
  "recommendations": ["Any follow-up actions or maintenance recommendations for the client..."],
  "safetyNotes": "Any safety checks performed or safety issues resolved.",
  "technicalMetrics": [
    // Include only if measurements were explicitly mentioned
  ],
  "equipmentId": {
    "brand": "...",
    "model": "...",
    "serial": "...",
    "age": "...",
    "refrigerant": "..."
  },
  "systemStatus": "Salvageable",
  "causeOfLoss": "N/A",
  "scopeOfRemediation": "N/A",
  "technicalJustifications": [
    // Only include if specific parts were replaced and justified by the tech
  ],
  "qboLineItems": [
    // Only include if pricing or billable line items are mentioned
  ],
  "relevantPhotos": [
    {
      "url": "...",
      "caption": "..."
    }
  ]
}
`;

// ============================================
// Public API
// ============================================

import { getGenerativeModel } from './ai';

/**
 * Takes raw technician notes (and optional inspection photo URLs) and generates
 * a structured, professional report with extracted technical metrics using Gemini.
 *
 * @param rawNotes - The raw notes provided by the HVAC technician.
 * @param inspectionPhotoUrls - Optional array of photo URLs for source evidence tagging.
 * @returns A structured ProfessionalReport object including technicalMetrics.
 */
export async function generateProfessionalReport(
  rawNotes: string,
  inspectionPhotoUrls?: string[],
  reportType: string = 'Inspection',
  claimType: string = 'Damage'
): Promise<ProfessionalReport> {
  if (!rawNotes || rawNotes.trim() === '') {
    throw new Error('Raw notes are required to generate a report.');
  }

  const { getGenerativeModel, getText } = await import('./ai');
  const { huntManual } = await import('./manual-hunter');
  
  // STEP 1: Quick Equipment Extraction for Manual Hunting
  let manualContext = '';
  try {
    console.log('[Report Generator] Performing pre-extraction of equipment for manual hunting...');
    const quickModel = await getGenerativeModel({
      systemInstruction: 'Extract the primary HVAC equipment mentioned in these notes.',
      responseMimeType: 'application/json',
      temperature: 0.1
    });
    
    const eqPrompt = `Extract the HVAC equipment mentioned in these notes. Return ONLY JSON: { "brand": "string", "model": "string", "serial": "string" }. If not found, use "Not specified". Notes:\n${rawNotes}`;
    
    const eqRes = await quickModel.generateContent(eqPrompt);
    const eqData = JSON.parse(getText(eqRes.response) || '{}');
    
    if (eqData.brand && eqData.brand !== 'Not specified' && eqData.model && eqData.model !== 'Not specified') {
      console.log(`[Report Generator] Extracted equipment: ${eqData.brand} ${eqData.model}. Hunting manual...`);
      const manual = await huntManual(eqData.brand, eqData.model, claimType, eqData.serial || '', rawNotes);
      
      if (manual && manual.manual_quote) {
        manualContext = `\n\nOEM MANUAL CONTEXT:\nThe manufacturer's manual for the inspected unit (${eqData.brand} ${eqData.model}) states:\n"${manual.manual_quote}"\n\nCRITICAL: You MUST use this exact quote in your Technical Justifications when explaining why this specific equipment needs to be repaired or replaced. Cite it as: "${eqData.brand} Installation Manual, Page ${manual.page_number}".`;
      } else {
        console.log(`[Report Generator] No manual quote found for ${eqData.brand} ${eqData.model}.`);
      }
    }
  } catch (err) {
    console.warn('[Report Generator] Pre-extraction or manual hunting failed (non-fatal):', err);
  }

  const systemInstruction = reportType.toLowerCase().includes('completion') 
    ? COMPLETION_SYSTEM_PROMPT 
    : SYSTEM_PROMPT;

  const generativeModel = await getGenerativeModel({
    systemInstruction,
    responseMimeType: 'application/json',
    temperature: 0.2
  });

  // Build the user prompt with optional photo context
  let userPrompt = `Raw Technician Notes:\n${rawNotes}`;
  
  if (manualContext) {
    userPrompt += manualContext;
  }
  if (inspectionPhotoUrls && inspectionPhotoUrls.length > 0) {
    userPrompt += `\n\nInspection Photo URLs:`;
    inspectionPhotoUrls.forEach((url, i) => {
      userPrompt += `\n  Photo ${i + 1}: ${url}`;
    });
    userPrompt += `\n\nINSTRUCTIONS FOR PHOTOS: Select a MAXIMUM of 3 most relevant photos from the provided URLs that show evidence of technical metrics (e.g. manifold measurement photos), damage, or safety issues. Provide a detailed caption for each describing what technical detail or measurement it shows. Include these in the 'relevantPhotos' array. Do NOT include random or scenic photos.`;
  }

  try {
    console.log('[Report Generator] Sending notes to Gemini for professional rewrite + metric extraction...');
    const result = await generativeModel.generateContent(userPrompt);
    const { getText } = await import('./ai');
    let jsonText = getText(result.response);

    if (!jsonText) {
      throw new Error('Received an empty response from Gemini.');
    }

    // Extract JSON from potential markdown or garbage
    const firstBrace = jsonText.indexOf('{');
    const lastBrace = jsonText.lastIndexOf('}');
    if (firstBrace !== -1 && lastBrace !== -1) {
      jsonText = jsonText.substring(firstBrace, lastBrace + 1);
    }

    let report: ProfessionalReport;
    try {
      report = JSON.parse(jsonText);
    } catch (parseError) {
      console.error('[Report Generator] Failed to parse JSON from Gemini. Raw text was:\n', jsonText);
      // Attempt a secondary cleanup if it looks like it was cut off but mostly valid
      if (jsonText.length > 500 && !jsonText.endsWith('}')) {
        console.warn('[Report Generator] JSON looks truncated, attempting emergency closure...');
        try {
          // This is a last resort - append enough braces/brackets to make it valid-ish
          // Better yet, just fail and let the retry logic (if any) handle it
          throw parseError;
        } catch (e) { throw parseError; }
      }
      throw parseError;
    }

    // Ensure defaults for optional arrays/objects
    if (!report.technicalMetrics) report.technicalMetrics = [];
    if (!report.technicalJustifications) report.technicalJustifications = [];
    if (!report.relevantPhotos) report.relevantPhotos = [];
    if (!report.equipmentId) {
      report.equipmentId = { brand: 'Not specified', model: 'Not specified', serial: 'Not specified', age: 'Not specified', refrigerant: 'Not specified' };
    }
    if (!report.systemStatus) report.systemStatus = 'Salvageable';
    if (!report.causeOfLoss) report.causeOfLoss = 'Not determined';
    if (!report.scopeOfRemediation) report.scopeOfRemediation = 'See recommendations';

    console.log(`[Report Generator] Report generated — Status: ${report.systemStatus}, ${report.technicalMetrics.length} metrics, ${report.technicalJustifications.length} justifications.`);
    return report;

  } catch (error) {
    console.error('[Report Generator] Error generating document:', error);
    throw error;
  }
}

// ============================================
// Synthesis Reporter 3.1: Homeowner Summary
// ============================================

export interface HomeownerSummaryParams {
  systemLogs: string[];
  qboStatus?: string;
  identifiedAnomalies?: string[];
  // Pending user-provided structured details
  inspectionDetails?: any;
}

const HOMEOWNER_SUMMARY_PROMPT = `
You are an expert HVAC Service Manager writing a summary for a HOMEOWNER.
You will be provided with a raw list of technical anomalies, system logs, and estimated repair costs (if any).

YOUR GOAL:
Synthesize this information into a perfectly polished, exactly 3-sentence summary.
The summary must explain the findings simply, provide actionable next steps, and maintain a calm, professional tone.

RULES:
1. Exactly 3 sentences. No more, no less.
2. Sentence 1: The core finding/issue in plain English.
3. Sentence 2: The consequence or what it means for their system.
4. Sentence 3: The recommended next step (or mentioning an attached estimate).
5. DO NOT use confusing jargon (e.g., "µA" or "manifold pressure"). Translate it to "sensor reading" or "gas pressure".
6. If QBO pricing/status is provided, refer to it gracefully.

INPUT FORMAT:
System Logs: [list of actions]
QBO Status: [pricing/estimate info]
Identified Anomalies: [list of severe issues]
Additional Details: [placeholder for structured inspection/report types]

INSPECTION REQUIREMENTS MATRIX:
Use the following matrix to understand the rigor of the testing performed, based on the job type (e.g. Fire, Flood, Abatement).
${FURNACE_INSPECTION_MATRIX_MD}
`;

/**
 * Generates a polished 3-sentence homeowner summary from raw logs and diagnostic anomalies.
 */
export async function generateHomeownerSummary(params: HomeownerSummaryParams): Promise<string> {
  const generativeModel = await getGenerativeModel({
    systemInstruction: HOMEOWNER_SUMMARY_PROMPT,
    temperature: 0.2
  });

  const userPrompt = `
System Logs: ${params.systemLogs.join(' | ') || 'None provided'}
QBO Status: ${params.qboStatus || 'No estimate generated yet'}
Identified Anomalies: ${params.identifiedAnomalies?.join(' | ') || 'No anomalies detected'}
Additional Details: ${params.inspectionDetails ? JSON.stringify(params.inspectionDetails) : 'Pending structured details framework'}
  `.trim();

  try {
    console.log('[Synthesis Reporter] Generating 3-sentence homeowner summary...');
    const result = await generativeModel.generateContent(userPrompt);
    const text = (result.response as any).text();
    if (!text) throw new Error('Received an empty response from Gemini.');

    console.log('[Synthesis Reporter] Successfully generated homeowner summary.');
    return text.trim();
  } catch (error) {
    console.error('[Synthesis Reporter] Error generating homeowner summary:', error);
    throw error;
  }
}

