#!/bin/bash
# ============================================================
# snap_daily.sh —— 每日快照（覆盖写唯一一份）
#
# 设计要点：
#   * 只保留一份 $SNAP_DIR/hermes.tar.gz，每天覆盖，不轮转、不留旧包。
#   * 先写 .tmp，gzip -t 校验通过后 mv 原子改名 —— 网络盘上永不出现
#     "半个包"，避免开机解到半截数据。
#   * 由 entrypoint.sh 后台拉起（--daemon），不依赖 Hermes cron：
#     新容器首启时 cron 尚未建好，轮询方式零依赖。
#   * state.db 用 sqlite3 .backup 在线冷备后再入包（WAL 下直接 copy 会撕裂）。
#   * 排除的全是可重建物：venv、浏览器、模型权重、Chromium profile、日志。
#     实测载荷约 525 MB，gzip -1 后约 400 MB。
#
# 时间：北京时间 05:00（容器时钟 UTC，故判断 UTC 21 点）
# 用法：
#   snap_daily.sh            # 立刻打一次包（手工测试用）
#   snap_daily.sh --daemon   # 常驻，每 60 秒轮询，到点打包
# ============================================================

SOURCE_ROOT="${SOURCE_ROOT:-/root}"
SNAP_DIR="${SNAP_DIR:-/mnt/workspace/hermes-snapshot}"
SNAP_FILE="$SNAP_DIR/hermes.tar.gz"
SNAP_TMP="$SNAP_FILE.tmp"
STAGE="${STAGE:-/tmp/hermes-snapshot-stage}"
LAST_RUN_FILE="/tmp/.hermes_last_snapshot_date"
LOG=/tmp/hermes-snapshot.log
STATE_DB="$SOURCE_ROOT/.hermes/state.db"
GZIP_LEVEL="${GZIP_LEVEL:-1}"

log_snap() {
    printf '[snap %s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

# ------------------------------------------------------------
# 排除清单：全部可重建，.hermes 里的配置/凭据/人格/记忆/技能/
# 脚本/cron/会话/hindsight 一个都不排除。
# ------------------------------------------------------------
EXCLUDES=(
    --exclude=.hermes/scripts/profiles
    --exclude=.hermes/scripts/weights
    --exclude=.hermes/scripts/tmp
    --exclude=.hermes/scripts/__pycache__
    --exclude=.hermes/venvs
    --exclude=.hermes/camoufox_profiles
    --exclude=.hermes/bin
    --exclude=.hermes/lsp
    --exclude=.hermes/logs
    --exclude=.hermes/shots
    --exclude=.hermes/cache
    --exclude=.hermes/audio_cache
    --exclude=.hermes/image_cache
    --exclude=.hermes/deploy/resin/data/log
    --exclude=.hermes/state.db
    --exclude=.hermes/state.db-wal
    --exclude=.hermes/state.db-shm
    --exclude=*.pyc
)

do_snapshot() {
    log_snap "===== 开始每日快照（目标 $SNAP_FILE）====="

    if [ ! -d "$(dirname "$SNAP_DIR")" ]; then
        log_snap "ERROR: 网络盘 $(dirname "$SNAP_DIR") 不存在，跳过本次快照。"
        return 1
    fi

    mkdir -p "$SNAP_DIR" || { log_snap "ERROR: 无法创建 $SNAP_DIR"; return 1; }

    rm -rf "$STAGE"
    mkdir -p "$STAGE/tree/.hermes" || { log_snap "ERROR: 无法创建暂存目录"; return 1; }

    # --------------------------------------------------------
    # 1) state.db 在线冷备
    # --------------------------------------------------------
    if [ -f "$STATE_DB" ]; then
        if sqlite3 "$STATE_DB" ".backup '$STAGE/tree/.hermes/state.db'" 2>>"$LOG"; then
            log_snap "state.db 冷备完成：$(( $(stat -c %s "$STAGE/tree/.hermes/state.db") / 1024 / 1024 )) MB"
        else
            log_snap "ERROR: state.db 冷备失败，本次放弃打包（不用残缺数据覆盖好包）。"
            rm -rf "$STAGE"
            return 1
        fi
    else
        log_snap "state.db 不存在，跳过（首启尚未建库时属正常）。"
    fi

    # --------------------------------------------------------
    # 2) 打包未压缩 tar：.hermes（排除可重建物）+ bz-startup
    # --------------------------------------------------------
    TAR_RC=0
    tar -cf "$STAGE/hermes.tar" "${EXCLUDES[@]}" \
        -C "$SOURCE_ROOT" .hermes bz-startup 2>>"$LOG" || TAR_RC=$?

    # tar 返回 1 = 打包期间有文件消失（缓存/临时文件），可接受
    if [ "$TAR_RC" -gt 1 ] || [ ! -s "$STAGE/hermes.tar" ]; then
        log_snap "ERROR: tar 失败 rc=$TAR_RC，保留旧快照不动。"
        rm -rf "$STAGE"
        return 1
    fi
    [ "$TAR_RC" -eq 1 ] && log_snap "tar 返回 1（打包期间有文件变动），继续。"

    # --------------------------------------------------------
    # 3) 把冷备的 state.db 追加进同一个包（路径 .hermes/state.db）
    # --------------------------------------------------------
    if [ -f "$STAGE/tree/.hermes/state.db" ]; then
        tar -rf "$STAGE/hermes.tar" -C "$STAGE/tree" .hermes/state.db 2>>"$LOG" \
            || { log_snap "ERROR: state.db 追加失败，放弃本次快照。"; rm -rf "$STAGE"; return 1; }
    fi

    # --------------------------------------------------------
    # 4) 压缩 → 临时名 → 校验 → 原子改名
    # --------------------------------------------------------
    if ! gzip -"$GZIP_LEVEL" -c "$STAGE/hermes.tar" > "$SNAP_TMP" 2>>"$LOG"; then
        log_snap "ERROR: gzip 失败，保留旧快照不动。"
        rm -f "$SNAP_TMP"; rm -rf "$STAGE"
        return 1
    fi

    if ! gzip -t "$SNAP_TMP" 2>>"$LOG"; then
        log_snap "ERROR: 生成的包校验失败，丢弃，保留旧快照。"
        rm -f "$SNAP_TMP"; rm -rf "$STAGE"
        return 1
    fi

    SZ=$(( $(stat -c %s "$SNAP_TMP") / 1024 / 1024 ))
    if ! mv -f "$SNAP_TMP" "$SNAP_FILE"; then
        log_snap "ERROR: 改名失败（网络盘写入异常）。"
        rm -f "$SNAP_TMP"; rm -rf "$STAGE"
        return 1
    fi

    rm -rf "$STAGE"
    log_snap "快照已覆盖写入：$SNAP_FILE（${SZ} MB）"
    date '+%F' > "$LAST_RUN_FILE"
    return 0
}

# ------------------------------------------------------------
# 常驻模式：每 60 秒看一次，北京时间 05:00 当天未打过就打包
# ------------------------------------------------------------
run_daemon() {
    log_snap "daemon 启动，目标时间北京时间 05:00（UTC 21:00）"
    while true; do
        HOUR_UTC="$(date -u +%H)"
        if [ "$HOUR_UTC" = "21" ]; then
            TODAY="$(date -u +%F)"
            LAST="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo '')"
            if [ "$LAST" != "$TODAY" ]; then
                do_snapshot || true
            fi
        fi
        sleep 60
    done
}

case "${1:-}" in
    --daemon) run_daemon ;;
    *)        do_snapshot ;;
esac
