package com.airsim.phonecontrol;

import java.net.SocketTimeoutException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class CloudSMSUploaderTests {
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }
    private static RelayHTTPException http(int status) { return new RelayHTTPException(status, ""); }

    /** Replies with a scripted failure per delivery ID and records every send, settle and failure. */
    private static final class Fake {
        final Map<String, Exception> replies = new HashMap<>();
        final List<String> sent = new ArrayList<>();
        final List<String> settled = new ArrayList<>();
        final List<String> failures = new ArrayList<>();

        void flush(CloudSMSUploader uploader, long now, String... pending) throws Exception {
            uploader.flush(List.of(pending), id -> {
                sent.add(id);
                Exception reply = replies.get(id);
                if (reply != null) throw reply;
            }, settled::add, (error, verdict, attempt, retryIn) -> failures.add(verdict + ":" + attempt + ":" + retryIn), now);
        }

        void clear() { sent.clear(); settled.clear(); failures.clear(); }
    }

    public static void main(String[] args) throws Exception {
        var u = new CloudSMSUploader();
        var f = new Fake();
        f.replies.put("a", http(400));
        f.flush(u, 0, "a", "b");
        check(f.sent.equals(List.of("a", "b")), "a rejected message does not hold the next one: " + f.sent);
        check(f.settled.equals(List.of("a", "b")), "rejected and delivered messages both leave the queue: " + f.settled);
        check(f.failures.equals(List.of("DROP:1:0")), "the rejection is reported as a drop: " + f.failures);

        u = new CloudSMSUploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a", "b");
        check(f.sent.equals(List.of("a", "b")), "a transient failure does not hold the next one: " + f.sent);
        check(f.settled.equals(List.of("b")), "only the delivered message leaves the queue: " + f.settled);
        check(f.failures.equals(List.of("RETRY:1:5000")), "the first retry comes after 5 s: " + f.failures);
        f.clear();
        f.flush(u, 4_999, "a");
        check(f.sent.isEmpty(), "not retried before its delay");
        long t = 5_000;
        for (long delay : new long[]{10_000, 20_000, 40_000, 80_000, 160_000, 300_000, 300_000}) {
            f.clear();
            f.flush(u, t, "a");
            check(f.sent.equals(List.of("a")), "retried when due at " + t);
            check(f.failures.size() == 1 && f.failures.get(0).endsWith(":" + delay), "next delay " + delay + ": " + f.failures);
            f.clear();
            f.flush(u, t + delay - 1, "a");
            check(f.sent.isEmpty(), "not retried 1 ms early at " + (t + delay - 1));
            t += delay;
        }

        u = new CloudSMSUploader();
        f = new Fake();
        f.replies.put("a", new SocketTimeoutException("connect timed out"));
        f.flush(u, 0, "a", "b");
        check(f.sent.equals(List.of("a")), "an unreachable Relay is tried once per flush: " + f.sent);
        check(f.failures.equals(List.of("STOP:1:5000")), "a transport failure stops the flush and backs off: " + f.failures);
        check(f.settled.isEmpty(), "nothing leaves the queue while the Relay is unreachable");

        for (int status : new int[]{401, 408, 409, 429, 500, 502, 503}) {
            u = new CloudSMSUploader();
            f = new Fake();
            f.replies.put("a", http(status));
            f.flush(u, 0, "a");
            check(f.failures.equals(List.of("RETRY:1:5000")) && f.settled.isEmpty(), status + " is retried: " + f.failures);
        }
        for (int status : new int[]{400, 403, 404, 413}) {
            u = new CloudSMSUploader();
            f = new Fake();
            f.replies.put("a", http(status));
            f.flush(u, 0, "a");
            check(f.failures.equals(List.of("DROP:1:0")) && f.settled.equals(List.of("a")), status + " is dropped: " + f.failures);
        }

        long day = 24L * 60 * 60 * 1000;
        u = new CloudSMSUploader();
        f = new Fake();
        f.replies.put("a", http(503));
        f.flush(u, 1_000, "a");
        f.clear();
        f.flush(u, 1_000 + day - 1, "a");
        check(f.failures.equals(List.of("RETRY:2:10000")) && f.settled.isEmpty(), "still retried just before 24 h: " + f.failures);
        f.clear();
        f.flush(u, 1_000 + day - 1 + 10_000, "a");
        check(f.failures.equals(List.of("DROP:3:0")) && f.settled.equals(List.of("a")),
                "dropped at its first failure after 24 h: " + f.failures);

        u = new CloudSMSUploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a");
        f.clear();
        f.flush(u, 5_000, "a");
        f.replies.remove("a");
        f.clear();
        f.flush(u, 15_000, "a");
        check(f.settled.equals(List.of("a")) && f.failures.isEmpty(), "delivered on a later attempt: " + f.settled);
        f.replies.put("a", http(502));
        f.clear();
        f.flush(u, 15_001, "a");
        check(f.failures.equals(List.of("RETRY:1:5000")), "success clears the retry state: " + f.failures);

        u = new CloudSMSUploader();
        f = new Fake();
        f.replies.put("a", http(502));
        f.flush(u, 0, "a");
        f.clear();
        f.flush(u, 1_000, "b");
        f.clear();
        f.flush(u, 1_001, "a");
        check(f.sent.equals(List.of("a")) && f.failures.equals(List.of("RETRY:1:5000")),
                "state of a message that left the queue is forgotten: " + f.failures);

        boolean threw = false;
        try {
            new CloudSMSUploader().flush(List.of("a"), id -> {}, id -> { throw new IllegalStateException("disk full"); },
                    (error, verdict, attempt, retryIn) -> {}, 0);
        } catch (IllegalStateException expected) {
            threw = true;
        }
        check(threw, "a failing ledger is not mistaken for a Relay failure");
        System.out.println("CloudSMSUploaderTests passed");
    }
}
