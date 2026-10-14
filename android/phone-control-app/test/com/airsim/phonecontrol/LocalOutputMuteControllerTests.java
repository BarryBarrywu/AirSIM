package com.airsim.phonecontrol;

import java.io.IOException;

public final class LocalOutputMuteControllerTests {
    public static void main(String[] args) throws Exception {
        Platform audio = new Platform();
        LocalOutputMuteController controller = new LocalOutputMuteController(audio);
        controller.setMuted(true);
        check(audio.muted && controller.isVerifiedMuted(), "mute must be verified");
        controller.setMuted(true);
        audio.volume = 1; // OEM changed the index during the remote session.
        controller.setMuted(false);
        check(!audio.muted && audio.volume == 4, "restore the original index after repeated mute");
        check(!controller.isVerifiedMuted(), "restored status must not remain muted");

        audio.muted = true;
        controller.setMuted(true);
        controller.setMuted(false);
        check(audio.muted, "pre-existing user mute must survive the call");

        audio.muted = false;
        audio.supportsMute = false;
        try { controller.setMuted(true); throw new AssertionError("ignored mute must fail visibly"); }
        catch (IOException expected) { /* unsupported OEM implementation */ }
        check(!controller.isVerifiedMuted() && !audio.muted, "no false successful mute");

        audio.supportsMute = true;
        controller.setMuted(true);
        audio.rejectRestore = true;
        try { controller.setMuted(false); throw new AssertionError("failed restoration must surface"); }
        catch (IOException expected) { /* retain the original snapshot for retry */ }
        audio.rejectRestore = false;
        controller.setMuted(false);
        check(!audio.muted && audio.volume == 4, "restore retry must retain original state");

        controller.setMuted(true);
        audio.volume = 1;
        audio.rejectVolume = true;
        try { controller.setMuted(false); throw new AssertionError("partial restore must surface"); }
        catch (IOException expected) { /* unmuted successfully, volume restoration failed */ }
        check(!audio.muted && !controller.isVerifiedMuted(), "partial restore must not claim muted");
        audio.rejectVolume = false;
        controller.setMuted(false);
        check(audio.volume == 4, "partial restoration must remain retryable");
        int changes = audio.changes;
        controller.setMuted(false);
        check(audio.changes == changes, "idle restore must not touch user audio");
        System.out.println("LocalOutputMuteControllerTests passed");
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static final class Platform implements LocalOutputMuteController.Backend {
        boolean muted;
        boolean supportsMute = true;
        boolean rejectRestore;
        boolean rejectVolume;
        int volume = 4;
        int changes;
        public boolean isMuted() { return muted; }
        public int volume() { return volume; }
        public void setVolume(int value) throws IOException {
            if (rejectVolume) throw new IOException("volume restore temporarily unavailable");
            volume = value; changes++;
        }
        public void setMuted(boolean value) throws IOException {
            if (!value && rejectRestore) throw new IOException("platform temporarily unavailable");
            if (supportsMute) muted = value;
            changes++;
        }
    }
}
