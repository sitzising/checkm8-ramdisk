<?php
/**
 * checkm8 Ramdisk API
 *
 * 兼容:
 *   ?productType=iPhone10,2&ios=16.0
 *   ?k=iPhone10.2/16.0
 *   ?k=iPhone10.2/16.0&ecid=000C6D3A0160002E&bdid=4   ← 按本机个性化
 *
 * 部署: /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/ramdisk.php
 */
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');

$raw = trim($_GET['k'] ?? $_GET['pack'] ?? '');
if ($raw !== '' && strpos($raw, '/') !== false) {
    $parts = explode('/', str_replace(',', '.', $raw), 2);
    $pt = $parts[0] ?? '';
    $ios = $parts[1] ?? '';
} else {
    $pt = trim($_GET['rd'] ?? $_GET['dev'] ?? $_GET['pt'] ?? $_GET['model'] ?? $_GET['productType'] ?? $_POST['rd'] ?? $_POST['productType'] ?? $_POST['pt'] ?? $raw);
    $ios = trim($_GET['ios'] ?? $_POST['ios'] ?? '');
}

$ecid = trim($_GET['ecid'] ?? $_GET['ECID'] ?? $_POST['ecid'] ?? '');
$bdid = trim($_GET['bdid'] ?? $_GET['BDID'] ?? $_GET['bord'] ?? $_POST['bdid'] ?? '');

if ($pt !== '' && preg_match('/^(iPhone|iPad|iPod)(\d+)\.(\d+)/i', $pt)) {
    $pt = preg_replace('/^(iPhone|iPad|iPod)(\d+)\.(\d+)/i', '$1$2,$3', $pt);
}

if ($pt === '' || preg_match('/[^\w,\.\-]/', $pt)) {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'invalid productType'], JSON_UNESCAPED_UNICODE);
    exit;
}

$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$host = $_SERVER['HTTP_HOST'] ?? 'tool.a-cheng.cn';
$scriptDir = str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/ramdisk/checkm8-down'));
$base = $scheme . '://' . $host . rtrim($scriptDir, '/') . '/';
$root = __DIR__ . '/ramdisks';
$ptDot = str_replace(',', '.', $pt);

function norm_ecid_hex($ecid) {
    $s = strtoupper(trim($ecid));
    if (strpos($s, '0X') === 0) $s = substr($s, 2);
    $s = preg_replace('/[^0-9A-F]/', '', $s);
    if ($s === '') return '';
    if (strlen($s) < 16) $s = str_pad($s, 16, '0', STR_PAD_LEFT);
    if (strlen($s) > 16) $s = substr($s, -16);
    return $s;
}

