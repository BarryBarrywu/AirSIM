package android.content;

public class Intent {
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;
    public static final int FLAG_ACTIVITY_CLEAR_TOP = 0x04000000;
    public static final int FLAG_ACTIVITY_SINGLE_TOP = 0x20000000;

    public Intent(Context context, Class<?> type) {}
    public Intent addFlags(int flags) { return this; }
    public Intent putExtra(String name, String value) { return this; }
}
