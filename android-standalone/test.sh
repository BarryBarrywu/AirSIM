#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$ROOT/AndroidManifest.xml"

assert_contains() {
  if ! grep -Fq "$2" "$1"; then
    echo "FAIL: $3" >&2
    exit 1
  fi
}

assert_not_contains() {
  if grep -Fq "$2" "$1"; then
    echo "FAIL: $3" >&2
    exit 1
  fi
}

assert_contains "$ROOT/../android/phone-control-app/src/com/airsim/phonecontrol/StandaloneAgentGateway.java" \
  'case "/api/calls/dtmf" -> command("dtmf", localCallTarget("dtmf", input)' \
  'standalone DTMF must preserve the explicitly requested published call identity'

S="$ROOT/../android/phone-control-app/src/com/airsim/phonecontrol/StandaloneAgentService.java"
assert_contains "$S" 'registrationRecovery.takeResync(' \
  'registration sync must honour relay 401 recovery'
assert_contains "$S" 'registrationRecovery.onFailure(heartbeatError' \
  'heartbeat 401 must request re-registration'
assert_contains "$S" 'registrationRecovery.onFailure(error, android.os.SystemClock.elapsedRealtime());' \
  'agent cycle 401 must request re-registration'
assert_contains "$S" 'registrationRecovery.onFailure(error, now);' \
  'command-channel 401 (HTTP poll or WebSocket handshake) must request re-registration'
assert_contains "$S" 'registrationRecovery.onAuthenticated()' \
  'successful heartbeat must reset recovery backoff'
assert_contains "$S" '"simulate-unauthorized"' \
  'dumpsys hook for live verification is missing'

assert_contains "$MANIFEST" 'package="com.airsim.phonecontrol.standalone"' \
  'standalone package id is missing'
assert_contains "$MANIFEST" 'android:versionCode="122"' \
  'standalone version code does not match the current candidate build'
assert_contains "$MANIFEST" 'android:versionName="0.9.8.17"' \
  'standalone version name does not match the current Android candidate'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.STANDALONE_AGENT' \
  'standalone runtime flag is missing'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.StandaloneAgentService' \
  'embedded Agent foreground service is missing'
assert_contains "$MANIFEST" 'android.permission.RECEIVE_SMS' \
  'standalone cannot receive carrier SMS'
assert_contains "$MANIFEST" 'android.permission.READ_SMS' \
  'standalone cannot use the optional inbox fallback'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.IncomingSMSReceiver' \
  'standalone carrier SMS receiver is missing'
assert_not_contains "$MANIFEST" 'com.android.virtualization.terminal' \
  'standalone APK must not query or depend on Linux Terminal'
assert_not_contains "$MANIFEST" 'AgentWatchdogService' \
  'standalone APK must not declare the AVF watchdog'

"$ROOT/../android/phone-control-app/test.sh"
"$ROOT/../android/phone-audio-bridge/build.sh"

"$ROOT/build.sh" >/dev/null
sh "$ROOT/../android/phone-control-app/test-gateway-lifecycle.sh"
sh "$ROOT/../android/phone-control-app/test-owned-dial.sh"
APK="$ROOT/build/android/AirSIM-Android-Standalone-debug.apk"
APKANALYZER=${APKANALYZER:-$(command -v apkanalyzer || true)}
if [ -z "$APKANALYZER" ]; then
  echo "FAIL: apkanalyzer is required to verify the built role manifest" >&2
  exit 1
fi
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home} \
  "$APKANALYZER" manifest print "$APK" | python3 "$ROOT/test/verify_dialer_manifest.py"
echo "Standalone Bridge tests passed"
