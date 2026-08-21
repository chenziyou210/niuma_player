FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NDK_HOME=/opt/ndk
ENV ANDROID_NDK=/opt/ndk
ENV PATH=/opt/ndk:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-17-jdk curl git unzip build-essential python3 yasm cmake pkg-config ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ⚠️ 废弃：这是旧 debugly + FFmpeg 4.0 流程（build.sh）的容器，NDK r26b 只对它有效。
# 现网 ff8.1 产物走 README.md 的手工流程（NDK 21 编 FFmpeg/OpenSSL + NDK 27 编 JNI），
# 见 VERSIONS.lock 的 NDK_FFMPEG_REVISION / NDK_CMAKE_REVISION。仅留档。
RUN curl -fsSL -o /tmp/ndk.zip https://dl.google.com/android/repository/android-ndk-r26b-linux.zip \
    && unzip -q /tmp/ndk.zip -d /opt \
    && mv /opt/android-ndk-r26b /opt/ndk \
    && rm /tmp/ndk.zip

WORKDIR /workspace
CMD ["/bin/bash"]
