# https://developers.home-assistant.io/docs/add-ons/configuration#add-on-dockerfile
ARG BUILD_FROM="ghcr.io/home-assistant/amd64-base-debian:bookworm"
FROM $BUILD_FROM

# Defaults for local builds (HA builder overrides these)
ARG TEMPIO_VERSION="2024.11.2"
ARG BUILD_ARCH="amd64"

# tempio ist in HA-Add-ons üblich, aber nicht zwingend für dieses Image.
# Der Download kann je nach Release/Arch-Namen variieren; darum fail-open.
RUN set -eux; \
    if curl -fsSL -o /usr/bin/tempio \
      "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_${BUILD_ARCH}"; then \
      chmod +x /usr/bin/tempio; \
    else \
      echo "WARN: tempio download skipped (not found for ${TEMPIO_VERSION}/${BUILD_ARCH})"; \
    fi

# Build-time deps and runtime deps
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true

# Prevent service startups during image build (dpkg postinst scripts)
RUN set -eux; \
  printf '%s\n' '#!/bin/sh' 'exit 101' > /usr/sbin/policy-rc.d; \
  chmod +x /usr/sbin/policy-rc.d; \
  echo "Stubbing systemd helpers for container build"; \
  dpkg-divert --local --rename --add /usr/bin/systemctl || true; \
  printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/bin/systemctl; \
  chmod +x /usr/bin/systemctl; \
  echo "Ensuring /bin/systemctl points to stub (best-effort)"; \
  if [ -e /bin/systemctl ]; then \
    ln -sf /usr/bin/systemctl /bin/systemctl 2>/dev/null || true; \
  fi; \
  dpkg-divert --local --rename --add /usr/bin/deb-systemd-invoke || true; \
  printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/bin/deb-systemd-invoke; \
  chmod +x /usr/bin/deb-systemd-invoke; \
  echo "Stubbing sysv service helper for container build"; \
  dpkg-divert --local --rename --add /usr/sbin/service || true; \
  printf '%s\n' '#!/bin/sh' 'exit 0' > /usr/sbin/service; \
  chmod +x /usr/sbin/service

