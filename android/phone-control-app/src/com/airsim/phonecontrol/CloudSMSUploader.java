package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;

/**
 * Uploads queued incoming SMS to the Relay so that no message can hold back the ones behind it.
 * A Relay 4xx other than 401/408/409/429 will never accept the message, so it leaves the cloud
 * queue at once. Anything else is retried per message (5 s, doubling, at most every 5 min) for
 * 24 h: unlike a call event, an SMS is still worth delivering hours later. A failure without an
 * HTTP answer means the Relay is unreachable, so the rest of the queue waits for the next flush.
 */
final class CloudSMSUploader {
    static final long FIRST_RETRY_MILLIS = 5_000L;
    static final long MAX_RETRY_MILLIS = 300_000L;
    static final long GIVE_UP_AFTER_MILLIS = 24L * 60 * 60 * 1000;

    interface Sender { void send(String deliveryID) throws Exception; }
    /** Called for a delivered and for a dropped message alike: both leave the cloud queue. */
    interface Ledger { void settled(String deliveryID) throws Exception; }
    interface Listener { void failed(Throwable error, Verdict verdict, int attempt, long retryInMillis); }
    enum Verdict { RETRY, DROP, STOP }

    private static final class Retry {
        final long firstFailureAt;
        long dueAt;
        int attempts;
        Retry(long firstFailureAt) { this.firstFailureAt = firstFailureAt; }
    }

    private final Map<String, Retry> retries = new HashMap<>();

    /** Tries each due message once, in queue order. Only Sender failures are handled here. */
    synchronized void flush(List<String> pending, Sender sender, Ledger ledger, Listener listener, long nowMillis)
            throws Exception {
        retries.keySet().retainAll(new HashSet<>(pending));
        for (String id : pending) {
            Retry retry = retries.get(id);
            if (retry != null && nowMillis < retry.dueAt) continue;
            try {
                sender.send(id);
            } catch (Exception error) {
                if (retry == null) retries.put(id, retry = new Retry(nowMillis));
                retry.attempts++;
                if (rejected(error) || nowMillis - retry.firstFailureAt >= GIVE_UP_AFTER_MILLIS) {
                    retries.remove(id);
                    listener.failed(error, Verdict.DROP, retry.attempts, 0);
                    ledger.settled(id);
                    continue;
                }
                long delay = Math.min(MAX_RETRY_MILLIS, FIRST_RETRY_MILLIS << Math.min(retry.attempts - 1, 6));
                retry.dueAt = nowMillis + delay;
                boolean unreachable = !(error instanceof RelayHTTPException);
                listener.failed(error, unreachable ? Verdict.STOP : Verdict.RETRY, retry.attempts, delay);
                if (unreachable) return;
                continue;
            }
            retries.remove(id);
            ledger.settled(id);
        }
    }

    /** The Relay answered that it will never accept this SMS. */
    static boolean rejected(Throwable error) {
        if (!(error instanceof RelayHTTPException http)) return false;
        int status = http.statusCode();
        return status >= 400 && status < 500 && status != 401 && status != 408 && status != 409 && status != 429;
    }
}
