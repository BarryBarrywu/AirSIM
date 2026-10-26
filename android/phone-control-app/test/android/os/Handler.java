package android.os;

public final class Handler {
    public Handler(Looper looper) {}

    public boolean post(Runnable action) {
        action.run();
        return true;
    }

    public boolean postDelayed(Runnable action, long delayMillis) {
        action.run();
        return true;
    }
}
