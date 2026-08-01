<?php
/**
 * A12/A13 ICH Ramdisk API
 * 部署: /www/wwwroot/tool.a-cheng.cn/ramdisk/a12-down/ramdisk.php
 * 例:   ?key=iPad11,1
 *
 * zip: ramdisks/{key}.zip（兼容逗号/点号）
 */
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');

$key = isset($_GET['key']) ? trim($_GET['key']) : '';
if ($key === '' || preg_match('/[^\w,\.\-]/', $key)) {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'invalid key'], JSON_UNESCAPED_UNICODE);
    exit;
}

$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$host = $_SERVER['HTTP_HOST'] ?? 'tool.a-cheng.cn';
$scriptDir = str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/ramdisk/a12-down'));
$base = $scheme . '://' . $host . rtrim($scriptDir, '/') . '/';
$root = __DIR__ . '/ramdisks';

$candidates = [
    $root . '/' . $key . '.zip',
    $root . '/' . str_replace(',', '.', $key) . '.zip',
    $root . '/' . str_replace('.', ',', $key) . '.zip',
];

foreach ($candidates as $path) {
    if (is_file($path)) {
        echo json_encode([
            'ok' => true,
            'key' => $key,
            'url' => $base . 'ramdisks/' . basename($path),
            'size' => filesize($path),
        ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        exit;
    }
}

http_response_code(404);
echo json_encode([
    'ok' => false,
    'error' => 'not found',
    'hint' => '上传 ICH 到 incoming/ 后执行 publish-a12.sh',
    'looked' => array_map('basename', $candidates),
], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
