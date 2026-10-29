package com.airsim.phonecontrol;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.DoubleSupplier;

/**
 * Uploads queued incoming SMS to the Relay so that no message can hold back the ones behind it,
 * and a Relay outage of any length loses none of them. Only a 400 (the Relay refuses the message
 * itself) settles a message unsent. Any other failure ends the flush and pauses the whole queue
 * with the shared Relay cooldown (Retry-After, jitter, reset by the next success); the failed
 * message also backs off on its own (5 s, doubling, at most 5 min) and messages that never failed
 * go first, so one bad message cannot starve the rest.
 */
final class CloudSMSUploader {
    static final long FIRST_RETRY_MILLIS = 5_000L;
    static final long MAX_RETRY_MILLIS = 300_000L;
    /** Keeps one agent cycle short enough for its heartbeat when a backlog drains. */
    static final int MAX_SENDS_PER_FLUSH = 10;

    interface Sender { void send(String deliveryID) throws Exception; }
    /** Called for a delivered and for a dropped message alike: both leave the cloud queue. */
    interface Ledger { void settled(String deliveryID) throws Exception; }
    interface Listener { void failed(Throwable error, Verdict verdict, int attempt, long pauseMillis); }
    /** RETRY: the Relay answered; STOP: no answer; DROP: refused for good. */
    enum Verdict { RETRY, DROP, STOP }

    private static final class Retry {
        long dueAt;
        int attempts;
    }

    private final Map<String, Retry> retries = new HashMap<>();
    private final RelayCommandRetryState pause = new RelayCommandRetryState();
    private final DoubleSupplier jitter;

    CloudSMSUploader() { this(() -> ThreadLocalRandom.current().nextDouble()); }

    CloudSMSUploader(DoubleSupplier jitter) { this.jitter = jitter; }

    /** Sends due messages, fewest failures first. Only Sender failures are handled here. */
    synchronized void flush(List<String> pending, Sender sender, Ledger ledger, Listener listener, long nowMillis)
            throws Exception {
        retries.keySet().retainAll(new HashSet<>(pending));
        if (pause.remainingMillis(nowMillis) > 0) return;
        List<String> order = new ArrayList<>(pending);
        order.sort(Comparator.comparingInt(this::attempts));
        int sends = 0;
        for (String id : order) {
            Retry retry = retries.get(id);
            if (retry != null && nowMillis < retry.dueAt) continue;
            if (sends++ == MAX_SENDS_PER_FLUSH) return;
            try {
                sender.send(id);
            } catch (Exception error) {
                if (rejected(error)) {
                    retries.remove(id);
                    listener.failed(error, Verdict.DROP, attempts(retry) + 1, 0);
                    ledger.settled(id);
                    continue;
                }
                if (retry == null) retries.put(id, retry = new Retry());
                retry.attempts++;
                retry.dueAt = nowMillis + Math.min(MAX_RETRY_MILLIS, FIRST_RETRY_MILLIS << Math.min(retry.attempts - 1, 6));
                long pauseMillis = pause.failed(nowMillis, 0, error, jitter.getAsDouble()).delayMillis();
                listener.failed(error, error instanceof RelayHTTPException ? Verdict.RETRY : Verdict.STOP,
                        retry.attempts, pauseMillis);
                return;
            }
            retries.remove(id);
            pause.reset();
            ledger.settled(id);
        }
    }

    private int attempts(String id) { return attempts(retries.get(id)); }

    private static int attempts(Retry retry) { return retry == null ? 0 : retry.attempts; }

    /** The Relay refused this SMS itself; every other status, Cloudflare's included, can clear up. */
    static boolean rejected(Throwable error) {
        return error instanceof RelayHTTPException http && http.statusCode() == 400;
    }

    /** The Relay answers 400 to times over 5 min ahead; a carrier clock running fast must not cost the SMS. */
    static String uploadTimestamp(String stored, long nowMillis) {
        try {
            return Instant.parse(stored).toEpochMilli() > nowMillis ? Instant.ofEpochMilli(nowMillis).toString() : stored;
        } catch (RuntimeException unreadable) {
            return Instant.ofEpochMilli(nowMillis).toString();
        }
    }
}
