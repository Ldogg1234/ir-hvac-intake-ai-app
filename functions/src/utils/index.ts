/**
 * Utility Functions
 */

/**
 * Safely parse a date string or return null
 */
export function parseDate(dateStr: string | null | undefined): Date | null {
  if (!dateStr) return null;
  const date = new Date(dateStr);
  return isNaN(date.getTime()) ? null : date;
}

/**
 * Parse a local date-time string (like from <input type="datetime-local">)
 * and assume it's in the America/Toronto timezone if no offset is provided.
 */
export function parseLocalDateTime(dateStr: string | null | undefined): Date | null {
  if (!dateStr) return null;
  
  // If the string already has an offset (Z, +HH:MM, -HH:MM), use standard Date constructor
  if (dateStr.includes('Z') || /[-+]\d{2}:?\d{2}$/.test(dateStr)) {
    const date = new Date(dateStr);
    return isNaN(date.getTime()) ? null : date;
  }

  // Otherwise, it's a local string from the form. 
  // We need to determine if Ontario is in EDT (-04:00) or EST (-05:00).
  try {
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Toronto',
      timeZoneName: 'shortOffset'
    });
    const parts = formatter.formatToParts(new Date(dateStr));
    const offsetPart = parts.find(p => p.type === 'timeZoneName');
    const offset = offsetPart ? offsetPart.value.replace('GMT', '') : '-04:00'; // Fallback to EDT
    
    // Offset might be like "-5" or "+4:30" or blank if UTC
    let validOffset = offset || '-04:00';
    if (!validOffset.includes(':')) {
       // Convert -5 to -05:00
       const sign = validOffset.startsWith('+') ? '+' : '-';
       const val = validOffset.replace(/[+-]/, '').padStart(2, '0');
       validOffset = `${sign}${val}:00`;
    }

    const date = new Date(`${dateStr}${validOffset}`);
    return isNaN(date.getTime()) ? null : date;
  } catch (e) {
    const date = new Date(dateStr);
    return isNaN(date.getTime()) ? null : date;
  }
}

/**
 * Resolve relative date strings (e.g., "next Tuesday", "tomorrow") to a Date object.
 * Returns null if not a relative date or if it cannot be parsed.
 */
export function resolveRelativeDate(relativeStr: string, baseDate: Date = new Date()): Date | null {
  const str = relativeStr.toLowerCase().trim();
  
  // Handle "tomorrow"
  if (str === 'tomorrow') {
    const d = new Date(baseDate);
    d.setDate(d.getDate() + 1);
    d.setHours(8, 0, 0, 0);
    return d;
  }

  // Handle "next [weekday]" or "[weekday] next week"
  const weekdays = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
  const dayMatch = str.match(/(next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)/);
  
  if (dayMatch) {
    const targetDayName = dayMatch[2];
    const targetDay = weekdays.indexOf(targetDayName);
    const currentDay = baseDate.getDay();
    
    let daysToAdd = (targetDay + 7 - currentDay) % 7;
    
    // If it's today and they say "next Tuesday", they probably mean next week
    // Or if they explicitly said "next"
    if (daysToAdd === 0 || str.includes('next')) {
      daysToAdd += 7;
    }
    
    const d = new Date(baseDate);
    d.setDate(d.getDate() + daysToAdd);
    d.setHours(8, 0, 0, 0);
    return d;
  }

  return null;
}

/**
 * Format a date for display
 */
export function formatDate(date: Date, options?: Intl.DateTimeFormatOptions): string {
  const defaultOptions: Intl.DateTimeFormatOptions = {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'America/Toronto',
  };
  return date.toLocaleDateString('en-CA', options || defaultOptions);
}

/**
 * Sanitize a string for use in filenames or folder names
 */
export function sanitizeForFilename(input: string): string {
  return input
    .replace(/[<>:"/\\|?*]/g, '-')
    .replace(/\s+/g, ' ')
    .trim()
    .substring(0, 200); // Limit length
}

/**
 * Check if a value is a non-empty string
 */
export function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

/**
 * Sleep for a specified number of milliseconds
 */
export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Retry a function with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxRetries: number = 3,
  baseDelayMs: number = 1000
): Promise<T> {
  let lastError: Error | undefined;
  
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      console.warn(`Attempt ${attempt + 1} failed:`, lastError.message);
      
      if (attempt < maxRetries - 1) {
        const delay = baseDelayMs * Math.pow(2, attempt);
        await sleep(delay);
      }
    }
  }
  
  throw lastError || new Error('All retries failed');
}

/**
 * Truncate a string to a maximum length with ellipsis
 */
