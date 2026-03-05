# IMR HVAC Project Blueprint

## 1. Core Logic
- **Project Check:** For every new lead, search QBO for an existing Project matching `[Property Address] - [Client Name]`. If not found, create it.
- **Multi-Estimate:** Allow multiple estimates to be linked to the same Project ID.

## 2. Field Mapping (Web Form to QBO)
- **Description:** Map 'Scope / Job Details' to the Estimate Line Item Description.
- **P.O. Number:** Map 'PO Number' from the form to the QBO P.O. Number field.
- **Job Type:** Map 'Job Categories' (joined by ' | ').
- **Claim Type:** Map 'Claim Type' (joined by ' | ').
- **Project Manager:** Map 'Project Manager Name'.
- **Technician:** Updated via Google Calendar Attendee sync.

## 3. Technical Specs
- **Company ID:** 9130 3494 4104 6016
- **Database:** Firestore (store all IDs and OAuth tokens here).
- **Functions:** 2nd Gen Firebase Functions.
