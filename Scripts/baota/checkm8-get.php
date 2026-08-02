<?php
/**
 * 推荐入口：
 *   get.php?k=iPhone10.2/16.0&ecid=...&bdid=4   → 解析下载 URL（缺包时服务端镜像拉 GitHub 并缓存）
 *   get.php?k=iPhone10.6&list=1                 → 列出可用版本（本地 zip ∪ gha-index.json）
 * 部署到: /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/get.php
 * 同目录还需: ramdisk.php, gha-index.json（从 Release 下载）
 */
header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
$raw = trim($_GET['k'] ?? $_GET['q'] ?? $_GET['x'] ?? $_GET['pack'] ?? '');
if ($raw === '') {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'missing k=Product.ios']);
    exit;
}
$parts = explode('/', str_replace(',', '.', $raw), 2);
$pt = $parts[0] ?? '';
$ios = $parts[1] ?? '';
if ($pt !== '' && preg_match('/^(iPhone|iPad|iPod)(\d+)\.(\d+)/i', $pt)) {
    $pt = preg_replace('/^(iPhone|iPad|iPod)(\d+)\.(\d+)/i', '$1$2,$3', $pt);
}
$_GET['rd'] = $pt;
$_GET['productType'] = $pt;
$_GET['ios'] = $ios;
// ecid / bdid 原样保留在 $_GET，由 ramdisk.php 读取
include __DIR__ . '/ramdisk.php';
