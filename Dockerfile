FROM alpine:3.19

ARG GUM_VERSION=0.14.1
ARG SUPERCRONIC_VERSION=0.2.26

RUN apk add --no-cache bash curl ca-certificates coreutils docker-cli tzdata zstd rclone gzip \
    && update-ca-certificates \
    && curl -fsSL -o /tmp/gum.tar.gz https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz \
    && tar -xzf /tmp/gum.tar.gz -C /tmp \
    && mv /tmp/gum_${GUM_VERSION}_Linux_x86_64/gum /usr/local/bin/gum \
    && chmod +x /usr/local/bin/gum \
    && curl -fsSL -o /usr/local/bin/supercronic https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64 \
    && chmod +x /usr/local/bin/supercronic \
    && rm -f /tmp/gum.tar.gz

WORKDIR /app
COPY app/pgcos.sh /app/pgcos.sh
RUN chmod +x /app/pgcos.sh

ENV CONFIG_DIR=/config
ENV RCLONE_CONFIG=/config/rclone.conf

ENTRYPOINT ["/app/pgcos.sh"]
