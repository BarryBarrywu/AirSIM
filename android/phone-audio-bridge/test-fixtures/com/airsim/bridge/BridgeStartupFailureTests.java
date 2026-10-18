package com.airsim.bridge;

import android.media.AudioRecord;
import android.media.AudioManager;
import android.media.AudioAttributes;
import java.lang.reflect.InvocationTargetException;
import java.net.Socket;

/** Runs the real production startup; only Android allocation/query boundaries are replaced. */
public final class BridgeStartupFailureTests {
    public static void main(String[] args) throws Exception {
        var start = PhoneAudioBridge.class.getDeclaredMethod("streamCallAudio", Socket.class, long.class, BridgeStats.class);
        start.setAccessible(true);
        for (int attempt = 0; attempt < 4; attempt++) {
            AudioAttributes.failSetup = attempt % 2 == 0;
            AudioManager.denyQuery = attempt == 1;
            try (Socket socket = new Socket()) {
                try {
                    start.invoke(null, socket, 0L, new BridgeStats());
                    throw new AssertionError("unavailable platform playback setup must fail startup");
                } catch (InvocationTargetException expected) {
                    if (!(expected.getCause() instanceof AudioStartupFailure failure)) throw expected;
                    String expectedPhase = AudioAttributes.failSetup ? "create_attributes" : "select_uplink_route";
                    if (!expectedPhase.equals(failure.diagnosticFields().get("error_phase")))
                        throw new AssertionError("startup failed before reaching the intended OS boundary", failure);
                    String expectedCode = AudioAttributes.failSetup ? "attributes_create_failed"
                            : AudioManager.denyQuery ? "permission_denied" : "telephony_tx_unavailable";
                    if (!expectedCode.equals(failure.diagnosticFields().get("error_code")))
                        throw new AssertionError("a rejected OEM query was mislabeled as an absent cellular route", failure);
                }
            }
            if (AudioRecord.live != 0 || AudioRecord.released != attempt + 1)
                throw new AssertionError("playback setup failure leaked the already-created capture on attempt " + attempt);
        }
        readyWriteFailureIsNotCaptureFailure(start);
        System.out.println("BridgeStartupFailureTests passed: real startup releases capture and distinguishes denied queries from absent routes");
    }

    private static void readyWriteFailureIsNotCaptureFailure(java.lang.reflect.Method start) throws Exception {
        AudioAttributes.failSetup = false; AudioManager.denyQuery = false; AudioManager.exposeTx = true;
        var logs = new java.io.ByteArrayOutputStream();
        var previous = System.out;
        AudioStartupFailure observed = null;
        try (Socket socket = new Socket() {
            @Override public java.io.InputStream getInputStream() {
                return new java.io.ByteArrayInputStream(BridgeProtocol.CLIENT_HELLO);
            }
            @Override public java.io.OutputStream getOutputStream() {
                return new java.io.OutputStream() {
                    @Override public void write(int value) throws java.io.IOException {
                        throw new java.io.IOException("peer closed during READY");
                    }
                };
            }
        }) {
            System.setOut(new java.io.PrintStream(logs));
            try { start.invoke(null, socket, 0L, new BridgeStats()); }
            catch (InvocationTargetException error) {
                if (!(error.getCause() instanceof AudioStartupFailure)) throw error;
                observed = (AudioStartupFailure) error.getCause();
            }
        } finally { System.setOut(previous); }
        if (observed == null || !"handshake_write_failed".equals(observed.diagnosticFields().get("error_code")))
            throw new AssertionError("READY transport write failure was mistaken for capture/HAL failure", observed);
        if (AudioRecord.live != 0 || android.media.AudioTrack.live != 0 || android.media.AudioTrack.released != 1)
            throw new AssertionError("READY write failure did not release both started native endpoints");
        String text = logs.toString(java.nio.charset.StandardCharsets.UTF_8);
        if (!text.contains("\"event\":\"audio_initialized\"") || text.contains("\"event\":\"client_ready\""))
            throw new AssertionError("READY write failure falsely announced usable media or skipped endpoint setup");
    }
}
