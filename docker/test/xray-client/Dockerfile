# Minimal Xray client (SOCKS). Config mounted or generated from subscription URL.
FROM alpine:3.20

RUN apk add --no-cache ca-certificates curl jq unzip wget

ARG XRAY_VERSION=26.2.6
RUN wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" \
    && unzip -q /tmp/xray.zip -d /usr/local/bin xray \
    && chmod +x /usr/local/bin/xray \
    && rm /tmp/xray.zip

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1080

ENTRYPOINT ["/entrypoint.sh"]
