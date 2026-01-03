#!/usr/bin/with-contenv bashio
set -euo pipefail

# Mehr Kontext bei Fehlern (auch für s6-rc Exit-Codes hilfreich)
trap 'rc=$?; bashio::log.error "freepbx-init.sh: Abbruch rc=${rc} bei Zeile ${LINENO}: ${BASH_COMMAND}"; exit ${rc}' ERR

# Robust: bashio::config kann je nach Base-Image/Version fehlschlagen.
# In deiner Umgebung crasht bashio::config intern -> wir lesen daher primär /data/options.json.
cfg() {
  local key="$1"
  local default="${2:-}"

  # Home Assistant add-on: Optionen liegen normalerweise hier
  local options_file="/data/options.json"

  if command -v jq >/dev/null 2>&1 && [ -f "$options_file" ]; then
    # jq: Schlüssel kann fehlen -> dann Default
    local jq_filter
    jq_filter=".${key} // empty"

    # type-sicher: bools als true/false, strings als string
    set +e
    local val
    val=$(jq -r "$jq_filter" "$options_file" 2>/dev/null)
    local rc=$?
    set -e

    if [ $rc -eq 0 ] && [ -n "$val" ] && [ "$val" != "null" ]; then
      printf '%s' "$val"
      return 0
    fi

    # Boolean false darf nicht als "empty" durchrutschen -> extra check
    set +e
    val=$(jq -r ".${key} // null" "$options_file" 2>/dev/null)
    rc=$?
    set -e
    if [ $rc -eq 0 ] && [ "$val" = "false" ]; then
      printf '%s' "false"
      return 0
    fi

    # Fallback default
    printf '%s' "$default"
    return 0
  fi

  # Wenn options.json nicht existiert, nur Default (bashio::config wird absichtlich nicht genutzt).
  bashio::log.warning "cfg: kann '${key}' nicht aus ${options_file} lesen; nutze Default"
  printf '%s' "$default"
  return 0
}

bashio::log.info "FreePBX Init (oneshot, s6-rc)..."

# Propagate debug toggles to the environment for downstream services (apache2 vhost)
PHP_DEBUG="$(cfg php_debug false)"
APACHE_DEBUG="$(cfg apache_debug false)"
export HA_PHP_DEBUG="${PHP_DEBUG}"
export HA_APACHE_DEBUG="${APACHE_DEBUG}"
bashio::log.info "Debug toggles: php_debug=${PHP_DEBUG} apache_debug=${APACHE_DEBUG}"

bashio::log.info "Debug: PATH=$PATH"
bashio::log.info "Debug: whoami=$(whoami) uid=$(id -u) gid=$(id -g)"
if command -v mysql >/dev/null 2>&1; then bashio::log.info "Debug: mysql=$(command -v mysql)"; fi
if command -v fwconsole >/dev/null 2>&1; then bashio::log.info "Debug: fwconsole=$(command -v fwconsole)"; fi
if command -v jq >/dev/null 2>&1; then bashio::log.info "Debug: jq=$(command -v jq)"; else bashio::log.warning "Debug: jq nicht gefunden"; fi

INIT_FLAG="/data/.freepbx_initialized"

rand_pw() {
  local out=""
  while [ "${#out}" -lt 24 ]; do
    out+=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | tr -dc 'A-Za-z0-9')
  done
  printf '%s' "${out:0:24}"
}

