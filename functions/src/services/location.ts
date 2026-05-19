/**
 * Location Service
 * Geocoding, proximity verification, and clock-in URL generation
 * for technician on-site check-in.
 *
 * Uses the Google Maps Geocoding API (server-side, API-key auth).
 */

import { config } from '../config';

// ============================================
// Types
// ============================================

export interface LatLng {
  lat: number;
  lng: number;
}

export interface ProximityResult {
  withinRange: boolean;
  distanceMetres: number;
  targetCoords: LatLng;
}

// ============================================
// Geocoding
// ============================================

export const WHITBY_HQ_COORDS: LatLng = { lat: 43.8860, lng: -78.9181 };


const GEOCODING_BASE = 'https://maps.googleapis.com/maps/api/geocode/json';

/**
 * Geocode an address string to lat/lng via the Google Maps Geocoding API.
 *
 * @param address - Human-readable address (e.g. "123 Main St, Calgary, AB")
 * @returns Coordinates of the first geocoding result
 * @throws If the API returns no results or an error status
 */
export async function geocodeAddress(address: string): Promise<{ lat: number, lng: number, formattedAddress: string }> {
  const apiKey = config.googleMaps.apiKey;
  if (!apiKey) {
    throw new Error('GOOGLE_MAPS_API_KEY is not configured');
  }

  const url = `${GEOCODING_BASE}?address=${encodeURIComponent(address)}&key=${apiKey}`;
  const response = await fetch(url);
  const data = (await response.json()) as {
    status: string;
    results: { formatted_address: string; geometry: { location: { lat: number; lng: number } } }[];
  };

  if (data.status !== 'OK' || !data.results.length) {
    throw new Error(`Geocoding failed for "${address}": ${data.status}`);
  }

  const loc = data.results[0].geometry.location;
  const formattedAddress = data.results[0].formatted_address;
  console.log(`[Location] Geocoded "${address}" → ${formattedAddress} (${loc.lat}, ${loc.lng})`);
  return { lat: loc.lat, lng: loc.lng, formattedAddress };
}

/**
 * Fetch address autocomplete suggestions via the Google Places Autocomplete API.
 *
 * @param query - The user's input string
 * @returns Array of prediction objects
 */
export async function fetchAutocompleteSuggestions(query: string): Promise<any[]> {
  const apiKey = config.googleMaps.apiKey;
  if (!apiKey) {
    throw new Error('GOOGLE_MAPS_API_KEY is not configured');
  }

  const url = `https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${encodeURIComponent(query)}&components=country:ca|country:us&key=${apiKey}`;
  const response = await fetch(url);
  const data = await response.json();

  if (data.status !== 'OK' && data.status !== 'ZERO_RESULTS') {
    console.warn(`[Location] Autocomplete failed for "${query}": ${data.status}`, data.error_message || '');
  }

  return data.predictions || [];
}

// ============================================
// Haversine distance
// ============================================

const EARTH_RADIUS_METRES = 6_371_000;

function toRadians(deg: number): number {
  return (deg * Math.PI) / 180;
}

/**
 * Calculate the great-circle distance between two points using the
 * Haversine formula.
 *
 * @returns Distance in metres
 */
export function haversineDistance(a: LatLng, b: LatLng): number {
  const dLat = toRadians(b.lat - a.lat);
  const dLng = toRadians(b.lng - a.lng);
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);

  const h =
    sinLat * sinLat +
    Math.cos(toRadians(a.lat)) * Math.cos(toRadians(b.lat)) * sinLng * sinLng;

  return 2 * EARTH_RADIUS_METRES * Math.asin(Math.sqrt(h));
}

// ============================================
// Proximity verification
// ============================================

/**
 * Verify that a technician's GPS position is within 200 m of the
 * geocoded target address.
 *
 * @param techLat  - Technician's current latitude
 * @param techLng  - Technician's current longitude
 * @param targetAddress - Property address to geocode and compare against
 * @returns true if the tech is within the configured proximity threshold
 */
export async function verifySiteProximity(
  techLat: number,
  techLng: number,
  targetAddress: string
): Promise<boolean> {
  const targetCoords = await geocodeAddress(targetAddress);
  const distance = haversineDistance(
    { lat: techLat, lng: techLng },
    targetCoords
  );

  const threshold = config.googleMaps.proximityThresholdMetres;
  const withinRange = distance <= threshold;

  console.log(
    `[Location] Tech (${techLat}, ${techLng}) is ${Math.round(distance)}m ` +
    `from target — ${withinRange ? 'WITHIN' : 'OUTSIDE'} ${threshold}m threshold`
  );

  return withinRange;
}

// ============================================
// Clock-In URL generation
// ============================================

/**
 * Generate the clock-in verification URL for a given property address.
 * Techs open this link on their phone; the page reads their GPS and
 * calls verifySiteProximity on the backend.
 *
 * @param propertyAddress - Full property address for the lead
 * @returns Fully-qualified clock-in URL
 */
export function generateClockInUrl(propertyAddress: string): string {
  const base = config.googleMaps.clockInBaseUrl;
  const encoded = encodeURIComponent(propertyAddress);
  return `${base}/clock-in?address=${encoded}`;
}

// ============================================
// Travel Compliance
// ============================================

/**
 * Check if the target address is more than 80km from the Whitby HQ.
 */
export async function checkTravelCompliance(propertyAddress: string): Promise<{ isSpecialWorkSite: boolean; distanceMetres: number }> {
  try {
    const targetCoords = await geocodeAddress(propertyAddress);
    const distanceMetres = haversineDistance(WHITBY_HQ_COORDS, targetCoords);
    const isSpecialWorkSite = distanceMetres > 80000;
    
    console.log(
      `[Location] Travel Compliance for "${propertyAddress}": ` +
      `${(distanceMetres / 1000).toFixed(2)} km from HQ. Special Site: ${isSpecialWorkSite}`
    );
    
    return { isSpecialWorkSite, distanceMetres };
  } catch (error) {
    console.error(`[Location] Failed to check travel compliance for ${propertyAddress}:`, error);
    // Fail closed: if we can't geocode, don't trigger the special work site workflow
    return { isSpecialWorkSite: false, distanceMetres: 0 };
  }
}
