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
 * 可选本地配置：checkm8-config.local.php
 * return [
 *   'github_repo' => 'sitzising/checkm8-ramdisk',
 *   'github_tag'  => 'latest', // 或 ramdisk-20260802-0102
 *   'mirrors'     => ['https://ghfast.top/','https://gh-proxy.com/'],
 *   'pull_enabled'=> true,
 * ];
 */
function load_checkm8_cfg() {
    static $cfg = null;
    if ($cfg !== null) return $cfg;
    $cfg = [
        'github_repo' => 'sitzising/checkm8-ramdisk',
        'github_tag' => 'latest',
        'mirrors' => [
            // 大陆常见 GitHub 加速（服务端拉取用；客户端永不直连 GitHub）
            'https://ghfast.top/',
            'https://gh-proxy.com/',
            'https://mirror.ghproxy.com/',
        ],
        'pull_enabled' => true,
    ];
    $local = __DIR__ . '/checkm8-config.local.php';
    if (is_file($local)) {
        $extra = include $local;
        if (is_array($extra)) $cfg = array_merge($cfg, $extra);
    }
    return $cfg;
}

function load_gha_index() {
    $path = __DIR__ . '/gha-index.json';
    if (!is_file($path)) return null;
    $j = json_decode(@file_get_contents($path), true);
    return is_array($j) ? $j : null;
}

/**
 * 列出某机型可用版本：本地 zip ∪ gha-index.json（Release 清单）。
 * 客户端：get.php?k=iPhone10.6&list=1
 */
function list_versions_for_product($root, $pt, $ptDot) {
    $set = [];
    $local = [];
    foreach ([$pt, $ptDot] as $name) {
        $dir = $root . '/' . $name;
        if (!is_dir($dir)) continue;
        foreach (glob($dir . '/*.zip') ?: [] as $z) {
            $b = basename($z, '.zip');
            if ($b === 'default' || $b === $pt || $b === $ptDot) continue;
            if (preg_match('/^[\d]+(?:\.[\d]+)*$/', $b)) {
                $set[$b] = true;
                $local[$b] = true;
            }
        }
    }
    $idx = load_gha_index();
    $fromIndex = [];
    if ($idx && !empty($idx['devices'])) {
        foreach ([$pt, $ptDot, str_replace('.', ',', $ptDot)] as $key) {
            if (empty($idx['devices'][$key]['versions'])) continue;
            foreach ($idx['devices'][$key]['versions'] as $v) {
                $v = trim((string)$v);
                if ($v === '') continue;
                $set[$v] = true;
                $fromIndex[$v] = true;
            }
            break;
        }
    }
    $vers = array_keys($set);
    usort($vers, function ($a, $b) { return version_compare($b, $a); });
    return [$vers, $local, $fromIndex];
}

/**
 * 服务端从 GitHub Release（经镜像）拉取并缓存到 ramdisks/{pt}/{ios}.zip。
 * 用户侧只访问 tool.a-cheng.cn，不直连 GitHub。
 */
function github_release_asset_urls($ptDot, $ios) {
    $cfg = load_checkm8_cfg();
    $repo = $cfg['github_repo'];
    $tag = $cfg['github_tag'] ?: 'latest';
    $file = $ptDot . '-' . $ios . '.zip';
    if ($tag === 'latest') {
        $origin = "https://github.com/{$repo}/releases/latest/download/{$file}";
    } else {
        $origin = "https://github.com/{$repo}/releases/download/{$tag}/{$file}";
    }
    $urls = [];
    foreach (($cfg['mirrors'] ?? []) as $m) {
        $m = rtrim((string)$m, '/') . '/';
        // 常见镜像：prefix + 完整 https://github.com/...
        $urls[] = $m . $origin;
    }
    $urls[] = $origin;
    return array_values(array_unique($urls));
}

