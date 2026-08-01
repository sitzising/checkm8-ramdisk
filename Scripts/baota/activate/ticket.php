<?php
/**
 * AC-Tools A12/A13 正式激活票据接口
 * 部署：/www/wwwroot/tool.a-cheng.cn/ramdisk/activate/ticket.php
 *
 * GET: ticket.php?ecid=XXXXXXXX&serial=&udid=&productType=
 *
 * 票据放置（任选）：
 *   tickets/{ECID}.zip
 *   tickets/{ECID}/activation_records/activation_record.plist
 *   tickets/{ECID}/activation_record.plist
 *   tickets/{ECID}/data_ark.plist
 *   tickets/{ECID}/IC-Info.sisv 或 FairPlay/iTunes_Control/iTunes/IC-Info.sisv
 *   tickets/{ECID}/IC-Info.sidv
 *   tickets/{ECID}/com.apple.commcenter.device_specific_nobackup.plist
 *
 * 成功 JSON：
 *   { "ok": true, "ecid": "...", "files": [ { "path": "...", "base64": "..." } ] }
 */
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('Access-Control-Allow-Origin: *');

function respond($arr, $code = 200) {
    http_response_code($code);
    echo json_encode($arr, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function norm_ecid($e) {
    $e = strtoupper(trim(str_ireplace('0x', '', (string)$e)));
    $e = preg_replace('/[^0-9A-F]/', '', $e);
    return $e;
}

function want_file($rel) {
    $rel = str_replace('\\', '/', $rel);
    $base = strtolower(basename($rel));
    if ($base === 'activation_record.plist') return true;
    if ($base === 'data_ark.plist') return true;
    if ($base === 'pod_record.plist') return true;
    if ($base === 'ic-info.sisv' || $base === 'ic-info.sidv') return true;
    if ($base === 'com.apple.commcenter.device_specific_nobackup.plist') return true;
    return false;
}

function normalize_rel($rel) {
    $rel = str_replace('\\', '/', $rel);
    $rel = ltrim($rel, '/');
    // strip leading junk folders from zip
    if (preg_match('#(?:^|/)(activation_records/.*)$#i', $rel, $m)) $rel = $m[1];
    if (preg_match('#(?:^|/)(FairPlay/.*)$#i', $rel, $m)) $rel = $m[1];
    if (preg_match('#(?:^|/)(Media/iTunes/.*)$#i', $rel, $m)) $rel = $m[1];
    $base = basename($rel);
    if (strcasecmp($base, 'activation_record.plist') === 0
        && stripos($rel, 'activation_records/') === false) {
        $rel = 'activation_records/activation_record.plist';
    }
    if (strcasecmp($base, 'IC-Info.sisv') === 0 && stripos($rel, '/') === false) {
        $rel = 'IC-Info.sisv';
    }
    if (strcasecmp($base, 'IC-Info.sidv') === 0 && stripos($rel, '/') === false) {
        $rel = 'IC-Info.sidv';
    }
    return $rel;
}

function add_file(&$files, $rel, $abs) {
    if (!is_file($abs)) return;
    $rel = normalize_rel($rel);
    if (!want_file($rel)) return;
    // dedupe by path
    foreach ($files as $f) {
        if (strcasecmp($f['path'], $rel) === 0) return;
    }
    $files[] = [
        'path' => $rel,
        'base64' => base64_encode(file_get_contents($abs)),
        'size' => filesize($abs),
    ];
}

function scan_dir_add(&$files, $root, $prefix = '') {
    if (!is_dir($root)) return;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if (!$f->isFile()) continue;
        $full = $f->getPathname();
        $rel = substr($full, strlen($root) + 1);
        if ($prefix !== '') $rel = rtrim($prefix, '/') . '/' . $rel;
        if (want_file($rel)) add_file($files, $rel, $full);
    }
}

$ecid = norm_ecid($_GET['ecid'] ?? '');
if ($ecid === '') {
    respond(['ok' => false, 'message' => 'missing ecid'], 400);
}

$base = __DIR__ . DIRECTORY_SEPARATOR . 'tickets';
$files = [];

// ZIP
$zipPath = $base . DIRECTORY_SEPARATOR . $ecid . '.zip';
if (is_file($zipPath)) {
    $tmp = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'ac_ticket_' . $ecid . '_' . mt_rand();
    @mkdir($tmp, 0777, true);
    $zip = new ZipArchive();
    if ($zip->open($zipPath) === true) {
        $zip->extractTo($tmp);
        $zip->close();
        scan_dir_add($files, $tmp);
    }
}

// Directory layouts
$dir = $base . DIRECTORY_SEPARATOR . $ecid;
add_file($files, 'activation_records/activation_record.plist', $dir . '/activation_records/activation_record.plist');
add_file($files, 'activation_records/activation_record.plist', $dir . '/activation_record.plist');
add_file($files, 'data_ark.plist', $dir . '/data_ark.plist');
add_file($files, 'data_ark.plist', $dir . '/activation_records/data_ark.plist');
add_file($files, 'IC-Info.sisv', $dir . '/IC-Info.sisv');
add_file($files, 'IC-Info.sidv', $dir . '/IC-Info.sidv');
add_file($files, 'FairPlay/iTunes_Control/iTunes/IC-Info.sisv', $dir . '/FairPlay/iTunes_Control/iTunes/IC-Info.sisv');
add_file($files, 'FairPlay/iTunes_Control/iTunes/IC-Info.sidv', $dir . '/FairPlay/iTunes_Control/iTunes/IC-Info.sidv');
add_file($files, 'Media/iTunes/IC-Info.sidv', $dir . '/Media/iTunes/IC-Info.sidv');
add_file($files, 'com.apple.commcenter.device_specific_nobackup.plist', $dir . '/com.apple.commcenter.device_specific_nobackup.plist');
scan_dir_add($files, $dir);

if (count($files) === 0) {
    respond([
        'ok' => false,
        'message' => 'ticket not found for ECID ' . $ecid,
        'hint' => 'put zip or plists under ramdisk/activate/tickets/' . $ecid,
        'need' => [
            'activation_records/activation_record.plist',
            'data_ark.plist (optional)',
            'IC-Info.sisv or IC-Info.sidv (optional but recommended)',
            'com.apple.commcenter.device_specific_nobackup.plist (optional)',
        ],
    ], 404);
}

respond([
    'ok' => true,
    'ecid' => $ecid,
    'count' => count($files),
    'files' => $files,
]);
