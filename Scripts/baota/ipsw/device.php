<?php
/**
 * IPSW 固件列表中转（给国内客户端用）
 * 部署到：/www/wwwroot/tool.a-cheng.cn/ipsw/device.php
 * 请求：  GET /ipsw/device.php?id=iPhone10,2
 *
 * 服务器能访问 api.ipsw.me 时，把 JSON 缓存到本地再返回，避免用户电脑直连超时。
 */
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Cache-Control: public, max-age=1800');

$id = isset($_GET['id']) ? trim($_GET['id']) : '';
if (!preg_match('/^iP(hone|ad|od)[0-9]+,[0-9]+$/i', $id)) {
    http_response_code(400);
    echo json_encode(['error' => 'bad device id', 'hint' => 'id like iPhone10,2'], JSON_UNESCAPED_UNICODE);
    exit;
}

$cacheDir = __DIR__ . '/cache';
if (!is_dir($cacheDir)) {
    @mkdir($cacheDir, 0755, true);
}
$cacheFile = $cacheDir . '/' . str_replace(',', '_', $id) . '.json';
$cacheTtl = 6 * 3600; // 6 小时

if (is_file($cacheFile) && (time() - filemtime($cacheFile)) < $cacheTtl) {
    readfile($cacheFile);
    exit;
}

$upstream = 'https://api.ipsw.me/v4/device/' . rawurlencode($id);
$ctx = stream_context_create([
    'http' => [
        'method'  => 'GET',
        'timeout' => 60,
        'header'  => "User-Agent: AC-Tools-IpswProxy/1.0\r\nAccept: application/json\r\n",
    ],
    'ssl' => [
        'verify_peer'      => true,
        'verify_peer_name' => true,
    ],
]);

$json = @file_get_contents($upstream, false, $ctx);
if ($json === false || strlen($json) < 32 || stripos($json, 'firmwares') === false) {
    // 上游失败：若有过期缓存也先顶上
    if (is_file($cacheFile)) {
        readfile($cacheFile);
        exit;
    }
    http_response_code(502);
    echo json_encode([
        'error'   => 'upstream failed',
        'message' => '无法从 api.ipsw.me 获取固件列表',
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

@file_put_contents($cacheFile, $json);
echo $json;
