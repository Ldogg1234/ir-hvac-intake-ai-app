import { sendEmail } from '../services/email';
import { getFirestore } from 'firebase-admin/firestore';

export async function handleEmailTylerTranscript(data: any, email: string) {
  let { htmlTranscript, leadId } = data;
  
  if (!htmlTranscript) {
    throw new Error('htmlTranscript is required');
  }

  // If we have a leadId, try to fetch the most recent scan that contains schematic JSON
  if (leadId) {
    const db = getFirestore();
    try {
      const scansRef = db.collection('leads').doc(leadId).collection('scans');
      const latestScanSnapshot = await scansRef
        .orderBy('timestamp', 'desc')
        .limit(1)
        .get();

      if (!latestScanSnapshot.empty) {
        const scanData = latestScanSnapshot.docs[0].data();
        if (scanData.schematic_json) {
          const schematic = scanData.schematic_json;
          
          let schematicHtml = '<div style="background-color: #f8f9fa; padding: 15px; border-radius: 8px; margin-bottom: 20px;">';
          schematicHtml += '<h3 style="color: #333; margin-top: 0;">LiDAR Scan & Measurements</h3>';
          
          if (schematic.dimensions) {
            schematicHtml += '<h4>Dimensions</h4><ul>';
            schematicHtml += `<li>Width: ${schematic.dimensions.width || 'N/A'}</li>`;
            schematicHtml += `<li>Length: ${schematic.dimensions.length || 'N/A'}</li>`;
            schematicHtml += `<li>Height: ${schematic.dimensions.height || 'N/A'}</li>`;
            schematicHtml += '</ul>';
            
            // Add a visual drawing (SVG) to satisfy the "drawing of the room" requirement
            const w = parseFloat(schematic.dimensions.width) || 10;
            const l = parseFloat(schematic.dimensions.length) || 10;
            const scale = 20; // scale factor for drawing
            const svgWidth = Math.max(w * scale, 200);
            const svgHeight = Math.max(l * scale, 200);
            
            schematicHtml += '<h4>Room Schematic (Top-Down View)</h4>';
            schematicHtml += `<svg width="${svgWidth + 40}" height="${svgHeight + 40}" xmlns="http://www.w3.org/2000/svg" style="background: #fff; border: 1px solid #ccc; display: block; margin: 10px 0;">`;
            // Draw room outline
            schematicHtml += `<rect x="20" y="20" width="${svgWidth}" height="${svgHeight}" fill="none" stroke="#333" stroke-width="2" />`;
            // Add dimension labels
            schematicHtml += `<text x="${svgWidth / 2 + 20}" y="15" font-family="Arial" font-size="12" text-anchor="middle">Width: ${w}</text>`;
            schematicHtml += `<text x="5" y="${svgHeight / 2 + 20}" font-family="Arial" font-size="12" text-anchor="middle" transform="rotate(-90 5,${svgHeight / 2 + 20})">Length: ${l}</text>`;
            
            // Draw dummy appliances if they exist to make the schematic useful
            if (schematic.appliances && Array.isArray(schematic.appliances)) {
              let appY = 20 + 10;
              schematic.appliances.forEach((app: any, idx: number) => {
                const appName = app.type || 'Appliance';
                schematicHtml += `<rect x="30" y="${appY}" width="80" height="40" fill="#0066cc" opacity="0.6" stroke="#004488" />`;
                schematicHtml += `<text x="70" y="${appY + 25}" font-family="Arial" font-size="10" fill="#fff" text-anchor="middle">${appName.substring(0, 10)}</text>`;
                appY += 50;
              });
            }
            schematicHtml += `</svg>`;
          }
          
          if (schematic.appliances && Array.isArray(schematic.appliances) && schematic.appliances.length > 0) {
            schematicHtml += '<h4>Appliances</h4><ul>';
            schematic.appliances.forEach((app: any) => {
              schematicHtml += `<li>Type: ${app.type || 'Unknown'}, Clearance: ${app.clearance || 'Unknown'}</li>`;
            });
            schematicHtml += '</ul>';
          }

          if (schematic.equipment_details && Array.isArray(schematic.equipment_details) && schematic.equipment_details.length > 0) {
            schematicHtml += '<h4>Equipment Details</h4><ul>';
            schematic.equipment_details.forEach((eq: any) => {
              schematicHtml += `<li>Type: ${eq.type || 'Unknown'}, Make: ${eq.make || 'N/A'}, Model: ${eq.model || 'N/A'}, S/N: ${eq.serial_number || 'N/A'}</li>`;
            });
            schematicHtml += '</ul>';
          }

          if (schematic.measurement_logs && Array.isArray(schematic.measurement_logs) && schematic.measurement_logs.length > 0) {
            schematicHtml += '<h4>Measurement Logs</h4><ul>';
            schematic.measurement_logs.forEach((log: any) => {
              schematicHtml += `<li>${log.parameter || 'Unknown'}: ${log.value || 'N/A'}</li>`;
            });
            schematicHtml += '</ul>';
          }

          if (schematic.violations_detailed && Array.isArray(schematic.violations_detailed) && schematic.violations_detailed.length > 0) {
            schematicHtml += '<h4>Code Violations</h4><ul>';
            schematic.violations_detailed.forEach((v: any) => {
              schematicHtml += `<li><strong>${v.authority || 'Code'} (${v.hazard_level || 'Unknown'}):</strong> ${v.description || 'N/A'} (Ref: ${v.code_reference || 'N/A'})</li>`;
            });
            schematicHtml += '</ul>';
          }

          schematicHtml += '</div>';
          
          // Prepend the schematic data to the transcript so it appears at the top
          htmlTranscript = schematicHtml + htmlTranscript;
        }
      }
    } catch (e) {
      console.error('Error fetching schematic data for email:', e);
    }
  }

  const attachments: { filename: string, content: Buffer, contentType: string }[] = [];
  
  // Prioritize importantPhotos requested by the AI/Technician.
  // Fallback to recentFrames only if no important photos were captured.
  let photosToProcess = data.importantPhotos;
  let photoPrefix = 'important_evidence';
  
  if (!photosToProcess || !Array.isArray(photosToProcess) || photosToProcess.length === 0) {
    photosToProcess = data.recentFrames;
    photoPrefix = 'recent_frame';
  }

  if (Array.isArray(photosToProcess)) {
    photosToProcess.forEach((base64String, index) => {
      try {
        const buffer = Buffer.from(base64String, 'base64');
        attachments.push({
          filename: `${photoPrefix}_${index + 1}.jpg`,
          content: buffer,
          contentType: 'image/jpeg'
        });
      } catch (e) {
        console.error(`Failed to parse ${photoPrefix} attachment:`, e);
      }
    });
  }

  const subject = `Diagnostic Chat Transcript with Tyler (Gemini Live)`;
  
  const body = `
  <div style="font-family: Arial, sans-serif; max-width: 600px; line-height: 1.6;">
    <h2 style="color: #0066cc;">Tyler Diagnostic Session Transcript</h2>
    <p>Attached are the recent captures from your camera (if available).</p>
    <hr style="border: 1px solid #eee; margin: 20px 0;" />
    ${htmlTranscript}
    <hr style="border: 1px solid #eee; margin: 20px 0;" />
    <p style="font-size: 12px; color: #888;">This transcript was automatically generated by Immediate Response HVAC AI.</p>
  </div>
  `;

  await sendEmail({
    to: email, // This is the signed-in user's email
    subject,
    body,
    attachments
  });

  return { success: true };
}
