package com.airsim.phonecontrol;

import android.content.Context;
final class LocalCallAudioController {
    private final ShizukuBridgeManager privilegedBridge;
    private boolean silencing;

    LocalCallAudioController(Context context) {
        privilegedBridge = ShizukuBridgeManager.get(context);
    }

    synchronized void update(boolean shouldSilence) {
        if (shouldSilence == silencing) return;
        silencing = shouldSilence;
        privilegedBridge.setLocalOutputMuted(shouldSilence);
        BridgeLog.info("local_call_output_requested target_suppressed=" + shouldSilence
                + " policy=" + LocalOutputMuteController.policyName(
                    LocalOutputMuteController.strategyForManufacturer(android.os.Build.MANUFACTURER))
                + " backend=shizuku");
    }

    void updateWatchdog(boolean active, String key, String transports) {
        privilegedBridge.updateAudioWatchdog(active, key, transports);
    }
}
