package android.media;

/** External OS boundary: allocating capture succeeds, later Android setup is unavailable. */
public class AudioRecord {
    public static int live, released;
    private int state = 1;
    public static final int RECORDSTATE_RECORDING = 3;
    public AudioRecord(int source, int rate, int channels, int encoding, int bytes) { live++; }
    public static int getMinBufferSize(int rate, int channels, int encoding) { return 320; }
    public int getState() { return 1; }
    public int getAudioSessionId() { return 100; }
    public int getRecordingState() { return state; }
    public void startRecording() { state = 3; }
    public void stop() { state = 1; }
    public void release() { released++; live--; }
}
