# Checkm8 Ramdisk（GitHub Actions）

用 **SSHRD_Script_Lite** 在 GitHub 上离线构建 A7–A11 SSH Ramdisk（不依赖 gaster）。

## 跑构建

1. 打开仓库 **Actions** → **Build Checkm8 Ramdisks** → **Run workflow**
2. 第一次选 `scope=smoke`
3. 成功后再选 `scope=a11`（8/8+/X）或 `scope=all`（A7–A11）
4. 在 Artifacts 下载 zip

覆盖节点：`11.4.1` → `12.4.1` / `12.5.7` → `13.7` → `14.0` → `15.0` → `16.0` → `16.7.8`（X 最高；Linux 默认 skip APFS）
