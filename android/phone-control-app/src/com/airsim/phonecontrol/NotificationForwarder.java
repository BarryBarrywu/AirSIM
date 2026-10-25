package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Best-effort notification egress owned by Android. It never blocks call/SMS
 * handling, never goes through Relay/APNs, and therefore survives iPhone force
 * quit and Relay quota outages.
 */
final class NotificationForwarder {
    private static final ExecutorService WORKERS = Executors.newSingleThreadExecutor(r -> {
        Thread thread = new Thread(r, "AirSIMForwarder");
        thread.setDaemon(true);
        return thread;
    });

    private NotificationForwarder() {}

    static void handle(Context context, JSONObject event) {
        JSONObject config = ForwardingConfigStore.config(context);
        if (!config.optBoolean("enabled", false)) return;
        JSONArray destinations = config.optJSONArray("destinations");
        if (destinations == null || destinations.length() == 0) return;

        String type = event.optString("event", "");
        boolean sms = "incoming_sms".equals(type) || "sms".equals(type);
        boolean call = type.contains("call") || event.has("direction");
        boolean ringing = "incoming".equals(event.optString("direction"))
                && "incoming".equals(event.optString("state"));
        boolean missed = "ended".equals(event.optString("state"))
                && "incoming".equals(event.optString("direction"));

        for (int i = 0; i < destinations.length(); i++) {
            JSONObject destination = destinations.optJSONObject(i);
            if (destination == null || !destination.optBoolean("enabled", true)) continue;
            if (sms && !destination.optBoolean("sendSMS", true)) continue;
            if (call && ringing && !destination.optBoolean("sendIncomingCall", true)) continue;
            if (call && missed && !destination.optBoolean("sendMissedCall", false)) continue;
            if (call && !ringing && !missed) continue;
            if (!sms && !call) continue;
            final JSONObject target = destination;
            final JSONObject payload = event;
            WORKERS.execute(() -> send(context, target, payload, sms, missed));
        }
    }

    private static void send(Context context, JSONObject destination, JSONObject event,
                             boolean sms, boolean missed) {
        try {
            String delivery = event.optString("delivery_id",
                    event.optString("call_uuid") + ":" + event.optString("state"));
            if (delivery.isEmpty() || alreadyForwarded(context, destination, delivery)) return;

            String text = render(destination, event, sms, missed);
            String channel = destination.optString("channel", "webhook");
            String url = destination.optString("webhookURL", "");
            JSONObject body = new JSONObject();
            String method = "POST";
            String contentType = "application/json";

            switch (channel) {
                case "bark" -> body.put("title", "AirSIM").put("body", text).put("group", "AirSIM");
                case "discord" -> body.put("content", text);
                case "slack" -> body.put("text", text);
                case "wecom" -> body.put("msgtype", "text")
                        .put("text", new JSONObject().put("content", text));
                case "feishu" -> body.put("msg_type", "text")
                        .put("content", new JSONObject().put("text", text));
                case "telegram" -> {
                    String token = destination.optString("token", "");
                    if (url.isEmpty()) url = "https://api.telegram.org/bot" + token + "/sendMessage";
                    body.put("chat_id", destination.optString("chatID", ""));
                    body.put("text", text);
                }
                case "qq" -> {
                    String chatID = destination.optString("chatID", "");
                    if (url.isEmpty()) url = "https://api.sgroup.qq.com/v2/users/"
                            + java.net.URLEncoder.encode(chatID, "UTF-8") + "/messages";
                    body.put("content", text).put("msg_type", 0);
                    contentType = "application/json";
                }
                default -> body.put("text", text)
                        .put("event", event.optString("event"))
                        .put("device", deviceName())
                        .put("number", destination.optBoolean("includeNumber", true)
                                ? event.optString("number") : "")
                        .put("sender", event.optString("sender"))
                        .put("content", destination.optBoolean("includeBody", true)
                                ? event.optString("content") : "")
                        .put("time", Instant.now().toString());
            }
            if (url.isBlank()) return;
            if ("qq".equals(channel) && !destination.optString("token", "").isBlank()) {
                // Authorization is passed separately below.
            }
            post(url, body.toString(), destination, channel);
            markForwarded(context, destination, delivery);
            BridgeLog.info("notification_forwarded channel=" + channel);
        } catch (Exception error) {
            BridgeLog.error("notification_forward_failed", error);
        }
    }

    private static String render(JSONObject destination, JSONObject event,
                                 boolean sms, boolean missed) {
        String template = destination.optString("template", "");
        if (template.isBlank()) template = "{event}\n{device}\n{number}\n{sender}\n{content}\n{time}";
        String number = destination.optBoolean("includeNumber", true)
                ? event.optString("number", "") : "";
        String content = destination.optBoolean("includeBody", true)
                ? event.optString("content", "") : "";
        String eventName = sms ? "短信" : missed ? "未接来电" : "来电";
        String device = deviceName();
        return template
                .replace("{event}", eventName)
                .replace("{device}", device)
                .replace("{number}", number)
                .replace("{sender}", event.optString("sender", ""))
                .replace("{content}", content)
                .replace("{time}", Instant.now().toString());
    }

    private static void post(String endpoint, String body, JSONObject destination,
                             String channel) throws Exception {
        URL url = new URL(endpoint);
        if (!"https".equalsIgnoreCase(url.getProtocol())) {
            throw new IllegalArgumentException("forwarding webhook must use HTTPS");
        }
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        try {
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(8_000);
            connection.setReadTimeout(10_000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            if ("qq".equals(channel)) {
                String token = destination.optString("token", "");
                if (!token.isBlank()) connection.setRequestProperty("Authorization", "QQBot " + token);
            }
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body.getBytes(StandardCharsets.UTF_8));
            }
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) {
                throw new IllegalStateException("forwarding HTTP " + status);
            }
        } finally {
            connection.disconnect();
        }
    }

    private static boolean alreadyForwarded(Context context, JSONObject destination, String delivery) {
        String id = destination.optString("id", "") + ":" + delivery;
        return context.getSharedPreferences("notification_forwarding", Context.MODE_PRIVATE)
                .getStringSet("sent", java.util.Collections.emptySet()).contains(id);
    }

    private static void markForwarded(Context context, JSONObject destination, String delivery) {
        String id = destination.optString("id", "") + ":" + delivery;
        android.content.SharedPreferences preferences =
                context.getSharedPreferences("notification_forwarding", Context.MODE_PRIVATE);
        java.util.Set<String> sent = new java.util.HashSet<>(
                preferences.getStringSet("sent", java.util.Collections.emptySet()));
        sent.add(id);
        while (sent.size() > 256) sent.remove(sent.iterator().next());
        preferences.edit().putStringSet("sent", sent).apply();
    }

    private static String deviceName() {
        return android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL;
    }
}
