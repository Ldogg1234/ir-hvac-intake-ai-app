/**
 * Professional Report Generator Service
 * Uses Vertex AI (Gemini) to rewrite messy technician notes into
 * a structured, professional HVAC report suitable for a branded PDF.
 */

import { VertexAI, Schema, SchemaType } from '@google-cloud/vertexai';
import { config } from '../config';

// ============================================
// Types
// ============================================

export interface ProfessionalReport {
  executiveSummary: string;
  systemFindings: string;
  recommendations: string[];
  safetyNotes: string;
}

// ============================================
// AI Prompt & Schema
// ============================================

const SYSTEM_PROMPT = `
You are an expert HVAC Sales & Service Assistant specializing in the Canadian market, acting as a professional Technical Writer.
Your goal is to provide technically accurate diagnostics, TSSA-compliant safety reporting, and high-value sales recommendations.

1. Terminology: Use precise industry terms (e.g., 'Inducer motor amperage draw', 'Static pressure across the coil', 'Flame rectification signal in microamps').
2. Sales Logic: Recommend 4 units in priority order: Trane, Goodman, Keeprite, Carrier (with their specific value props if replacement is needed).
3. Structural Hierarchy:
   - System Identification: Note Brand, Model, Serial, Age, and Refrigerant (highlight R-454B or R-32).
   - Diagnostic Findings: Explain the root cause using logic from 'hvac_troubleshooting_master.csv'.
   - Safety & Compliance: Explicitly mention TSSA-specific checks (e.g., gas-tight seal on manifold, clearance to combustibles, CO levels).
   - Homeowner Summary: Translate technical data into an impact-focused 'Executive Summary' (e.g., efficiency loss, lifespan shortening).

Tone: Authoritative, transparent, and focused on safety and long-term reliability.
Efficiency: Recommendations must be 96%+ AFUE as required for the Canadian market.
Structure: Output JSON matching the provided schema.
`;

const reportSchema: Schema = {
  type: SchemaType.OBJECT,
  properties: {
    executiveSummary: {
      type: SchemaType.STRING,
      description: 'A 2-3 sentence overview of the visit and primary outcome.',
    },
    systemFindings: {
      type: SchemaType.STRING,
      description: 'Detailed, professional paragraph describing the condition of the HVAC equipment and the work performed.',
    },
    recommendations: {
      type: SchemaType.ARRAY,
      items: { type: SchemaType.STRING },
      description: 'List of actionable recommendations for the client.',
    },
    safetyNotes: {
      type: SchemaType.STRING,
      description: 'Critical safety information or "No immediate safety concerns noted at the time of inspection."',
    },
  },
  required: ['executiveSummary', 'systemFindings', 'recommendations', 'safetyNotes'],
};

// ============================================
// Public API
// ============================================

/** Shared Vertex AI client instance */
let vertexAIClient: VertexAI | null = null;

function getVertexAI(): VertexAI {
  if (!vertexAIClient) {
    // Project ID is pulled from Firebase config; location defaults to us-central1
    const projectId = config.gcp.projectId || process.env.GCP_PROJECT_ID;

    if (!projectId) {
      console.warn('[Report Generator] GCP_PROJECT_ID not found, AI generation may fail if not authorized via other means.');
    }

    vertexAIClient = new VertexAI({
      project: projectId || '',
      location: 'us-central1'
    });
  }
  return vertexAIClient;
}

/**
 * Takes raw technician notes and generates a structured, professional report using Gemini.
 * 
 * @param rawNotes - The raw notes provided by the HVAC technician.
 * @returns A structured ProfessionalReport object.
 */
export async function generateProfessionalReport(rawNotes: string): Promise<ProfessionalReport> {
  if (!rawNotes || rawNotes.trim() === '') {
    throw new Error('Raw notes are required to generate a report.');
  }

  const vertexai = getVertexAI();
  const generativeModel = vertexai.getGenerativeModel({
    model: 'gemini-1.5-flash',
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: reportSchema,
      temperature: 0.2, // Low temperature for more deterministic, professional output
    },
    systemInstruction: {
      role: 'system',
      parts: [{ text: SYSTEM_PROMPT }]
    }
  });

  const request = {
    contents: [
      {
        role: 'user',
        parts: [{ text: `Raw Technician Notes:\n${rawNotes}` }]
      }
    ]
  };

  try {
    console.log('[Report Generator] Sending notes to Gemini for professional rewrite...');
    const result = await generativeModel.generateContent(request);

    if (!result.response || !result.response.candidates || result.response.candidates.length === 0) {
      throw new Error('No candidate response received from Gemini.');
    }

    const jsonText = result.response.candidates[0].content.parts[0].text;

    if (!jsonText) {
      throw new Error('Received an empty response from Gemini.');
    }

    const report: ProfessionalReport = JSON.parse(jsonText);

    console.log('[Report Generator] Successfully generated professional report.');
    return report;

  } catch (error) {
    console.error('[Report Generator] Error generating document:', error);
    throw error;
  }
}
