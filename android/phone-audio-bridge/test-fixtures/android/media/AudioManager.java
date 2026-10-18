package android.media;

public final class AudioManager {
    public static boolean denyQuery = true;
    public static boolean exposeTx;
    public static AudioDeviceInfo[] getDevicesStatic(int flags) {
        if (denyQuery) throw new SecurityException("private OEM error text");
        return exposeTx ? new AudioDeviceInfo[]{new AudioDeviceInfo()} : new AudioDeviceInfo[0];
    }
}
