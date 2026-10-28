# ============================================================
# Stage 1: Build all Social Network C++ RPC services
# ============================================================
FROM anuphal/thrift-microservice-deps:latest AS builder

WORKDIR /social-network-microservices

COPY . .

RUN mkdir -p build && \
    cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    make -j2 \
      ComposePostService \
      UniqueIdService \
      UserService \
      TextService \
      MediaService \
      UrlShortenService \
      UserMentionService \
      PostStorageService \
      UserTimelineService \
      HomeTimelineService \
      SocialGraphService

# Verify and collect all 11 binaries.
RUN set -eu; \
    mkdir -p /tmp/social-network-bin; \
    for svc in \
      ComposePostService \
      UniqueIdService \
      UserService \
      TextService \
      MediaService \
      UrlShortenService \
      UserMentionService \
      PostStorageService \
      UserTimelineService \
      HomeTimelineService \
      SocialGraphService; \
    do \
      test -x "build/src/${svc}/${svc}"; \
      cp "build/src/${svc}/${svc}" /tmp/social-network-bin/; \
    done

# ============================================================
# Stage 2: ARM64 runtime
# ============================================================
FROM hyunjinis/social-network-microservices:arm64-sslfix

WORKDIR /social-network-microservices

# Replace older service binaries with the newly compiled ones.
COPY --from=builder /tmp/social-network-bin/ /usr/local/bin/

# Use configuration from the same source version.
COPY config/service-config.json \
     /social-network-microservices/config/service-config.json

COPY config/jaeger-config.yml \
     /social-network-microservices/config/jaeger-config.yml
