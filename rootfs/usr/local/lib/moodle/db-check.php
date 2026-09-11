<?php
// Reports the state of the Moodle database via the exit code:
//   0 = Moodle is installed
//   1 = database reachable but empty (fresh install needed)
//   2 = cannot connect
//   3 = partial install (config table exists but no version)
declare(strict_types=1);

function env(string $name, string $default = ''): string {
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

$type   = env('MOODLE_DB_TYPE', 'mariadb');
$host   = env('MOODLE_DB_HOST', '127.0.0.1');
$port   = (int) env('MOODLE_DB_PORT', $type === 'pgsql' ? '5432' : '3306');
$name   = env('MOODLE_DB_NAME', 'moodle');
$user   = env('MOODLE_DB_USER', 'moodle');
$pass   = env('MOODLE_DB_PASSWORD');
$table  = env('MOODLE_DB_PREFIX', 'mdl_') . 'config';

try {
    if ($type === 'pgsql') {
        $q = static fn(string $v): string => "'" . addcslashes($v, "'\\") . "'";
        $conn = @pg_connect(sprintf('host=%s port=%d dbname=%s user=%s password=%s connect_timeout=5',
            $q($host), $port, $q($name), $q($user), $q($pass)));
        if (!$conn) {
            exit(2);
        }
        $res = @pg_query_params($conn,
            'SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1', [$table]);
        if (!$res) {
            exit(2);
        }
        if (pg_num_rows($res) === 0) {
            exit(1);
        }
        $res = @pg_query_params($conn,
            'SELECT value FROM ' . pg_escape_identifier($conn, $table) . ' WHERE name = $1', ['version']);
        exit(($res && pg_num_rows($res) > 0) ? 0 : 3);
    }

    mysqli_report(MYSQLI_REPORT_OFF);
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 5);
    if (!@$db->real_connect($host, $user, $pass, $name, $port)) {
        exit(2);
    }
    $stmt = $db->prepare('SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?');
    if (!$stmt) {
        exit(2);
    }
    $stmt->bind_param('s', $table);
    $stmt->execute();
    $stmt->store_result();
    if ($stmt->num_rows === 0) {
        exit(1);
    }
    $res = $db->query('SELECT value FROM `' . str_replace('`', '``', $table) . "` WHERE name = 'version'");
    exit(($res && $res->num_rows > 0) ? 0 : 3);
} catch (Throwable $e) {
    fwrite(STDERR, 'Database check failed: ' . $e->getMessage() . "\n");
    exit(2);
}
