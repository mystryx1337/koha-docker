FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive
ARG S6_OVERLAY_VERSION=3.2.0.2
ARG KOHA_VERSION=stable
ARG TARGETARCH

LABEL org.opencontainers.image.source=https://github.com/mystryx1337/koha-docker
LABEL org.opencontainers.image.description="Modern Multi-Arch Koha Docker Container with s6-overlay"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
            wget \
            curl \
            ca-certificates \
            apache2 \
            gnupg2 \
            apt-transport-https \
            xz-utils \
            pwgen \
            xmlstarlet \
    && rm -rf /var/cache/apt/archives/* \
    && rm -rf /var/lib/apt/lists/*

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz

RUN case ${TARGETARCH} in \
            "amd64") S6_ARCH=x86_64 ;; \
            "arm64") S6_ARCH=aarch64 ;; \
            "arm")   S6_ARCH=armhf ;; \
            *)       S6_ARCH=x86_64 ;; \
        esac \
    && wget -P /tmp/ -q https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz \
    && rm -rf /tmp/s6-overlay*

# Configure Koha official repository
RUN mkdir -p /etc/apt/keyrings/ && \
    wget -qO - https://debian.koha-community.org/koha/gpg.asc | gpg --dearmor -o /etc/apt/keyrings/koha.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/koha.gpg] https://debian.koha-community.org/koha ${KOHA_VERSION} main bullseye" | tee /etc/apt/sources.list.d/koha.list

# Install Koha
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       koha-core \
       idzebra-2.0 \
       libapache2-mpm-itk \
       logrotate \
    && rm -rf /var/cache/apt/archives/* \
    && rm -rf /var/lib/apt/lists/*

# Configure Apache
RUN a2enmod rewrite headers proxy proxy_http cgi setenvif \
    && a2dissite 000-default \
    && echo -e "Listen 8081\nListen 8080" > /etc/apache2/ports.conf \
    && sed -E -i "s#^(export APACHE_LOG_DIR=).*#\1/var/log/koha/apache#g" /etc/apache2/envvars \
    && mkdir -p /var/log/koha/apache \
    && chown -R www-data:www-data /var/log/koha/apache

COPY --chown=0:0 files/ /
WORKDIR /docker

EXPOSE 2100 6001 8080 8081

CMD [ "/init" ]