# ---- Layer 1: minimal base tooling (sehr stabil) ----
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
    lsb-release apt-transport-https \
    procps net-tools iproute2 \
    bash \
  ; \
  rm -rf /var/lib/apt/lists/*

# FreePBX repo (Bookworm) (stabil)
RUN set -eux; \
  mkdir -p /etc/apt/trusted.gpg.d; \
  curl -fsSL http://deb.freepbx.org/gpg/aptly-pubkey.asc | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/freepbx.gpg; \
  echo "deb [arch=amd64] http://deb.freepbx.org/freepbx17-prod bookworm main" >> /etc/apt/sources.list

# ---- Layer 2: Web/DB/Runtime Stack (seltene Änderungen) ----
RUN set -eux; \
  apt-get update; \
  echo "Ensuring fail2ban is not installed (conflicts with sangoma-pbx17)"; \
  apt-get remove -y --purge fail2ban || true; \
  echo "Preparing expected paths for sysadmin17/sangoma-pbx17 postinst"; \
  mkdir -p /var/spool/incron /etc/apache2 /etc/ssh /tftpboot; \
  touch /var/spool/incron/root /etc/apache2/apache2.conf /etc/ssh/sshd_config; \
  apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confnew \
    apache2 apache2-bin apache2-utils \
    libapache2-mod-php8.2 \
    ssl-cert \
    mariadb-server mariadb-client \
    redis-server \
    incron \
    php8.2 php8.2-cli php8.2-common \
    php8.2-curl php8.2-zip php8.2-mysql php8.2-gd php8.2-mbstring php8.2-intl php8.2-xml php8.2-bz2 php8.2-ldap php8.2-sqlite3 php8.2-bcmath php8.2-soap php8.2-ssh2 \
    php-pear \
    cron \
    nodejs npm \
    sox mpg123 lame \
    sqlite3 git \
    jq \
  ; \
  rm -rf /var/lib/apt/lists/*

# ---- Layer 3: PBX/FreePBX Pakete (sehr seltene Änderungen) ----
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confnew \
    liburiparser1 \
    libodbc2 unixodbc \
    libneon27 \
    libsrtp2-1 \
    liblua5.2-0 \
    libiksemel3 \
    libunbound8 \
    libgmime-3.0-0 \
    libspandsp2 \
    libspeexdsp1 \
    libresample1 \
    libical3 \
    asterisk22 asterisk22-core asterisk22-odbc asterisk22-voicemail asterisk22-curl asterisk22-addons asterisk22-addons-core asterisk22-addons-mysql \
    asterisk22.0-freepbx-asterisk-modules \
    asterisk-version-switch \
    asterisk-sounds-core-en-ulaw asterisk-sounds-core-en-alaw \
    asterisk-sounds-moh-opsound-ulaw asterisk-sounds-moh-opsound-alaw \
    sysadmin17 sangoma-pbx17 ffmpeg \
    ioncube-loader-82 freepbx17 \
  ; \
  rm -rf /var/lib/apt/lists/*

# ---- Layer 4: Post-Install Konfiguration (häufiger angepasst) ----
RUN set -eux; \
  # Apache module enabling expects this dir. \
  mkdir -p /etc/apache2/mods-enabled; \
  # Ensure snakeoil certs exist for default-ssl \
  if [ ! -s /etc/ssl/certs/ssl-cert-snakeoil.pem ] || [ ! -s /etc/ssl/private/ssl-cert-snakeoil.key ]; then \
    make-ssl-cert generate-default-snakeoil --force-overwrite; \
  fi; \
  phpenmod freepbx || true; \
  # Für mod_php muss ein MPM aktiv sein; wir nutzen prefork. \
  a2dismod mpm_event mpm_worker || true; \
  a2enmod mpm_prefork || true; \
  # Fallback: falls a2enmod im Container-Context nicht greift, erzwinge den Symlink. \
  if [ -e /etc/apache2/mods-available/mpm_prefork.load ]; then \
    ln -sf ../mods-available/mpm_prefork.load /etc/apache2/mods-enabled/mpm_prefork.load; \
  fi; \
  if [ -e /etc/apache2/mods-available/mpm_prefork.conf ]; then \
    ln -sf ../mods-available/mpm_prefork.conf /etc/apache2/mods-enabled/mpm_prefork.conf; \
  fi; \
  rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.* || true; \
  a2enmod rewrite ssl expires lbmethod_byrequests || true; \
  a2ensite freepbx.conf default-ssl || true; \
  rm -f /var/www/html/index.html || true; \
  sed -i 's/\(^expose_php = \).*/\1Off/' /etc/php/8.2/apache2/php.ini || true; \
  sed -i 's/;max_input_vars = 1000/max_input_vars = 2000/' /etc/php/8.2/apache2/php.ini || true; \
  sed -i 's/\(^ServerTokens \).*/\1Prod/' /etc/apache2/conf-available/security.conf || true; \
  sed -i 's/\(^ServerSignature \).*/\1Off/' /etc/apache2/conf-available/security.conf || true; \
  sed -i 's/;pcre.jit=1/pcre.jit=0/' /etc/php/8.2/apache2/php.ini || true

# Copy root filesystem (s6 services)
COPY rootfs /

# Ensure s6 scripts are executable (s6-rc.d)
RUN set -eux; \
  if [ -d /etc/s6-overlay/s6-rc.d ]; then \
    find /etc/s6-overlay/s6-rc.d -type f \( -name run -o -name up -o -path '*/finish' \) -exec chmod 0755 {} + || true; \
  fi; \
  if [ -d /usr/local/sbin ]; then \
    find /usr/local/sbin -maxdepth 1 -type f -name '*.sh' -exec chmod 0755 {} + || true; \
  fi

# Simple healthcheck: Apache should answer after init
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 CMD curl -fsS http://127.0.0.1/ >/dev/null || exit 1