function http_download_to($url, $dest, $timeout = 600) {
    $dir = dirname($dest);
    if (!is_dir($dir)) @mkdir($dir, 0755, true);
    $tmp = $dest . '.part.' . getmypid();
    if (function_exists('curl_init')) {
        $fp = fopen($tmp, 'wb');
        if (!$fp) return false;
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_FILE => $fp,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS => 8,
            CURLOPT_CONNECTTIMEOUT => 20,
            CURLOPT_TIMEOUT => $timeout,
            CURLOPT_USERAGENT => 'AC-Tools-Checkm8-Baota/1.0',
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_FAILONERROR => false,
        ]);
        $ok = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        fclose($fp);
        if (!$ok || $code < 200 || $code >= 300 || !is_file($tmp) || filesize($tmp) < 1000000) {
            @unlink($tmp);
            return false;
        }
        @rename($tmp, $dest);
        return is_file($dest);
    }
    // fallback
    $ctx = stream_context_create([
        'http' => ['timeout' => $timeout, 'follow_location' => 1, 'user_agent' => 'AC-Tools-Checkm8-Baota/1.0'],
        'ssl' => ['verify_peer' => true, 'verify_peer_name' => true],
    ]);
    $data = @file_get_contents($url, false, $ctx);
    if ($data === false || strlen($data) < 1000000) return false;
    if (@file_put_contents($tmp, $data) === false) return false;
    @rename($tmp, $dest);
    return is_file($dest);
}

function pull_github_release_zip($root, $pt, $ptDot, $ios) {
    $cfg = load_checkm8_cfg();
    if (empty($cfg['pull_enabled'])) return null;
    if ($ios === '' || !preg_match('/^[\d]+(?:\.[\d]+)*$/', $ios)) return null;

    $dest = $root . '/' . $ptDot . '/' . $ios . '.zip';
    if (is_file($dest) && filesize($dest) > 1000000) return $dest;

    // 锁：同机型同版本并发只拉一次
    $lockFile = sys_get_temp_dir() . '/ac-c8-pull-' . md5($ptDot . '|' . $ios) . '.lock';
    $fh = fopen($lockFile, 'c');
    if ($fh === false) return null;
    if (!flock($fh, LOCK_EX)) {
        fclose($fh);
        return null;
    }
    try {
        if (is_file($dest) && filesize($dest) > 1000000) return $dest;
        foreach (github_release_asset_urls($ptDot, $ios) as $url) {
            if (http_download_to($url, $dest)) {
                return $dest;
            }
        }
        return null;
    } finally {
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

$ecidHex = norm_ecid_hex($ecid);

// 0) 仅列出版本（不下载）
$wantList = !empty($_GET['list']) || !empty($_GET['versions'])
    || (isset($_GET['action']) && strtolower((string)$_GET['action']) === 'list');
if ($wantList) {
    list($vers, $localMap, $indexMap) = list_versions_for_product($root, $pt, $ptDot);
    $defaultIos = $vers[0] ?? '';
    echo json_encode([
        'ok' => true,
        'productType' => $pt,
        'versions' => $vers,
        'defaultIos' => $defaultIos,
        'count' => count($vers),
        'cached' => array_keys($localMap),
        'pullOnDemand' => array_values(array_diff(array_keys($indexMap), array_keys($localMap))),
        'source' => 'baota+gha-index',
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

// 2) 通用机型包（本地缓存）
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

// 3) 本地没有 → 服务端从 GitHub Release（走镜像）拉取并缓存，再给客户端宝塔直链
//    解决：大陆用户无法稳定访问 GitHub
$pulled = pull_github_release_zip($root, $pt, $ptDot, $ios);
if ($pulled) {
    respond_ok($base, $root, $pulled, $pt, $ios, false, [
        'pulledFromGithub' => true,
        'cached' => true,
    ]);
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
list($indexVers) = list_versions_for_product($root, $pt, $ptDot);

http_response_code(200);
echo json_encode([
    'ok' => false,
    'error' => 'ramdisk not found',
    'productType' => $pt,
    'ios' => $ios,
    'ecid' => $ecidHex,
    'available' => $available,
    'indexVersions' => $indexVers,
    'hint' => '本地无包且服务端拉取 GitHub Release 失败。请上传 gha-index.json/PHP，或检查服务器出网/镜像',
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
