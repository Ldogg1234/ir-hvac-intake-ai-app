-- Migration: Add missing fields to lead_submissions table
-- Date: 2026-02-13
-- Purpose: Sync database schema with form fields to prevent data loss

-- Add apartment_number column
ALTER TABLE lead_submissions
ADD COLUMN IF NOT EXISTS apartment_number TEXT;

-- Add lockbox_code column
ALTER TABLE lead_submissions
ADD COLUMN IF NOT EXISTS lockbox_code TEXT;

-- Add gate_code column
ALTER TABLE lead_submissions
ADD COLUMN IF NOT EXISTS gate_code TEXT;

-- Note: scope_details already exists in the schema (line 310 of alloydb.ts)

-- Verify the changes
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'lead_submissions'
AND column_name IN ('apartment_number', 'lockbox_code', 'gate_code', 'scope_details')
ORDER BY column_name;
