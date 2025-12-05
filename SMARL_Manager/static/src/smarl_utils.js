/*
    File: static/src/smarl_utils.js
    Global utility functions and constants used across D3 overlays.
*/
console.log("Loading utilities")
const SMARL_SETTINGS = {
    // Standard race properties (Can be updated dynamically later if needed)
    TOTAL_CARS: 16,
    MAX_CARS: 20,
    // Default transitions (Mirroring Flask properties for client-side use)
    TRANSITION_SHORT: 300,
    TRANSITION_LONG: 800,
    TRANSITION_LONGER: 1200,

    // D3/Chart Dimensions (can be moved here from individual templates later)
    CHART_WIDTH: 1920,
    CHART_HEIGHT: 1080,
    SCROLL_WAIT: 5000,
};


// --- REFACTORED: STANDARD TIME PARSING (MM:SS.mmm format) ---
// Helper function to convert MM:SS.mmm or M:SS.mmm time string to total milliseconds
function timeToMs(timeStr) {
    if (!timeStr || timeStr.length < 7) return Number.MAX_SAFE_INTEGER; // Handle missing or malformed data
    
    // Assuming format is "MM:SS.mmm" or "M:SS.mmm"
    // Use regex or split logic for robustness: Find the colon and the period.
    try {
        const [minSec, milli] = timeStr.split('.');
        const [minutes, seconds] = minSec.split(':').map(p => parseInt(p) || 0);

        const milliseconds = parseInt(milli.substring(0, 3)) || 0;
        
        return (minutes * 60 * 1000) + (seconds * 1000) + milliseconds;
    } catch (e) {
        console.error("Error parsing time string:", timeStr, e);
        return Number.MAX_SAFE_INTEGER;
    }
}



// Helper function to format gap/delta time (prefixed with + or -)
function formatGap(gapSeconds) {
    if (gapSeconds === null || isNaN(gapSeconds) || Math.abs(gapSeconds) < 0.001) {
        return (gapSeconds === 0) ? "0.000" : "--.---";
    }
    
    const sign = gapSeconds >= 0 ? "+" : "";
    const absSeconds = Math.abs(gapSeconds);
    
    // Format to 3 decimal places
    return `${sign}${absSeconds.toFixed(3)}`;
}

// --- REFACTORED: STANDARD TIME FORMATTING (MM:SS.mmm format) ---
function formatMsToTime(ms) {
    if (ms === Number.MAX_SAFE_INTEGER || ms < 0) return '--:--.---';
    
    const totalSeconds = Math.floor(ms / 1000);
    const m = Math.floor(totalSeconds / 60);
    const s = totalSeconds % 60;
    const milli = ms % 1000;
    
    // Standard formatting: MM:SS.mmm
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}.${milli.toString().padStart(3, '0')}`;
}


// --- REFACTORED: Uses the centralized timeToMs function ---
function getOverallBestLapTime(data) {
    let bestTimeMs = Number.MAX_SAFE_INTEGER;

    // Ensure data is an iterable array
    if (!Array.isArray(data)) return bestTimeMs; 
    
    for (const d of data) {
        // Assume 'bestLap' property holds the "MM:SS.mmm" string
        const totalMs = timeToMs(d.bestLap);

        if (totalMs < bestTimeMs) {
            bestTimeMs = totalMs;
        }
    }
    return bestTimeMs;
}