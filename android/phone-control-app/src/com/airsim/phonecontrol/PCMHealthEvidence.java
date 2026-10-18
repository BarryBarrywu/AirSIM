package com.airsim.phonecontrol;

/** Whitelisted, non-audio evidence from the privileged helper for local TXT diagnostics. */
final class PCMHealthEvidence {
    private static final java.util.regex.Pattern FIELD = java.util.regex.Pattern.compile(
        "\"(event|error_phase|error_code|error_class|downlink_bytes|downlink_peak|uplink_bytes|uplink_peak)\"\\s*:\\s*(?:\"([A-Za-z0-9_.$]{1,64})\"|(\\d{1,18}))");
    private static final java.util.Set<String> EVENTS = java.util.Set.of("bridge_listening", "audio_initializing", "audio_initialized",
        "client_ready", "pcm_stats", "voice_tx_route_verified", "voice_tx_route_unverified",
        "session_error", "uplink_error", "downlink_error", "client_closed");
    private String event = "waiting";
    private boolean initialized, routeVerified;
    private long downBytes, downPeak, upBytes, upPeak;
    private String failureEvent = "none", failurePhase = "unknown", failureCode = "unknown", failureClass = "unknown";
    private int failures;

    synchronized void reset() {
        event = "waiting"; clearAudio(); clearFailure();
    }
    private void clearAudio() {
        initialized = false; routeVerified = false;
        downBytes = 0; downPeak = 0; upBytes = 0; upPeak = 0;
    }
    private void clearFailure() {
        failureEvent = "none"; failurePhase = "unknown"; failureCode = "unknown"; failureClass = "unknown";
        failures = 0;
    }
    synchronized void observe(String line) {
        if (line == null || line.length() > 4096 || !line.startsWith("{")) return;
        java.util.Map<String,String> fields = new java.util.HashMap<>();
        var matcher = FIELD.matcher(line);
        while (matcher.find()) fields.put(matcher.group(1), matcher.group(2) != null ? matcher.group(2) : matcher.group(3));
        String next = fields.get("event");
        if (!EVENTS.contains(next == null ? "" : next)) return;
        if (next.equals("bridge_listening")) reset();
        if (next.equals("audio_initializing") || next.equals("audio_initialized")) clearAudio();
        event = next;
        if (next.equals("client_ready")) { initialized = true; clearFailure(); }
        if (next.equals("voice_tx_route_verified")) routeVerified = true;
        if (next.equals("voice_tx_route_unverified")) routeVerified = false;
        if (next.endsWith("_error")) {
            initialized = false;
            failureEvent = next;
            failurePhase = label(fields.get("error_phase"));
            failureCode = label(fields.get("error_code"));
            String type = fields.getOrDefault("error_class", "");
            failureClass = type.matches("[A-Za-z_$][A-Za-z_.$]{0,48}(Exception|Error)") ? type : "unknown";
            failures = Math.min(1000, failures + 1);
        }
        if (next.equals("client_closed")) initialized = false;
        downBytes = number(fields, "downlink_bytes", downBytes);
        downPeak = number(fields, "downlink_peak", downPeak);
        upBytes = number(fields, "uplink_bytes", upBytes);
        upPeak = number(fields, "uplink_peak", upPeak);
    }
    private static String label(String value) {
        return value != null && value.matches("[a-z][a-z_]{0,39}") ? value : "unknown";
    }
    private static long number(java.util.Map<String,String> fields, String name, long fallback) {
        try { return Long.parseLong(fields.get(name)); }
        catch (NumberFormatException ignored) { return fallback; }
    }
    synchronized String snapshot() {
        // Peaks are cumulative PCM16 magnitudes. 0/1 is silence/quantization noise,
        // not evidence of audible speech. A larger peak still does not prove playback.
        String capture = downBytes == 0 ? "not_observed" : downPeak == 0 ? "all_zero"
            : downPeak == 1 ? "near_zero" : "observed";
        return "pcm_event=" + event + " pcm_initialized=" + initialized + " pcm_capture=" + capture
            + " pcm_route=" + (routeVerified ? "verified" : "unverified")
            + " pcm_down_bytes=" + downBytes + " pcm_down_peak=" + downPeak
            + " pcm_up_bytes=" + upBytes + " pcm_up_peak=" + upPeak
            + " pcm_failure=" + failureEvent + " pcm_error_phase=" + failurePhase
            + " pcm_error_code=" + failureCode + " pcm_error_class=" + failureClass
            + " pcm_failure_count=" + failures;
    }
}
