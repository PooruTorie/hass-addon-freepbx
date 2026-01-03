#!/usr/bin/with-contenv bashio
set -euo pipefail

# Asterisk-Konfig erwartet teils *_custom.conf Includes. In klassischen
# FreePBX-Installationen werden diese Dateien oft erst später erzeugt.
# Damit Asterisk nicht mit Fehlern/Exit abbricht, legen wir leere Stubs an.

mkdir -p /etc/asterisk

for f in \
  logger_general_custom.conf \
  globals_custom.conf \
  extensions_custom.conf \
  extconfig_custom.conf \
  res_odbc_custom.conf \
  res_odbc.conf
 do
  if [ ! -e "/etc/asterisk/${f}" ]; then
    : > "/etc/asterisk/${f}"
  fi
done