function respond_ok($base, $root, $path, $pt, $ios, $fallback = false, $extra = []) {
    $rel = 'ramdisks/' . ltrim(str_replace('\\', '/', substr($path, strlen($root))), '/');
    $matched = basename($path, '.zip');
    if ($matched === 'default' || $matched === $pt || $matched === str_replace(',', '.', $pt)) {
        $dir = dirname($path);
        $vers = glob($dir . '/*.zip') ?: [];
        $pick = '';
        foreach ($vers as $z) {
            $b = basename($z, '.zip');
            if ($b !== 'default' && $b !== $pt && $b !== str_replace(',', '.', $pt)) {
                $pick = $b;
                break;
            }
        }
        $matched = $pick !== '' ? $pick : 'default';
        $fallback = true;
    }
    $payload = array_merge([
        'ok' => true,
        'productType' => $pt,
        'ios' => $ios,
        'matchedIos' => $matched,
        'fallback' => $fallback,
        'url' => $base . $rel,
        'downloadUrl' => $base . $rel,
        'size' => @filesize($path),
    ], $extra);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function find_generic_zip($root, $pt, $ptDot, $ios) {
    $candidates = [];
    foreach ([$pt, $ptDot] as $name) {
        if ($ios !== '' && preg_match('/^[\d\.]+$/', $ios)) {
            $candidates[] = $root . '/' . $name . '/' . $ios . '.zip';
        }
        $candidates[] = $root . '/' . $name . '/default.zip';
        $candidates[] = $root . '/' . $name . '.zip';
    }
    foreach ($candidates as $path) {
        if (is_file($path)) return $path;
    }
    foreach ([$pt, $ptDot] as $name) {
        $dir = $root . '/' . $name;
        if (!is_dir($dir)) continue;
        $zips = glob($dir . '/*.zip') ?: [];
        usort($zips, function ($a, $b) {
            $va = basename($a, '.zip');
            $vb = basename($b, '.zip');
            if ($va === 'default') return 1;
            if ($vb === 'default') return -1;
            return version_compare($vb, $va);
        });
        if (!empty($zips)) return $zips[0];
    }
    return null;
}

/**
 * 按 ECID 个性化：优先缓存；否则调用 personalize-ramdisk.sh（需基础包已存在）。
 */
function try_personalized($root, $base, $pt, $ptDot, $ios, $ecidHex, $bdid) {
    if ($ecidHex === '') return null;

    $cacheCandidates = [];
    if ($ios !== '') {
        $cacheCandidates[] = $root . '/by-ecid/' . $ecidHex . '/' . $pt . '/' . $ios . '.zip';
        $cacheCandidates[] = $root . '/by-ecid/' . $ecidHex . '/' . $ptDot . '/' . $ios . '.zip';
    }
    $cacheCandidates[] = $root . '/by-ecid/' . $ecidHex . '/' . $pt . '/default.zip';
    $cacheCandidates[] = $root . '/by-ecid/' . $ecidHex . '/' . $ptDot . '/default.zip';
    foreach ($cacheCandidates as $path) {
        if (is_file($path) && filesize($path) > 1000) {
            return ['path' => $path, 'built' => false];
        }
    }

    // 无缓存 → 现场个性化（短锁，避免并发打爆）
    $script = __DIR__ . '/Scripts/baota/personalize-ramdisk.sh';
    if (!is_file($script)) {
        $script = __DIR__ . '/personalize-ramdisk.sh';
    }
    if (!is_file($script)) {
        return null;
    }

    $lockDir = sys_get_temp_dir();
    $lockFile = $lockDir . '/ac-c8-pers-' . $ecidHex . '-' . md5($pt . '|' . $ios) . '.lock';
    $fh = fopen($lockFile, 'c');
    if ($fh === false) return null;
    if (!flock($fh, LOCK_EX)) {
        fclose($fh);
        return null;
    }

    try {
        // 双检缓存
        foreach ($cacheCandidates as $path) {
            if (is_file($path) && filesize($path) > 1000) {
                return ['path' => $path, 'built' => false];
            }
        }

        $cmd = 'bash ' . escapeshellarg($script) . ' '
            . escapeshellarg($pt) . ' '
            . escapeshellarg($ios !== '' ? $ios : 'default') . ' '
            . escapeshellarg($ecidHex);
        if ($bdid !== '') {
            $cmd .= ' ' . escapeshellarg($bdid);
        }
        $cmd .= ' 2>&1';

        $out = [];
        $code = 0;
        exec($cmd, $out, $code);
        $logLine = trim(implode("\n", array_slice($out, -20)));

        foreach ($cacheCandidates as $path) {
            if (is_file($path) && filesize($path) > 1000) {
                return ['path' => $path, 'built' => true, 'log' => $logLine, 'code' => $code];
            }
        }
        // 脚本可能用了 default ios 名
        $guess = $root . '/by-ecid/' . $ecidHex . '/' . $pt . '/' . ($ios !== '' ? $ios : 'default') . '.zip';
        if (is_file($guess)) {
            return ['path' => $guess, 'built' => true, 'log' => $logLine, 'code' => $code];
        }
        return ['path' => null, 'built' => false, 'log' => $logLine, 'code' => $code];
    } finally {
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

/**
 * 列出某机型云端已上传的通用包版本（扫 ramdisks/{pt}/*.zip）。
 * 客户端：get.php?k=iPhone10.6&list=1
 */
function list_versions_for_product($root, $pt, $ptDot) {
    $set = [];
    foreach ([$pt, $ptDot] as $name) {
        $dir = $root . '/' . $name;
        if (!is_dir($dir)) continue;
        foreach (glob($dir . '/*.zip') ?: [] as $z) {
            $b = basename($z, '.zip');
            if ($b === 'default' || $b === $pt || $b === $ptDot) continue;
            if (preg_match('/^[\d]+(?:\.[\d]+)*$/', $b)) $set[$b] = true;
        }
    }
    $vers = array_keys($set);
    usort($vers, function ($a, $b) { return version_compare($b, $a); });
    return $vers;
}

$ecidHex = norm_ecid_hex($ecid);

// 0) 仅列出版本（不下载）
$wantList = !empty($_GET['list']) || !empty($_GET['versions'])
    || (isset($_GET['action']) && strtolower((string)$_GET['action']) === 'list');
if ($wantList) {
    $vers = list_versions_for_product($root, $pt, $ptDot);
    $defaultIos = $vers[0] ?? '';
    echo json_encode([
        'ok' => true,
        'productType' => $pt,
        'versions' => $vers,
        'defaultIos' => $defaultIos,
        'count' => count($vers),
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

// 1) 有 ECID → 走个性化包
if ($ecidHex !== '') {
    $pers = try_personalized($root, $base, $pt, $ptDot, $ios, $ecidHex, $bdid);
    if (is_array($pers) && !empty($pers['path']) && is_file($pers['path'])) {
        respond_ok($base, $root, $pers['path'], $pt, $ios, false, [
            'personalized' => true,
            'ecid' => $ecidHex,
            'bdid' => $bdid,
            'builtNow' => !empty($pers['built']),
        ]);
    }
    // 个性化失败时回落通用包，并带警告
}

// 2) 通用机型包
$path = find_generic_zip($root, $pt, $ptDot, $ios);
if ($path) {
    $extra = [];
    if ($ecidHex !== '') {
        $extra['personalized'] = false;
        $extra['ecid'] = $ecidHex;
        $extra['warning'] = 'personalized build unavailable; serving generic CPID ticket (checkm8 OK if BORD patched on server builds)';
    }
    respond_ok($base, $root, $path, $pt, $ios, false, $extra);
}

$available = [];
if (is_dir($root)) {
    foreach (glob($root . '/*', GLOB_ONLYDIR) ?: [] as $d) {
        $name = basename($d);
        if ($name === 'by-ecid') continue;
        $vs = [];
        foreach (glob($d . '/*.zip') ?: [] as $z) $vs[] = basename($z, '.zip');
        if ($vs) $available[$name] = $vs;
    }
}

http_response_code(200);
echo json_encode([
    'ok' => false,
    'error' => 'ramdisk not found',
    'productType' => $pt,
    'ios' => $ios,
    'ecid' => $ecidHex,
    'available' => $available,
    'hint' => '云端尚无该机型包，请先 build-checkm8.sh',
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
