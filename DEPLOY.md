# Hermes Lite 2 —— 魔塔（ModelScope）Docker 空间部署单

一个自包含的 Hermes Agent 容器镜像：Python 3.11 + Hermes v2026.8.3 源码安装 +
SQLite(FTS5) + ttyd Web Shell + cloudflared tunnel + Dashboard，可选远程访问。

与上游 `kakaw-1/herm_lite` 的区别：**没有 rclone 实时镜像、没有 S3/WebDAV 往返、
没有 inotify 守护**。数据在本地盘运行，网络盘只当一个 tar 包的仓库。

---

## 1. 数据模型（唯一需要理解的一件事）

```
本地盘 /root/.hermes          ← 运行期全部读写都在这里，性能零损失
网络盘 /mnt/workspace/hermes-snapshot/hermes.tar.gz   ← 唯一一份快照，每天覆盖
```

**开机**（`/bz/boot_restore.sh`，由 entrypoint 在 gateway 之前调用）：

| 网络盘状态 | 行为 |
|---|---|
| 有 `hermes.tar.gz` 且 `gzip -t` 通过 | 解包覆盖 `/root`，用打包时的状态启动 |
| 没有 / 小于 1 KB / 校验失败 / 盘未挂载 | 什么都不做，空 `~/.hermes` 原生首启 |

没有"种子包"、没有一次性注入、不区分首次与再次开机。首启建好的东西在下一次
05:00 打包之后，就自然成为后续开机的恢复源。

**每天北京时间 05:00**（`/bz/snap_daily.sh --daemon`，entrypoint 后台拉起，
不依赖 Hermes cron）：

1. `sqlite3 state.db ".backup"` 在线冷备（WAL 下直接 copy 会撕裂）
2. `tar` 打包 `~/.hermes` + `~/bz-startup`，排除可重建物
3. `gzip -1` → 写 `hermes.tar.gz.tmp` → `gzip -t` 校验 → `mv` 原子改名

只保留单份，不轮转。包内是明文 `.env` / `auth.json`，网络盘权限请自行管控。

**打包排除**（全部可重建，实测载荷约 525 MB → 压缩后约 400 MB）：

```
scripts/profiles  scripts/weights  scripts/tmp  scripts/__pycache__
venvs  camoufox_profiles  bin  lsp  logs  shots
cache  audio_cache  image_cache  deploy/resin/data/log
state.db(-wal/-shm)  *.pyc        ← state.db 用冷备件替代
```

---

## 2. 构建镜像

推送到 `main` 分支即由 GitHub Actions 构建并推 GHCR：

```
ghcr.io/kakaw-1/herm-lite2:latest
ghcr.io/kakaw-1/herm-lite2:sha-<commit>
```

工作流：`.github/workflows/docker-build.yml`（buildx，`linux/amd64`）。
Dockerfile 里对每个 shell 脚本都跑了 `bash -n`，语法错误会在构建阶段就红掉。

---

## 3. 建魔塔空间

控制台 → 创空间 → **Docker 类型**：

- 镜像：`ghcr.io/kakaw-1/herm-lite2:latest`
- 端口：**7860**（硬性，`health_server.py` 绑 `0.0.0.0:7860`，它是容器生命周期锚点）
- 规格：`platform/2v-cpu-16g-mem`（2 vCPU / 16 GiB）
- 参见 `ms_deploy.json`

### 必须注入的环境变量

| 变量 | 说明 |
|---|---|
| `HEALTH_PASSWORD` | 7860 状态页口令（不设则状态页任意访问） |
| `HERMES_DASHBOARD` | `1` 启用 Dashboard |
| `HERMES_DASHBOARD_PORT` | 默认 `9119`，不要设成 7860 |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` / `_SECRET` | Dashboard 基础认证 |
| `WEB_SHELL_USER` / `WEB_SHELL_PASSWORD` | 启用 ttyd Web Shell（可选） |
| `CF_TUNNEL_TOKEN` / `CF_TUNNEL_PROTOCOL` | 启用 cloudflared（可选，见下） |

**不要设**：`S3_KEY_ID`、`S3_ACCESS_KEY`、`S3_BUCKET`、`S3_ENDPOINT`、
`S3_BACKUP_PATH`、`BACKUP_ENC_PASS`、`RESTORE_SOURCE`——本镜像已无任何代码读它们。

`SKIP_RESTORE=1` 仅作强制跳过开机恢复的手动用，平时不需要。

### CF 隧道注意

**不要复用旧容器的 `CF_TUNNEL_TOKEN`。** 同一个 token 在两台机器上连接等于同一条
tunnel 的两个副本，Cloudflare 会把请求随机分给其中一个，域名会串台。要对外访问就在
CF 控制台新建一条 tunnel + 新 hostname，把新 token 填进来；不需要就留空，7860 状态页
和 `HERMES_DASHBOARD_PORT`（默认 9119）的 Dashboard 已经够用。

---

## 4. 首次开机后

```bash
# 看恢复有没有跑、拿到了什么
cat /tmp/hermes-restore.log

# 看每日快照守护
tail -20 /tmp/hermes-snapshot.log

# 手动立刻打一次包（不等到 05:00）
/bz/snap_daily.sh

# 手动立刻恢复一次
/bz/boot_restore.sh
```

首启是空实例：没有 SOUL.md、没有技能、没有记忆、没有历史会话。模型 key 与渠道配置
通过控制台 env + `~/.hermes/.env` 建立。

---

## 5. 已知边界

- 网络盘（ossfs）小文件性能极差：建文件约 7 个/秒、遍历 `skills/` 的 954 个文件 13.9 s。
  所以它只能当 tar 仓库，不能当活目录；`mount --bind` 也不可用（缺 `CAP_SYS_ADMIN`）。
- 顺序读写正常：写约 31 MB/s，读约 42 MB/s。一个 400 MB 的包写进去约 15 s，
  开机读回 + 解包约 20 s。
- 恢复是**覆盖**不是清空：包内同名文件覆盖，本地多出来的文件会留着。
- gateway 只启动一次、不自动拉起（与旧镜像一致）：`/entrypoint.sh` 里
  `"$@" &` 后不再 supervisor；`health_server.py` 是唯一决定容器生死的进程。
