package com.airsim.phonecontrol;

import android.content.Context;
import android.telephony.SubscriptionManager;

/** Pushes a fresh SIM snapshot to the paired iPhone when subscriptions change. */
final class SIMSlotObserver {
    private static SubscriptionManager manager;
    private static SubscriptionManager.OnSubscriptionsChangedListener listener;

    private SIMSlotObserver() {}

    static synchronized void start(Context context, Runnable onChange) {
        stop(context);
        SubscriptionManager subscriptions = context.getSystemService(SubscriptionManager.class);
        if (subscriptions == null) return;
        manager = subscriptions;
        listener = new SubscriptionManager.OnSubscriptionsChangedListener() {
            @Override public void onSubscriptionsChanged() { onChange.run(); }
        };
        subscriptions.addOnSubscriptionsChangedListener(context.getMainExecutor(), listener);
    }

    static synchronized void stop(Context context) {
        if (manager != null && listener != null) {
            manager.removeOnSubscriptionsChangedListener(listener);
        }
        manager = null;
        listener = null;
    }
}
