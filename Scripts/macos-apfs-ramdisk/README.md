# macOS · iOS 16.4 / 16.7 APFS Ramdisk

Linux/Docker 无法构建 iOS **16.1+**（APFS）。本目录在 **macOS** 上原生跑 [SSHRD_Script_Lite](https://github.com/mast3rz3ro/SSHRD_Script_Lite)。

## GitHub Actions（推荐）

仓库：**Actions → Build Checkm8 APFS (macOS)**

- `smoke=true`：先打 `iPhone10,6 @ 16.7.8`
- `smoke=false`：按 `pairs.txt`（A11 × 16.4/16.7.8 + 部分 iPad 16.4）
- 默认发布到 `ramdisk-20260802-0102`

## 本地 Mac

```bash
chmod +x build.sh
./build.sh iPhone10,6 16.7.8
./build.sh iPhone10,1 16.4
./build.sh   # 读 pairs.txt
```

产物：`~/checkm8-ramdisk-mac/ramdisks/iPhone10.6-16.7.8.zip`
