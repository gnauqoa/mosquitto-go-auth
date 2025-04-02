# Define Mosquitto version, see also .github/workflows/build_and_push_docker_images.yml for
# the automatically built images
ARG MOSQUITTO_VERSION=2.0.18
# Define libwebsocket version
ARG LWS_VERSION=4.2.2
# PostgreSQL configuration ARGs
ARG DATABASE_HOST
ARG DATABASE_PORT
ARG DATABASE_NAME
ARG DATABASE_USERNAME
ARG DATABASE_PASSWORD
ARG DATABASE_CONNECT_TRIES
ARG DATABASE_SSL_MODE

# Auth configuration ARGs
ARG AUTH_LOG_LEVEL
ARG AUTH_CHECK_PREFIX
ARG AUTH_HASHER
ARG AUTH_HASHER_COST

# PostgreSQL query configuration ARGs
ARG AUTH_PG_USERQUERY
ARG AUTH_PG_ACLQUERY
ARG AUTH_PG_SUPERQUERY

# Use debian:stable-slim as a builder for Mosquitto and dependencies.
FROM debian:stable-slim as mosquitto_builder
ARG MOSQUITTO_VERSION
ARG LWS_VERSION

# Get mosquitto build dependencies.
RUN set -ex; \
    apt-get update; \
    apt-get install -y wget build-essential cmake libssl-dev libcjson-dev

# Get libwebsocket. Debian's libwebsockets is too old for Mosquitto version > 2.x so it gets built from source.
RUN set -ex; \
    wget https://github.com/warmcat/libwebsockets/archive/v${LWS_VERSION}.tar.gz -O /tmp/lws.tar.gz; \
    mkdir -p /build/lws; \
    tar --strip=1 -xf /tmp/lws.tar.gz -C /build/lws; \
    rm /tmp/lws.tar.gz; \
    cd /build/lws; \
    cmake . \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DLWS_IPV6=ON \
        -DLWS_WITHOUT_BUILTIN_GETIFADDRS=ON \
        -DLWS_WITHOUT_CLIENT=ON \
        -DLWS_WITHOUT_EXTENSIONS=ON \
        -DLWS_WITHOUT_TESTAPPS=ON \
        -DLWS_WITH_HTTP2=OFF \
        -DLWS_WITH_SHARED=OFF \
        -DLWS_WITH_ZIP_FOPS=OFF \
        -DLWS_WITH_ZLIB=OFF \
        -DLWS_WITH_EXTERNAL_POLL=ON; \
    make -j "$(nproc)"; \
    rm -rf /root/.cmake

WORKDIR /app

RUN mkdir -p mosquitto/auth mosquitto/conf.d

RUN wget http://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz

RUN tar xzvf mosquitto-${MOSQUITTO_VERSION}.tar.gz

# Build mosquitto.
RUN set -ex; \
    cd mosquitto-${MOSQUITTO_VERSION}; \
    make CFLAGS="-Wall -O2 -I/build/lws/include" LDFLAGS="-L/build/lws/lib" WITH_WEBSOCKETS=yes; \
    make install;

# Use golang:latest as a builder for the Mosquitto Go Auth plugin.
FROM --platform=$BUILDPLATFORM golang:latest AS go_auth_builder

ENV CGO_CFLAGS="-I/usr/local/include -fPIC"
ENV CGO_LDFLAGS="-shared -Wl,-unresolved-symbols=ignore-all"
ENV CGO_ENABLED=1

# Bring TARGETPLATFORM to the build scope
ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Install TARGETPLATFORM parser to translate its value to GOOS, GOARCH, and GOARM
COPY --from=tonistiigi/xx:golang / /
RUN go env

# Install needed libc and gcc for target platform.
RUN set -ex; \
  if [ ! -z "$TARGETPLATFORM" ]; then \
    case "$TARGETPLATFORM" in \
  "linux/arm64") \
    apt update && apt install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
    ;; \
  "linux/arm/v7") \
    apt update && apt install -y gcc-arm-linux-gnueabihf libc6-dev-armhf-cross \
    ;; \
  "linux/arm/v6") \
    apt update && apt install -y gcc-arm-linux-gnueabihf libc6-dev-armel-cross libc6-dev-armhf-cross \
    ;; \
  esac \
  fi

WORKDIR /app
COPY --from=mosquitto_builder /usr/local/include/ /usr/local/include/

COPY ./ ./
RUN set -ex; \
    go build -buildmode=c-archive go-auth.go; \
    go build -buildmode=c-shared -o go-auth.so; \
	  go build pw-gen/pw.go

