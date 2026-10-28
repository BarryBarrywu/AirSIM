package com.airsim.phonecontrol;

public final class RelayRegistrationRecoveryTests {
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }

    public static void main(String[] args) {
        var r = new RelayRegistrationRecovery();
        check(!r.takeResync(0), "nothing pending initially");
        r.onFailure(new RelayHTTPException(500, ""), 0);
        r.onFailure(new RelayHTTPException(429, ""), 0);
        r.onFailure(new java.io.IOException("offline"), 0);
        r.onFailure(null, 0);
        check(!r.takeResync(0), "only 401 schedules a resync");
        r.onFailure(new RelayHTTPException(401, "{\"error\":\"unauthorized\"}"), 0);
        check(r.takeResync(0), "first 401 resyncs immediately");
        check(!r.takeResync(0), "resync is one-shot");
        long t = 0;
        for (long w : new long[]{60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000, 3_600_000, 3_600_000}) {
            r.onFailure(new RelayHTTPException(401, ""), t + w - 1);
            check(!r.takeResync(t + w - 1), "401 inside window is dropped: " + w);
            check(!r.takeResync(t + w), "401 inside window is not queued: " + w);
            t += w;
            r.onFailure(new RelayHTTPException(401, ""), t);
            check(r.takeResync(t), "401 after window resyncs: " + w);
        }
        r.onAuthenticated();
        r.onFailure(new RelayHTTPException(401, ""), t + 1);
        check(r.takeResync(t + 1), "authentication resets backoff");
        check(r.describe(t + 1).contains("resyncs=10"), "describe reports the resync count");
        System.out.println("RelayRegistrationRecoveryTests passed");
    }
}
