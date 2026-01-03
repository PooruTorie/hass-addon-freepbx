<?php
header('Content-Type: text/plain; charset=utf-8');

// Basic runtime info
echo "health.php OK\n";
echo "PHP version: ".PHP_VERSION."\n";
echo "SAPI: ".php_sapi_name()."\n";

echo "\n-- ini files --\n";
echo "loaded_ini=".(php_ini_loaded_file() ?: '')."\n";
echo "scanned_ini_files=".(php_ini_scanned_files() ?: '')."\n";

echo "\n-- ini --\n";
echo "log_errors=".ini_get('log_errors')."\n";
echo "error_log=".ini_get('error_log')."\n";
echo "display_errors=".ini_get('display_errors')."\n";
echo "display_startup_errors=".ini_get('display_startup_errors')."\n";
echo "error_reporting=".ini_get('error_reporting')."\n";

echo "\n-- env --\n";
echo "HA_PHP_DEBUG=".(getenv('HA_PHP_DEBUG') ?: '')."\n";
echo "HA_APACHE_DEBUG=".(getenv('HA_APACHE_DEBUG') ?: '')."\n";

// ---- logging probe ----
function ha_log_probe(string $msg): void {
    $prefix = '[HA-PHP-PROBE] ' . date('c') . ' ';
    // 1) PHP error_log()
    @error_log($prefix . $msg);
    // 2) trigger_error (should go through normal error handling)
    @trigger_error($prefix . $msg, E_USER_WARNING);
    // 3) syslog (may or may not be available)
    if (function_exists('openlog') && function_exists('syslog')) {
        @openlog('freepbx-ha', LOG_PID, LOG_USER);
        @syslog(LOG_WARNING, $prefix . $msg);
        @closelog();
    }
}

if (isset($_GET['probe'])) {
    ha_log_probe('probe=1 endpoint hit');
    echo "\nprobe: wrote to error_log()+trigger_error()+syslog (if available)\n";
}

// If requested, trigger a warning and a fatal to prove error logging.
if (isset($_GET['warn'])) {
    ha_log_probe('forced warning');
    trigger_error('health.php forced user warning', E_USER_WARNING);
    echo "Triggered E_USER_WARNING\n";
}

if (isset($_GET['fatal'])) {
    ha_log_probe('forced fatal next');
    // Undefined function -> fatal
    healthphp_nonexistent_function();
}