mysql_here_root() {
  local tmp
  tmp=$(mktemp)
  cat >"${tmp}"
  if mysql -uroot <"${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    return 0
  fi
  if [ -n "${DB_ROOT_PASSWORD:-}" ] && mysql -uroot -p"${DB_ROOT_PASSWORD}" <"${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Liefert eine kurze, nicht-sensitive Beschreibung von Secrets/Config
mask_secret() {
  local s="${1:-}"
  if [ -z "$s" ]; then
    printf '%s' "<leer>"
    return 0
  fi
  # Länge + erste/letzte 2 Zeichen reichen fürs Debugging
  local l=${#s}
  if [ "$l" -le 4 ]; then
    printf '%s' "<len:${l}>"
    return 0
  fi
  printf '%s' "${s:0:2}***${s:l-2:2}<len:${l}>"
}

# Führt SQL als root aus und nutzt dabei bevorzugt das konfigurierte Root-Passwort.
# Verhindert "Access denied for user 'root'@'localhost' (using password: NO)" Logspam.
mysql_root_exec() {
  local tmp
  tmp=$(mktemp)
  cat >"${tmp}"

  # Wenn bereits Secrets existieren, versuchen wir NICHT erst "root ohne Passwort",
  # um Logspam wie "using password: NO" zu vermeiden.
  if [ -f /data/secrets.json ] && [ -n "${DB_ROOT_PASSWORD:-}" ]; then
    bashio::log.info "MySQL root exec: nutze Root-PW aus /data/secrets.json (mask=$(mask_secret "${DB_ROOT_PASSWORD}"))"
    if mysql -uroot -p"${DB_ROOT_PASSWORD}" <"${tmp}" >/dev/null 2>&1; then
      rm -f "${tmp}"
      return 0
    fi
    bashio::log.error "MySQL root exec: Auth mit Root-PW fehlgeschlagen."
    rm -f "${tmp}"
    return 1
  fi

  bashio::log.info "MySQL root exec: versuche Root ohne Passwort (nur Erststart)"
  if mysql -uroot <"${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    return 0
  fi

  bashio::log.info "MySQL root exec: versuche Root mit Passwort (mask=$(mask_secret "${DB_ROOT_PASSWORD}"))"
  if [ -n "${DB_ROOT_PASSWORD:-}" ] && mysql -uroot -p"${DB_ROOT_PASSWORD}" <"${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    return 0
  fi

  bashio::log.error "MySQL root exec: alle Auth-Varianten fehlgeschlagen."
  rm -f "${tmp}"
  return 1
}

# Finde fwconsole auch dann, wenn es nicht im PATH liegt
find_fwconsole() {
  if command -v fwconsole >/dev/null 2>&1; then
    command -v fwconsole
    return 0
  fi

  # typische Pfade (je nach Distro/Install)
  local candidates=(
    "/usr/sbin/fwconsole"
    "/usr/local/sbin/fwconsole"
    "/var/www/html/admin/fwconsole"
    "/var/www/html/admin/bin/fwconsole"
    "/var/www/html/admin/modules/framework/amp_conf/bin/fwconsole"
    "/usr/src/freepbx/admin/fwconsole"
    "/usr/src/freepbx/admin/bin/fwconsole"
  )

  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done

  return 1
}

ensure_fwconsole_symlink() {
  local fw
  if ! fw=$(find_fwconsole); then
    bashio::log.warning "fwconsole: nicht gefunden (PATH + Candidate-Scan)."
    # Minimaler Kontext fürs Debugging
    bashio::log.info "fwconsole debug: ls /usr/sbin/fwconsole=$(ls -l /usr/sbin/fwconsole 2>/dev/null || true)"
    bashio::log.info "fwconsole debug: ls /var/www/html/admin=$(ls -la /var/www/html/admin 2>/dev/null | head -n 20 || true)"
    return 0
  fi

  bashio::log.info "fwconsole: gefunden unter '${fw}'"

  # In einigen Paketlayouts liegt fwconsole unter /var/www/html/...; viele Skripte erwarten /usr/sbin/fwconsole.
  if [ "$fw" != "/usr/sbin/fwconsole" ]; then
    mkdir -p /usr/sbin
    ln -sf "$fw" /usr/sbin/fwconsole || true
    bashio::log.info "fwconsole: Symlink gesetzt: /usr/sbin/fwconsole -> ${fw}"
  fi

  if [ -L /usr/sbin/fwconsole ]; then
    bashio::log.info "fwconsole: /usr/sbin/fwconsole verweist auf $(readlink -f /usr/sbin/fwconsole 2>/dev/null || true)"
  fi
}

fwconsole_safe() {
  local args=("$@")
  bashio::log.info "fwconsole: ${args[*]}"

  local fw
  if ! fw=$(find_fwconsole); then
    bashio::log.warning "fwconsole nicht gefunden (PATH/Install nicht bereit). Überspringe: ${args[*]}"
    return 127
  fi

  # oft muss fwconsole als asterisk laufen
  if command -v s6-setuidgid >/dev/null 2>&1 && getent passwd asterisk >/dev/null 2>&1; then
    if ! s6-setuidgid asterisk "$fw" "${args[@]}"; then
      bashio::log.warning "fwconsole (als asterisk) ${args[*]} fehlgeschlagen (wird ignoriert)."
      return 1
    fi
  else
    if ! "$fw" "${args[@]}"; then
      bashio::log.warning "fwconsole ${args[*]} fehlgeschlagen (wird ignoriert)."
      return 1
    fi
  fi

  return 0
}

# -------- persistence layout --------
bashio::log.info "Persistenz: stelle Verzeichnisse sicher..."
mkdir -p /data/mysql /data/freepbx /data/asterisk
bashio::log.info "Persistenz: /data/mysql /data/freepbx /data/asterisk bereit."

# asterisk user fallback
bashio::log.info "Prüfe User/Group 'asterisk'..."
getent group asterisk >/dev/null 2>&1 || groupadd -r asterisk
getent passwd asterisk >/dev/null 2>&1 || useradd -r -g asterisk -d /home/asterisk -M -s /bin/bash asterisk
bashio::log.info "User/Group 'asterisk' OK."

bashio::log.info "Erstelle/Setze Asterisk-Verzeichnisse & Rechte..."
mkdir -p /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk
# Achtung: Dateien wie *-journal können währenddessen verschwinden (race). Kein fataler Fehler.
if ! chown -R asterisk:asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /etc/asterisk 2>/tmp/freepbx-init-chown.err; then
  bashio::log.warning "chown -R hat Fehler geliefert (wahrscheinlich flüchtige Dateien). Fahre fort."
  # Keine Pipeline (vermeidet SIGPIPE/Exit 128 in manchen Umgebungen)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    bashio::log.warning "chown: $line"
  done < /tmp/freepbx-init-chown.err
fi
rm -f /tmp/freepbx-init-chown.err || true
bashio::log.info "Asterisk-Verzeichnisse OK."

# Versuche, bestehende FreePBX DB-Config zu erkennen (wenn FreePBX bereits Dateien geschrieben hat)
read_freepbx_db_config() {
  local f
  for f in /etc/freepbx.conf /etc/amportal.conf /etc/freepbx/freepbx.conf; do
    if [ -f "$f" ]; then
      # shellcheck disable=SC1090
      if grep -q "AMPDBUSER" "$f" 2>/dev/null; then
        bashio::log.info "DB-Config gefunden in $f"
      fi
      # einfache Parser: KEY=VALUE Zeilen
      local v
      v=$(grep -E "^\s*AMPDBNAME=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
      [ -n "$v" ] && DB_NAME="$v"
      v=$(grep -E "^\s*AMPDBUSER=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
      [ -n "$v" ] && FREEPBX_DB_USER="$v"
      v=$(grep -E "^\s*AMPDBPASS=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
      [ -n "$v" ] && FREEPBX_DB_PASS="$v"
      v=$(grep -E "^\s*AMPDBHOST=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
      [ -n "$v" ] && FREEPBX_DB_HOST="$v"
      return 0
    fi
  done
  return 1
}

write_or_update_kv() {
  # usage: write_or_update_kv <file> <key> <value>
  local file="$1"
  local key="$2"
  local value="$3"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  if grep -qE "^\s*${key}=" "$file" 2>/dev/null; then
    # ersetze nur erste passende Zeile
    sed -i "0,/^\\s*${key}=/{s|^\\s*${key}=.*|${key}=${value}|}" "$file"
    bashio::log.info "Config sync: ${file}: updated ${key}"
  else
    printf '%s\n' "${key}=${value}" >>"$file"
    bashio::log.info "Config sync: ${file}: added ${key}"
  fi
}

sync_freepbx_db_config() {
  # Schreibt AMPDB* in mehrere bekannte FreePBX Config-Dateien so, dass sie zu den erzeugten Secrets passen.
  # Das verhindert "Access denied for user 'freepbxuser'@'localhost'" wenn FreePBX noch alte Defaults nutzt.
  local host="localhost"
  local f

  bashio::log.info "Sync FreePBX DB config: DB_NAME='${DB_NAME}' DB_USER='${DB_USER}' DB_PASSWORD(mask)='$(mask_secret "${DB_PASSWORD}")'"

  # Reihenfolge: systemweite configs, dann ggf. webroot configs.
  for f in \
    /etc/freepbx.conf \
    /etc/amportal.conf \
    /etc/freepbx/freepbx.conf \
    /var/www/html/admin/config.php \
    /var/www/html/admin/config.conf \
    /var/www/html/admin/modules/framework/amp_conf/etc/freepbx.conf
  do
    [ -f "$f" ] || {
      # create only the classic locations; webroot files sollen wir nicht blind erzeugen
      if [ "$f" = "/etc/freepbx.conf" ] || [ "$f" = "/etc/amportal.conf" ] || [ "$f" = "/etc/freepbx/freepbx.conf" ]; then
        :
      else
        continue
      fi
    }

    write_or_update_kv "$f" "AMPDBHOST" "$host"
    write_or_update_kv "$f" "AMPDBNAME" "${DB_NAME}"
    write_or_update_kv "$f" "AMPDBUSER" "${DB_USER}"
    write_or_update_kv "$f" "AMPDBPASS" "${DB_PASSWORD}"
    bashio::log.info "Sync FreePBX DB config: wrote AMPDB* to ${f}"

    # logge finalen Zustand (ohne Passwort im Klartext)
    local u p n h
    u=$(grep -E "^\s*AMPDBUSER=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
    p=$(grep -E "^\s*AMPDBPASS=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
    n=$(grep -E "^\s*AMPDBNAME=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
    h=$(grep -E "^\s*AMPDBHOST=" "$f" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"\r')
    [ -n "$u" ] && bashio::log.info "Config state: ${f}: AMPDBHOST='${h:-}' AMPDBNAME='${n:-}' AMPDBUSER='${u:-}' AMPDBPASS(mask)='$(mask_secret "${p:-}")'"
  done
}

# Read config options
bashio::log.info "Lese Add-on Konfiguration (options.json/jq)..."
ADMIN_USER=$(cfg 'admin_user' 'admin')
ADMIN_PASSWORD=$(cfg 'admin_password' '')
DB_ROOT_PASSWORD=$(cfg 'db_root_password' '')
DB_NAME=$(cfg 'db_name' 'asterisk')
DB_USER=$(cfg 'db_user' 'asteriskuser')
DB_PASSWORD=$(cfg 'db_password' '')
OPENSOURCE_ONLY=$(cfg 'opensource_only' 'false')

# Falls FreePBX schon eine DB-Config hat (z.B. freepbxuser), nutzen wir sie zusätzlich.
FREEPBX_DB_USER=""
FREEPBX_DB_PASS=""
FREEPBX_DB_HOST=""
read_freepbx_db_config || true

if [ -n "${FREEPBX_DB_USER}" ]; then
  bashio::log.info "Erkannte FreePBX DB-Creds: user='${FREEPBX_DB_USER}' host='${FREEPBX_DB_HOST:-localhost}'"
fi

bashio::log.info "Config: admin_user='${ADMIN_USER:-}' db_name='${DB_NAME:-}' db_user='${DB_USER:-}' opensource_only='${OPENSOURCE_ONLY:-}'"

# Generate passwords if empty, persist once
SECRETS_FILE=/data/secrets.json
if [ -f "$SECRETS_FILE" ]; then
  bashio::log.info "Secrets gefunden: $SECRETS_FILE (lese fehlende Werte daraus)"
  ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(jq -r '.admin_password // empty' "$SECRETS_FILE" 2>/dev/null || true)}
  DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD:-$(jq -r '.db_root_password // empty' "$SECRETS_FILE" 2>/dev/null || true)}
  DB_PASSWORD=${DB_PASSWORD:-$(jq -r '.db_password // empty' "$SECRETS_FILE" 2>/dev/null || true)}
else
  bashio::log.info "Keine Secrets-Datei vorhanden: $SECRETS_FILE"
fi

if [ -z "${ADMIN_PASSWORD}" ]; then ADMIN_PASSWORD=$(rand_pw); bashio::log.warning "admin_password war leer → generiert"; fi
if [ -z "${DB_ROOT_PASSWORD}" ]; then DB_ROOT_PASSWORD=$(rand_pw); bashio::log.warning "db_root_password war leer → generiert"; fi
if [ -z "${DB_PASSWORD}" ]; then DB_PASSWORD=$(rand_pw); bashio::log.warning "db_password war leer → generiert"; fi

bashio::log.info "Effective creds: admin_user='${ADMIN_USER}' admin_password(mask)='$(mask_secret "${ADMIN_PASSWORD}")'"
bashio::log.info "Effective creds: db_name='${DB_NAME}' db_user='${DB_USER}' db_password(mask)='$(mask_secret "${DB_PASSWORD}")' db_root_password(mask)='$(mask_secret "${DB_ROOT_PASSWORD}")'"

# Stelle sicher, dass fwconsole später auffindbar ist (best-effort)
ensure_fwconsole_symlink || true

# Synchronisiere FreePBX Config-Dateien auf die finalen Secrets/Options (idempotent)
sync_freepbx_db_config || true

if command -v jq >/dev/null 2>&1; then
  umask 077
  jq -n \
    --arg admin_user "$ADMIN_USER" \
    --arg admin_password "$ADMIN_PASSWORD" \
    --arg db_root_password "$DB_ROOT_PASSWORD" \
    --arg db_name "$DB_NAME" \
    --arg db_user "$DB_USER" \
    --arg db_password "$DB_PASSWORD" \
    '{admin_user:$admin_user, admin_password:$admin_password, db_root_password:$db_root_password, db_name:$db_name, db_user:$db_user, db_password:$db_password}' \
    > "$SECRETS_FILE" || true
  chmod 600 "$SECRETS_FILE" || true
  bashio::log.info "Secrets geschrieben/aktualisiert: $SECRETS_FILE"
fi

# MariaDB Setup: secure root + DB/User prüfen/erstellen...
bashio::log.info "MariaDB Setup: secure root + DB/User prüfen/erstellen..."

# Quick readiness/selftest: root login ohne Details (best-effort)
if mysql_here_root <<<'SELECT 1;' >/dev/null 2>&1; then
  bashio::log.info "MariaDB selftest: root login OK (ohne/mit PW je nach Zustand)."
else
  bashio::log.warning "MariaDB selftest: root login noch nicht OK (wird gleich erneut via mysql_root_exec probiert)."
fi

# Secure mysql root & create app db/user (idempotent)
if ! mysql_root_exec <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
then
  bashio::log.error "Konnte MySQL Root nicht konfigurieren (Auth fehlgeschlagen)."
  exit 1
fi

# Debug: zeige User/Plugin und Grants (ohne Passwörter)
mysql_root_exec <<'SQL' || true
SELECT User,Host,plugin FROM mysql.user WHERE User IN ('root','freepbxuser','asteriskuser','asteriskuser','asteriskuser','asteriskuser') GROUP BY User,Host,plugin;
SQL

# Zusätzlich: Wenn FreePBX einen anderen DB-User verwendet (z.B. freepbxuser), den ebenfalls anlegen.
# Wir nehmen nach sync_freepbx_db_config als "Source of Truth" die Werte aus der (ggf. existierenden) FreePBX-Konfig.
read_freepbx_db_config || true

if [ -n "${FREEPBX_DB_USER}" ]; then
  # Passwort: bevorzugt aus erkannter Config, sonst aus Secrets/options
  if [ -z "${FREEPBX_DB_PASS}" ]; then
    FREEPBX_DB_PASS="${DB_PASSWORD}"
    bashio::log.warning "FREEPBX_DB_PASS nicht gefunden; nutze db_password als Fallback für '${FREEPBX_DB_USER}'"
  fi

  if ! mysql_root_exec <<SQL
CREATE USER IF NOT EXISTS '${FREEPBX_DB_USER}'@'localhost' IDENTIFIED BY '${FREEPBX_DB_PASS}';
ALTER USER '${FREEPBX_DB_USER}'@'localhost' IDENTIFIED BY '${FREEPBX_DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${FREEPBX_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  then
    bashio::log.error "Konnte FreePBX DB-User '${FREEPBX_DB_USER}' nicht anlegen/berechtigen."
    exit 1
  fi

  bashio::log.info "MariaDB: FreePBX DB-User '${FREEPBX_DB_USER}' wurde aktualisiert (Passwort synchronisiert)."
else
  # Kompatibilität: viele FreePBX-Installs nutzen per Default freepbxuser/freepbx.
  # Wenn DB_USER nicht bereits freepbxuser ist, legen wir freepbxuser mit dem db_password an.
  if [ "${DB_USER}" != "freepbxuser" ]; then
    if ! mysql_root_exec <<SQL
CREATE USER IF NOT EXISTS 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'freepbxuser'@'localhost';
FLUSH PRIVILEGES;
SQL
    then
      bashio::log.error "Konnte Kompatibilitäts-User 'freepbxuser' nicht anlegen/berechtigen."
      exit 1
    fi
    bashio::log.info "MariaDB: Kompatibilitäts-User 'freepbxuser' ist bereit (PW=db_password, aktualisiert)."
  fi
fi

bashio::log.info "MariaDB Setup OK."

# Einige FreePBX/PBX-Komponenten (oder Alt-Konfigurationen) verbinden sich hartkodiert als 'freepbxuser'.
# Auch wenn wir AMPDBUSER auf ${DB_USER} setzen, taucht in der Praxis weiter 'freepbxuser' im Log auf.
# Daher halten wir 'freepbxuser' als Alias immer im Gleichschritt mit DB_USER/DB_PASSWORD.
if [ "${DB_USER}" != "freepbxuser" ]; then
  bashio::log.info "MariaDB: sync alias-user 'freepbxuser' -> nutzt das gleiche Passwort wie '${DB_USER}' (mask=$(mask_secret "${DB_PASSWORD}"))."
  if ! mysql_root_exec <<SQL
CREATE USER IF NOT EXISTS 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'freepbxuser'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'freepbxuser'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER 'freepbxuser'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'freepbxuser'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'freepbxuser'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  then
    bashio::log.error "Konnte Alias-User 'freepbxuser' nicht anlegen/berechtigen."
    exit 1
  fi
fi

# Optionaler Selftest für freepbxuser (best-effort)
if mysql -u"freepbxuser" -p"${DB_PASSWORD}" -h"localhost" -e 'SELECT 1;' "${DB_NAME}" >/dev/null 2>&1; then
  bashio::log.info "MariaDB selftest: login als 'freepbxuser'@localhost auf DB '${DB_NAME}' OK."
else
  bashio::log.warning "MariaDB selftest: login als 'freepbxuser'@localhost auf DB '${DB_NAME}' fehlgeschlagen (PW/User/Grants prüfen)."
fi
if mysql -u"freepbxuser" -p"${DB_PASSWORD}" -h"127.0.0.1" -e 'SELECT 1;' "${DB_NAME}" >/dev/null 2>&1; then
  bashio::log.info "MariaDB selftest: login als 'freepbxuser'@127.0.0.1 auf DB '${DB_NAME}' OK."
else
  bashio::log.warning "MariaDB selftest: login als 'freepbxuser'@127.0.0.1 auf DB '${DB_NAME}' fehlgeschlagen (PW/User/Grants prüfen)."
fi

# First-run FreePBX module cleanup and upgrades
if [ ! -f "$INIT_FLAG" ]; then
  bashio::log.info "Erststart: FreePBX initialisieren..."

  #bashio::log.info "Setze Rechte für /var/www/html..."
  #chown -R asterisk:asterisk /var/www/html || true
  #bashio::log.info "Rechte: /var/www/html gesetzt (best-effort)."

  if [ "${OPENSOURCE_ONLY}" = "true" ]; then
    bashio::log.info "OpenSource-only aktiv: entferne kommerzielle Module (falls vorhanden)..."

    # Nur ausführen, wenn fwconsole tatsächlich vorhanden ist.
    if fw=$(find_fwconsole); then
      # Best-effort: Liste ermitteln und entfernen. Kein hard-fail.
      "$fw" ma list 2>/dev/null | awk '/Commercial/ {print $2}' | while IFS= read -r mod; do
        [ -n "$mod" ] || continue
        fwconsole_safe ma -f remove "$mod" || true
      done
      fwconsole_safe ma -f remove firewall || true
    else
      bashio::log.warning "OpenSource-only: fwconsole nicht gefunden, überspringe Modul-Entfernung."
    fi
  fi

  fwconsole_safe ma installlocal || true
  fwconsole_safe ma upgradeall || true
  fwconsole_safe reload || true
  fwconsole_safe restart || true

  date -Iseconds > "$INIT_FLAG"
  bashio::log.info "FreePBX initialisiert. Admin: ${ADMIN_USER} Password: ${ADMIN_PASSWORD}"
  bashio::log.info "Datenbank: ${DB_NAME} User: ${DB_USER} Password: ${DB_PASSWORD}"
  bashio::log.info "Datenbank Root Password: ${DB_ROOT_PASSWORD}"
else
  bashio::log.info "FreePBX bereits initialisiert (Flag vorhanden)."
fi

bashio::log.info "FreePBX Init abgeschlossen."
exit 0

