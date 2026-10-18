package android.media;

public final class AudioFormat {
    public static final class Builder {
        public Builder setEncoding(int value) { return this; }
        public Builder setSampleRate(int value) { return this; }
        public Builder setChannelMask(int value) { return this; }
        public AudioFormat build() { return new AudioFormat(); }
    }
}
