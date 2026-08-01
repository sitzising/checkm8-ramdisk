# 宝塔上传包（重做版）

> **不要用 CentOS 7。** SSHRD 自带 `pzb` 需要新版 `libstdc++`，CentOS 7 跑不通。  
> **请用 Ubuntu 22.04 LTS** 新开云服务器，安装宝塔后再上传本目录。

---

## 一、服务器要求

| 项目 | 要求 |
|------|------|
| 系统 | **Ubuntu 22.04**（首选）/ 20.04 / Debian 11–12 / Rocky·Alma 8+ |
| 面板 | 宝塔 Linux |
| 磁盘 | checkm8 全量建议 **≥ 80GB**（构建时下 IPSW，完成后脚本会删） |
| 域名站点 | `tool.a-cheng.cn` 根目录建议：`/www/wwwroot/tool.a-cheng.cn/` |

**明确不支持：** CentOS 7 / RHEL 7。

---

## 二、上传什么

把本仓库整个目录：

```
Scripts/baota/
```

上传到服务器任意位置均可（例如先传到 `/tmp/baota`），然后执行部署脚本。

本包文件清单：

| 文件 | 作用 |
|------|------|
| `00-deploy.sh` | **最先跑**：创建站点目录 + 部署 PHP |
| `install-deps.sh` | 装 git/curl/zip/python3 等 |
| `build-checkm8.sh` | X 以下云端批量构建 SSHRD → zip |
| `publish-a12.sh` | A12 ICH 文件夹 → zip |
| `checkm8-ramdisk.php` | checkm8 下载 API |
| `a12-ramdisk.php` | A12 下载 API |
| `_os_check.sh` | 拒绝 CentOS 7 |

---

## 三、宝塔站点目录（自动创建）

```
/www/wwwroot/tool.a-cheng.cn/
  ramdisk/
    a12-down/
      Scripts/baota/
      incoming/          ← 上传 ICH 原始包
      ramdisks/          ← 对外 zip
      ramdisk.php
    checkm8-down/
      Scripts/baota/
      build/             ← SSHRD 源码与临时
      ramdisks/          ← 对外 zip
      ramdisk.php
```

客户端地址（勿改路径，与程序内配置一致）：

- A12：`https://tool.a-cheng.cn/ramdisk/a12-down/`
- checkm8：`https://tool.a-cheng.cn/ramdisk/checkm8-down/`

---

## 四、SSH 一键流程

```bash
# 1) 进入你上传的 baota 目录
cd /path/to/Scripts/baota
chmod +x *.sh

# 2) 创建目录 + 拷 PHP（会同步到 a12-down / checkm8-down）
bash 00-deploy.sh

# 3) 装依赖
bash /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/Scripts/baota/install-deps.sh
```

### A12 / A13（打 zip，不从 IPSW 编译）

```bash
# 宝塔文件管理：把 ICH 文件夹上传到
#   /www/wwwroot/tool.a-cheng.cn/ramdisk/a12-down/incoming/iPad11,1/
# 文件夹内至少要有: iBoot.patched.bin, ramdisk.img4, kernelcache.img4 …

cd /www/wwwroot/tool.a-cheng.cn/ramdisk/a12-down/Scripts/baota
bash publish-a12.sh

# 测试
curl -s "https://tool.a-cheng.cn/ramdisk/a12-down/ramdisk.php?key=iPad11,1"
```

### iPhone X 及以下（云端生成）

先小范围验证：

```bash
cd /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/Scripts/baota
ONLY_PRODUCTS="iPhone10,6" ONLY_IOS="15.7.1" bash build-checkm8.sh

# 或单条：
bash build-checkm8.sh iPhone10,6 15.7.1

# 8 Plus 示例（构建时会自动把 0x8015.shsh 的 BORD 改成 0x4）
bash build-checkm8.sh iPhone10,2 16.0

# 按本机 ECID 个性化（客户端 get.php?ecid=… 会自动调）
bash personalize-ramdisk.sh iPhone10,2 16.0 000C6D3A0160002E 4
# 产出: ramdisks/by-ecid/{ECID}/iPhone10,2/16.0.zip
```

**重要：** SSHRD Lite 自带的 `0x8015.shsh` 票证是 X 的（BORD=6、ECID=0x2131312312）。  
构建/个性化脚本会按机型改写 **BORD**；带 `ecid` 请求时再尝试写入本机 ECID。

确认成功后再全量：

```bash
bash build-checkm8.sh
```

说明：

- 自动查 [ipsw.me](https://api.ipsw.me)，**该机型没有的版本会跳过**（不是失败）
- 每完成一个：打 `ramdisks/{ProductType}/{ios}.zip`，并 **删除 IPSW**
- 已有 zip 默认跳过：`SKIP_EXISTING=1`
- Linux **不要用 16.1+**，默认列表最高到 16.0.x

测试：

```bash
curl -s "https://tool.a-cheng.cn/ramdisk/checkm8-down/ramdisk.php?productType=iPhone10,6&ios=15.7.1"
```

---

## 五、从 CentOS 7 迁出（你现在的情况）

1. 新买 / 重装 **Ubuntu 22.04** 云主机  
2. 安装宝塔，绑定 `tool.a-cheng.cn`（或解析到新 IP）  
3. 上传本 `Scripts/baota`，按上面「四、SSH 一键流程」执行  
4. 旧 CentOS 7 机器可废弃，不要再在上面硬跑 SSHRD  

---

## 六、宝塔计划任务（可选）

- A12 每天同步发布：

```bash
cd /www/wwwroot/tool.a-cheng.cn/ramdisk/a12-down/Scripts/baota && bash publish-a12.sh
```

- checkm8 全量很慢，建议 SSH 手动跑，或只定时补缺：

```bash
cd /www/wwwroot/tool.a-cheng.cn/ramdisk/checkm8-down/Scripts/baota && bash build-checkm8.sh
```

---

## 七、GitHub Actions（离线构建）

工作流：`.github/workflows/build-checkm8-ramdisk.yml`  
基于 **SSHRD_Script_Lite**（不下载 gaster，避免旧 SSHRD 解压失败）。

覆盖节点（非逐小版本）：`11.4.1` → `12.4.1` / `12.5.7` → `13.7` → `14.0` → `15.0` → `16.0` → `16.7.8`（X 最高区间）。  
无固件组合自动跳过；`16.7.8` 需 APFS，Linux runner 默认 skip（勾选 `force_apfs` 可强试）。

操作：仓库 **Actions → Build Checkm8 Ramdisks → Run workflow**

1. 先 `scope=smoke` 验证  
2. 再 `scope=a11`（8/8+/X）或 `scope=all`（A7–A11）  
3. 产物在 Artifacts：`ramdisk-*` 与汇总包 `checkm8-ramdisks-bundle`  
