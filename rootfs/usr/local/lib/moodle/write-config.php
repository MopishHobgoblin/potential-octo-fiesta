<?php
// Generates Moodle's config.php from environment variables at container start.
// Values are written with var_export() so quotes/backslashes in passwords are safe.
declare(strict_types=1);

function env(string $name, string $default = ''): string {
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

function env_bool(string $name, bool $default = false): bool {
    return in_array(strtolower(env($name, $default ? 'true' : 'false')), ['1', 'true', 'yes', 'on'], true);
}

function cfg(string $property, $value, string $indent = ''): string {
    return $indent . '$CFG->' . $property . ' = ' . var_export($value, true) . ";\n";
}

$root     = env('MOODLE_ROOT', '/var/www/moodle');
$dataroot = env('MOODLE_DATA', '/var/www/moodledata');
$confdir  = env('CONFIG_DIR', '/config');
$wwwroot  = rtrim(env('MOODLE_URL'), '/');
$dbtype   = env('MOODLE_DB_TYPE', 'mariadb');
$dbport   = (int) env('MOODLE_DB_PORT', $dbtype === 'pgsql' ? '5432' : '3306');

$sslproxy = strtolower(env('MOODLE_SSLPROXY', 'auto')) === 'auto'
    ? str_starts_with($wwwroot, 'https://')
    : env_bool('MOODLE_SSLPROXY');

$dboptions = ['dbpersist' => 0, 'dbport' => $dbport, 'dbsocket' => ''];
if (in_array($dbtype, ['mariadb', 'mysqli'], true)) {
    $dboptions['dbcollation'] = 'utf8mb4_unicode_ci';
}

$out  = "<?php  // Moodle configuration file\n";
$out .= "//\n// GENERATED AUTOMATICALLY at container start - manual edits will be overwritten.\n";
$out .= "// Change environment variables instead, or add settings to {$confdir}/config.extra.php\n\n";
$out .= "unset(\$CFG);\nglobal \$CFG;\n\$CFG = new stdClass();\n\n";

// Database.
$out .= cfg('dbtype', $dbtype);
$out .= cfg('dblibrary', 'native');
$out .= cfg('dbhost', env('MOODLE_DB_HOST', '127.0.0.1'));
$out .= cfg('dbname', env('MOODLE_DB_NAME', 'moodle'));
$out .= cfg('dbuser', env('MOODLE_DB_USER', 'moodle'));
$out .= cfg('dbpass', env('MOODLE_DB_PASSWORD'));
$out .= cfg('prefix', env('MOODLE_DB_PREFIX', 'mdl_'));
$out .= cfg('dboptions', $dboptions);
$out .= "\n";

// Site paths.
$out .= cfg('wwwroot', $wwwroot);
$out .= cfg('dataroot', $dataroot);
$out .= cfg('admin', 'admin');
$out .= cfg('directorypermissions', 02777);
$out .= cfg('sslproxy', $sslproxy);
$out .= cfg('routerconfigured', true);
$out .= "\n";

// Let nginx deliver files from moodledata.
$out .= cfg('xsendfile', 'X-Accel-Redirect');
$out .= cfg('xsendfilealiases', ['/dataroot/' => $dataroot]);
$out .= "\n";

// Executables available in the image; lock them so they can't be changed from the web UI.
$out .= cfg('pathtophp', '/usr/local/bin/php');
$out .= cfg('pathtodu', '/usr/bin/du');
$out .= cfg('aspellpath', '/usr/bin/aspell');
$out .= cfg('pathtodot', '/usr/bin/dot');
$out .= cfg('pathtogs', '/usr/bin/gs');
$out .= cfg('pathtopdftoppm', '/usr/bin/pdftoppm');
$out .= cfg('preventexecpath', true);

// Code is rebuilt from the image on every update: install plugins via /config/plugins instead.
$out .= cfg('disableupdateautodeploy', true);

if (($key = env('MOODLE_UPGRADE_KEY')) !== '') {
    $out .= cfg('upgradekey', $key);
}

// Redis sessions. Skipped while the entrypoint runs install/upgrade (Redis isn't started yet).
if (env_bool('MOODLE_REDIS_ENABLED', true)) {
    $out .= "\nif (getenv('MOODLE_BOOTSTRAP') === false) {\n";
    $out .= cfg('session_handler_class', '\\core\\session\\redis', '    ');
    $out .= cfg('session_redis_host', env('MOODLE_REDIS_HOST', '127.0.0.1'), '    ');
    $out .= cfg('session_redis_port', (int) env('MOODLE_REDIS_PORT', '6379'), '    ');
    $out .= cfg('session_redis_database', 0, '    ');
    $out .= cfg('session_redis_prefix', 'mdl_sess_', '    ');
    $out .= cfg('session_redis_acquire_lock_timeout', 120, '    ');
    $out .= cfg('session_redis_lock_expire', 7200, '    ');
    if (($auth = env('MOODLE_REDIS_PASSWORD')) !== '') {
        $out .= cfg('session_redis_auth', $auth, '    ');
    }
    $out .= "}\n";
}

// Outgoing mail (optional; when set these are locked in the admin UI).
if (($smtphost = env('MOODLE_SMTP_HOST')) !== '') {
    $out .= "\n" . cfg('smtphosts', $smtphost);
    $out .= cfg('smtpsecure', env('MOODLE_SMTP_SECURE'));
    if (($smtpuser = env('MOODLE_SMTP_USER')) !== '') {
        $out .= cfg('smtpauthtype', 'LOGIN');
        $out .= cfg('smtpuser', $smtpuser);
        $out .= cfg('smtppass', env('MOODLE_SMTP_PASSWORD'));
    }
}
if (($noreply = env('MOODLE_NOREPLY_ADDRESS')) !== '') {
    $out .= cfg('noreplyaddress', $noreply);
}

if (env_bool('MOODLE_DEBUG')) {
    $out .= "\n" . cfg('debug', 32767) . cfg('debugdisplay', 1);
}

$extra = $confdir . '/config.extra.php';
$out .= "\n// Optional local overrides.\n";
$out .= 'if (is_readable(' . var_export($extra, true) . ")) {\n";
$out .= '    require ' . var_export($extra, true) . ";\n}\n\n";

$out .= "if (file_exists(__DIR__ . '/public/lib/setup.php')) {\n";
$out .= "    require_once(__DIR__ . '/public/lib/setup.php');\n";
$out .= "} else {\n";
$out .= "    require_once(__DIR__ . '/lib/setup.php');\n";
$out .= "}\n\n";
$out .= "// There is no php closing tag in this file,\n";
$out .= "// it is intentional because it prevents trailing whitespace problems!\n";

$target = $root . '/config.php';
$tmp    = $target . '.tmp';

if (file_put_contents($tmp, $out) === false) {
    fwrite(STDERR, "Cannot write {$tmp}\n");
    exit(1);
}
chown($tmp, 'root');
chgrp($tmp, 'www-data');
chmod($tmp, 0640);
rename($tmp, $target);

echo "Wrote {$target}\n";
