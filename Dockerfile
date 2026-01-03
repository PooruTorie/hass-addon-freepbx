ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:bookworm
FROM ${BUILD_FROM}

LABEL \
  io.hass.version="0.1.0" \
  io.hass.type="addon" \
  io.hass.arch="amd64"

ENV \
  LANG=C.UTF-8 \
  DEBIAN_FRONTEND=noninteractive

# 2) Bootstrap-Pakete
RUN apt-get update && \
    apt-get install -y \
      ca-certificates \
      wget curl git tzdata

# 3) Build-/Runtime-Pakete für Asterisk/FreePBX
RUN apt-get update && \
    apt-get install -y \
      build-essential git curl wget htop sngrep \
      libnewt-dev libssl-dev libncurses5-dev subversion \
      libsqlite3-dev libjansson-dev libxml2-dev uuid-dev \
      default-libmysqlclient-dev \
      bison flex \
      apache2 mariadb-server mariadb-client \
      php8.2 php8.2-curl php8.2-cli php8.2-common php8.2-mysql \
      php8.2-gd php8.2-mbstring php8.2-intl php8.2-xml php-pear \
      sox mpg123 sqlite3 pkg-config automake libtool autoconf \
      unixodbc-dev uuid libasound2-dev libogg-dev libvorbis-dev \
      libicu-dev libcurl4-openssl-dev odbc-mariadb libical-dev \
      libneon27-dev libsrtp2-dev libspandsp-dev sudo \
      libtool-bin python-dev-is-python3 \
      unixodbc vim software-properties-common \
      nodejs npm ipset iptables fail2ban php-soap \
      cron

# 4) Asterisk-Quellen holen
RUN cd /usr/src && \
    wget -O asterisk-21-current.tar.gz \
      http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-21-current.tar.gz && \
    rm -rf /usr/src/asterisk && \
    mkdir -p /usr/src/asterisk && \
    tar -xvf asterisk-21-current.tar.gz -C /usr/src/asterisk --strip-components=1

# 5) Asterisk-Abhängigkeiten & Konfiguration
RUN cd /usr/src/asterisk && \
    contrib/scripts/get_mp3_source.sh && \
    contrib/scripts/install_prereq install && \
    ./configure --libdir=/usr/lib64 --with-pjproject-bundled --with-jansson-bundled

# 6) Asterisk bauen & installieren
RUN cd /usr/src/asterisk && \
    make menuselect && \
    make && \
    make install && \
    make samples && \
    make config && \
    ldconfig

# In Containern schlagen ulimit/sysctl Änderungen oft fehl (keine Privileges).
# safe_asterisk soll dann trotzdem weiterlaufen.
RUN if [ -f /usr/sbin/safe_asterisk ]; then \
      sed -i -E 's/^(\s*)ulimit -n (.*)$/\1{ ulimit -n \2; } 2>\/dev\/null; true/' /usr/sbin/safe_asterisk; \
      sed -i -E 's/^(\s*)ulimit -c unlimited$/\1{ ulimit -c unlimited; } 2>\/dev\/null; true/' /usr/sbin/safe_asterisk; \
      sed -i -E 's/\s+\|\|\s+true\s*$//; s/\s+true\s*$//' /usr/sbin/safe_asterisk; \
    fi

# 7) Asterisk-User/Gruppe anlegen
RUN groupadd -r asterisk && \
	useradd -r -d /var/lib/asterisk -g asterisk asterisk && \
	usermod -aG audio,dialout asterisk

# 8) Verzeichnisse & Rechte für Asterisk
RUN mkdir -p /var/lib/asterisk /var/log/asterisk /var/spool/asterisk && \
	chown -R asterisk:asterisk /etc/asterisk && \
	chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk && \
	chown -R asterisk:asterisk /usr/lib64/asterisk && \
	bash -c 'echo "/usr/lib64" >> /etc/ld.so.conf.d/x86_64-linux-gnu.conf' && \
	ldconfig

# 9) Asterisk-Konfig auf User/Group asterisk umstellen
RUN if [ -f /etc/default/asterisk ]; then \
      sed -i 's|^#AST_USER=.*|AST_USER=asterisk|' /etc/default/asterisk && \
      sed -i 's|^#AST_GROUP=.*|AST_GROUP=asterisk|' /etc/default/asterisk; \
    fi

RUN if [ -f /etc/asterisk/asterisk.conf ]; then \
      sed -i 's|^;runuser =.*|runuser = asterisk|' /etc/asterisk/asterisk.conf && \
      sed -i 's|^;rungroup =.*|rungroup = asterisk|' /etc/asterisk/asterisk.conf; \
    fi

# 10) PHP-Tuning
RUN if [ -f /etc/php/8.2/apache2/php.ini ]; then \
      sed -i 's/^\(upload_max_filesize = \).*/\120M/' /etc/php/8.2/apache2/php.ini && \
      sed -i 's/^\(memory_limit = \).*/\1256M/' /etc/php/8.2/apache2/php.ini; \
    fi

# 11) Apache auf User asterisk umstellen
RUN if [ -f /etc/apache2/apache2.conf ]; then \
      sed -i 's/^User .*/User asterisk/' /etc/apache2/apache2.conf && \
      sed -i 's/^Group .*/Group asterisk/' /etc/apache2/apache2.conf && \
      sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf; \
    fi

RUN a2enmod rewrite && \
	systemctl disable apache2 && \
	rm -f /etc/systemd/system/apache2.service && \
	rm -f /var/www/html/index.html

# 12) ODBC-Konfiguration
# Robust in Docker (ohne heredocs), damit der Legacy-Builder nicht am EOF scheitert.
COPY rootfs/etc/odbcinst.ini /etc/
COPY rootfs/etc/odbc.ini /etc/

# 14) FreePBX 17 herunterladen
RUN cd /usr/local/src && \
    wget -O freepbx-17.0-latest-EDGE.tgz \
      http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest-EDGE.tgz && \
    tar zxvf freepbx-17.0-latest-EDGE.tgz

# Cron + Asterisk-User KOMPLETT vorbereiten (VOR FreePBX)
RUN apt-get install -y cron && \
    useradd -r -g crontab -d /var/spool/cron crontab && \
    mkdir -p /var/spool/cron/crontabs && \
    chmod 1730 /var/spool/cron /var/spool/cron/crontabs && \
    chown -R root:crontab /var/spool/cron && \
    chmod u+s /usr/bin/crontab && \
    usermod -aG crontab asterisk

# 15) FreePBX installieren
RUN service mariadb start && \
    mysql -u root -e "SET GLOBAL innodb_file_per_table=1;" && \
    service cron start && \
    sleep 2 && \
 	cd /usr/local/src/freepbx && \
    ./start_asterisk start && \
    ./install -n --user asterisk --group asterisk && \
    fwconsole ma installall && \
    fwconsole reload && \
    fwconsole restart && \
    service cron stop || true

# 16) Aufräumen systemd-Unit
RUN rm -f /etc/systemd/system/freepbx.service || true

# 17) s6-rootfs kopieren
COPY rootfs/ /

RUN find /etc/s6-overlay/s6-rc.d -name "run" -exec chmod +x {} + && \
    find /etc/s6-overlay/s6-rc.d -name "pre-*" -exec chmod +x {} +

# Kein CMD/ENTRYPOINT – wird vom Supervisor mit /init (s6) gestartet
