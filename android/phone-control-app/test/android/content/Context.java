package android.content;

public class Context {
    public static final int MODE_PRIVATE = 0;
    private final java.util.Map<Class<?>, Object> services = new java.util.HashMap<>();
    private final java.util.Set<String> permissions = new java.util.HashSet<>();
    private java.util.Map<String, SharedPreferences> storage = new java.util.HashMap<>();
    public Context getApplicationContext() { return this; }
    public Object getContentResolver() { return null; }
    public String getPackageName() { return "com.airsim.test"; }
    public <T> T getSystemService(Class<T> type) { return type.cast(services.get(type)); }
    public <T> void setSystemService(Class<T> type, T service) { services.put(type, service); }
    public int checkSelfPermission(String permission) { return permissions.contains(permission) ? 0 : -1; }
    public void grant(String permission) { permissions.add(permission); }
    public void revoke(String permission) { permissions.remove(permission); }
    public SharedPreferences getSharedPreferences(String name, int mode) {
        return storage.computeIfAbsent(name, ignored -> new SharedPreferences());
    }
    public Context reopen() {
        Context copy = new Context();
        copy.storage = storage; copy.services.putAll(services); copy.permissions.addAll(permissions);
        return copy;
    }
}