export function truncate(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  return str.substring(0, maxLength - 3) + '...';
}

/**
 * Deep clone an object (JSON-safe)
 */
export function deepClone<T>(obj: T): T {
  return JSON.parse(JSON.stringify(obj));
}

/**
 * Generate a unique reference ID for logs
 */
export function generateRefId(): string {
  const timestamp = Date.now().toString(36);
  const random = Math.random().toString(36).substring(2, 8);
  return `${timestamp}-${random}`;
}

/**
 * Strip undefined properties from an object (modifies in place or returns new)
 */
export function stripUndefined(obj: any): any {
  if (obj === null || typeof obj !== 'object') return obj;
  
  Object.keys(obj).forEach(key => {
    if (obj[key] === undefined) {
      delete obj[key];
    } else if (typeof obj[key] === 'object' && obj[key] !== null) {
      stripUndefined(obj[key]);
    }
  });
  return obj;
}

/**
 * Replace undefined properties with null for Firestore compatibility.
 * Skips recursion on Firestore FieldValue objects to prevent corruption.
 */
export function replaceUndefinedWithNull(obj: any): any {
  if (obj === null || typeof obj !== 'object') return obj;
  
  // Skip recursion for Firestore FieldValue objects (delete, serverTimestamp, etc.)
  if (obj.constructor && (obj.constructor.name === 'FieldValue' || obj.constructor.name === 'f')) {
    return obj;
  }
  
  Object.keys(obj).forEach(key => {
    if (obj[key] === undefined) {
      obj[key] = null;
    } else if (typeof obj[key] === 'object' && obj[key] !== null) {
      // Check if the nested object is a FieldValue before recursing
      const nested = obj[key];
      if (nested.constructor && (nested.constructor.name === 'FieldValue' || nested.constructor.name === 'f')) {
        // Keep as is
      } else {
        replaceUndefinedWithNull(nested);
      }
    }
  });
  return obj;
}

/**
 * Standardize address for matching
 */
export function normalizeAddress(address: string | undefined): string {
  if (!address) return '';
  return address
    .toLowerCase()
    .replace(/,?\s*canada\b/gi, '')
    .replace(/\bca\b$/gi, '') // Remove trailing CA (Canada)
    .replace(/[a-z]\d[a-z]\s*\d[a-z]\d/gi, '') // Postal code
    .replace(/\b(street|st\.?)\b/gi, 'st')
    .replace(/\b(avenue|ave\.?)\b/gi, 'ave')
    .replace(/\b(road|rd\.?)\b/gi, 'rd')
    .replace(/\b(drive|dr\.?)\b/gi, 'dr')
    .replace(/\b(lane|ln\.?)\b/gi, 'ln')
    .replace(/\b(crescent|cres\.?)\b/gi, 'cres')
    .replace(/\b(place|pl\.?)\b/gi, 'pl')
    .replace(/\b(square|sq\.?)\b/gi, 'sq')
    .replace(/\b(way|circle|cir\.?|court|ct\.?|boulevard|blvd\.?)\b/gi, '')
    .replace(/\b(saint|st)\b/gi, 'st')
    .replace(/\b(north|n\.?)\b/gi, 'n')
    .replace(/\b(south|s\.?)\b/gi, 's')
    .replace(/\b(east|e\.?)\b/gi, 'e')
    .replace(/\b(west|w\.?)\b/gi, 'w')
    .replace(/\bunit\s+/gi, '#') // Normalize Unit 101 to #101
    .replace(/\bsuite\s+/gi, '#') // Normalize Suite 101 to #101
    .replace(/\bapt\.?\s+/gi, '#') // Normalize Apt 101 to #101
    .replace(/\b#\s+/gi, '#') // Remove space after #

    .replace(/[.,/#!$%^&*;:{}=\-_`~()]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Job Category Classification Helpers
 */
export const isReAndRe = (categories: string[]) => {
  if (!categories || categories.length === 0) return false;
  return categories.some(c => {
    const low = c.toLowerCase();
    return low.includes('re and re') || 
           low.includes('replacement') || 
           low.includes('repair') || 
           low.includes('repairs and replacement') ||
           low.includes('r&r');
  });
};
export const isInspection = (categories: string[]) => categories?.some(c => c.toLowerCase().includes('inspection'));
export const isTroubleshooting = (categories: string[]) => categories?.some(c => c.toLowerCase().includes('trouble'));
export const isDuctCleaning = (categories: string[]) => categories?.some(c => c.toLowerCase().includes('duct') && (c.toLowerCase().includes('cleaning') || c.toLowerCase().includes('dc')));

export { logError } from './logger';
