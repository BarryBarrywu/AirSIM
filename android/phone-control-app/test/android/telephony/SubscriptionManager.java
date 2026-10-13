package android.telephony;
public class SubscriptionManager {
    public SubscriptionInfo info;
    public int numberReadCount;
    public java.util.List<SubscriptionInfo> active;
    public static int defaultVoiceId = -1;
    public static int getDefaultVoiceSubscriptionId() { return defaultVoiceId; }
    public java.util.List<SubscriptionInfo> getActiveSubscriptionInfoList() { return active; }
    public SubscriptionInfo getActiveSubscriptionInfo(int id) {
        if (active != null) return active.stream().filter(value -> value.subscriptionId == id).findFirst().orElse(null);
        return info;
    }
    public String getPhoneNumber(int id) { numberReadCount++; return getActiveSubscriptionInfo(id).getNumber(); }
}