#Start from a new image.
FROM debian:stable-slim
# Set environment variables with ARG defaults
ENV DATABASE_HOST=${DATABASE_HOST:-postgres}
ENV DATABASE_PORT=${DATABASE_PORT:-5432}
ENV DATABASE_NAME=${DATABASE_NAME:-mqtt}
ENV DATABASE_USERNAME=${DATABASE_USERNAME:-mqtt}
ENV DATABASE_PASSWORD=${DATABASE_PASSWORD:-mqtt}
ENV DATABASE_CONNECT_TRIES=${DATABASE_CONNECT_TRIES:-5}
ENV DATABASE_SSL_MODE=${DATABASE_SSL_MODE:-disable}
ENV AUTH_LOG_LEVEL=${AUTH_LOG_LEVEL:-debug}
ENV AUTH_CHECK_PREFIX=${AUTH_CHECK_PREFIX:-false}
ENV AUTH_HASHER=${AUTH_HASHER:-bcrypt}
ENV AUTH_HASHER_COST=${AUTH_HASHER_COST:-10}
ENV AUTH_PG_USERQUERY=${AUTH_PG_USERQUERY:-'SELECT "deviceToken" FROM "device" WHERE "deviceKey" = $1 limit 1'}
ENV AUTH_PG_ACLQUERY=${AUTH_PG_ACLQUERY:-'SELECT "topic" FROM "mqtt_acl" acl JOIN "device" on acl."deviceId" = "device".id WHERE "device"."deviceKey" = $1 and (acl.rw = $2 or acl.rw = 999)'}
ENV AUTH_PG_SUPERQUERY=${AUTH_PG_SUPERQUERY:-'SELECT count(*) FROM "device" WHERE "deviceKey" = $1 and "role" = 1'}

RUN set -ex; \
    apt update; \
    apt install -y libc-ares2 openssl uuid tini wget libssl-dev libcjson-dev

RUN mkdir -p /var/lib/mosquitto /var/log/mosquitto
RUN set -ex; \
    groupadd mosquitto; \
    useradd -s /sbin/nologin mosquitto -g mosquitto -d /var/lib/mosquitto; \
    chown -R mosquitto:mosquitto /var/log/mosquitto/; \
    chown -R mosquitto:mosquitto /var/lib/mosquitto/

# Create mosquitto config directory
RUN mkdir -p /etc/mosquitto

# Create a script to generate mosquitto.conf from environment variables
RUN echo '#!/bin/sh\n\
echo "listener 1883\n\
protocol mqtt\n\
allow_anonymous false\n\
\n\
auth_plugin /mosquitto/go-auth.so\n\
auth_opt_log_level ${AUTH_LOG_LEVEL}\n\
\n\
auth_opt_backends postgres\n\
auth_opt_check_prefix ${AUTH_CHECK_PREFIX}\n\
allow_anonymous false\n\
\n\
auth_opt_pg_host ${DATABASE_HOST}\n\
auth_opt_pg_port ${DATABASE_PORT}\n\
auth_opt_pg_dbname ${DATABASE_NAME}\n\
auth_opt_pg_user ${DATABASE_USERNAME}\n\
auth_opt_pg_password ${DATABASE_PASSWORD}\n\
\n\
auth_opt_pg_connect_tries ${DATABASE_CONNECT_TRIES}\n\
auth_opt_pg_sslmode ${DATABASE_SSL_MODE}\n\
auth_opt_pg_userquery ${AUTH_PG_USERQUERY}\n\
auth_opt_pg_aclquery ${AUTH_PG_ACLQUERY}\n\
auth_opt_pg_superquery ${AUTH_PG_SUPERQUERY}\n\
\n\
auth_opt_hasher ${AUTH_HASHER}\n\
auth_opt_hasher_cost ${AUTH_HASHER_COST}" > /etc/mosquitto/mosquitto.conf' > /usr/local/bin/generate-config.sh && \
    chmod +x /usr/local/bin/generate-config.sh

#Copy confs, plugin so and mosquitto binary.
COPY --from=mosquitto_builder /app/mosquitto/ /mosquitto/
COPY --from=go_auth_builder /app/pw /mosquitto/pw
COPY --from=go_auth_builder /app/go-auth.so /mosquitto/go-auth.so
COPY --from=mosquitto_builder /usr/local/sbin/mosquitto /usr/sbin/mosquitto

COPY --from=mosquitto_builder /usr/local/lib/libmosquitto* /usr/local/lib/

COPY --from=mosquitto_builder /usr/local/bin/mosquitto_passwd /usr/bin/mosquitto_passwd
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_sub /usr/bin/mosquitto_sub
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_pub /usr/bin/mosquitto_pub
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_rr /usr/bin/mosquitto_rr

RUN ldconfig;
EXPOSE 1883 1884

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/sh", "-c", "/usr/local/bin/generate-config.sh && /usr/sbin/mosquitto -c /etc/mosquitto/mosquitto.conf"]
