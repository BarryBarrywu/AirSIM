package com.airsim.phonecontrol;

/**
 * Decides when the embedded Agent must re-post its registration because the Relay
 * no longer knows this device (HTTP 401). The Agent only re-registers when its
 * registration content changes, so a device record deleted on the Relay would
 * otherwise stay unauthorized until the process restarts.
 *
 * Only 401 counts; 429, 5xx and network errors keep their existing retry paths.
 * Re-registration backs off (1, 2, 4 … minutes, capped at one hour) so a Relay
 * that deliberately rejects this device is not hammered, and resets once a
 * heartbeat authenticates again. A 401 inside the back-off window is dropped,
 * not queued: unauthorized calls keep recurring while the device is unknown.
 */
final class RelayRegistrationRecovery {
    static final long INITIAL_DELAY_MILLIS = 60_000L;
    static final long MAX_DELAY_MILLIS = 3_600_000L;

    private boolean pending;
    private long nextAllowedAt;
    private long delay = INITIAL_DELAY_MILLIS;
    private int resyncs;

    synchronized void onFailure(Throwable error, long nowMillis) {
        if (!(error instanceof RelayHTTPException http) || http.statusCode() != 401) return;
        if (nowMillis >= nextAllowedAt) pending = true;
    }

    synchronized boolean takeResync(long nowMillis) {
        if (!pending) return false;
        pending = false;
        nextAllowedAt = nowMillis + delay;
        delay = Math.min(delay * 2, MAX_DELAY_MILLIS);
        resyncs++;
        return true;
    }

    synchronized void onAuthenticated() {
        delay = INITIAL_DELAY_MILLIS;
        nextAllowedAt = 0;
    }

    synchronized String describe(long nowMillis) {
        return "pending=" + pending + " resyncs=" + resyncs + " delay_ms=" + delay
                + " next_allowed_in_ms=" + Math.max(0, nextAllowedAt - nowMillis);
    }
}
