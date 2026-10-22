#!/bin/bash
# ============================================================
# boot_restore.sh —— 开机恢复（有包就解包，没包就走原生首启）
#
# 语义：
#   网络盘里有快照 tar.gz  →  校验后解包覆盖 /root，再启动
#   没有 / 损坏 / 未挂载   →  什么都不做，按空 ~/.hermes 原生首启
#
# 不是"种子"：不区分首次开机与再次开机，不做一次性注入。
# 快照由 snap_daily.sh 每天覆盖写同一路径，开机拿到的永远是
# 最近一次成功打包的状态。
#
# 由 /entrypoint.sh 在启动 gateway 之前调用。
# 任何失败都只记日志并返回 0 —— 恢复不了也要能起来。
# ============================================================

SNAP_DIR="${SNAP_DIR:-/mnt/workspace/hermes-snapshot}"
SNAP_FILE="${SNAP_FILE:-$SNAP_DIR/hermes.tar.gz}"
TARGET_ROOT="${TARGET_ROOT:-/root}"
LOG=/tmp/hermes-restore.log

log_restore() {
    printf '[boot_restore %s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

restore_abort() {
    log_restore "跳过恢复：$*"
    log_restore "按空 ~/.hermes 走原生首启流程。"
    exit 0
}

log_restore "===== 开机恢复检查 ====="
log_restore "快照路径：$SNAP_FILE"

# ------------------------------------------------------------------
# 1) 网络盘挂载 + tar 存在且非空
#    ossfs 单次 stat 约 70ms，这里只有两次检查，开销可忽略
# ------------------------------------------------------------------
[ -d /mnt/workspace ] || restore_abort "/mnt/workspace 不存在（网络盘未挂载）"
[ -f "$SNAP_FILE" ]   || restore_abort "快照文件不存在"

SIZE="$(stat -c %s "$SNAP_FILE" 2>/dev/null || echo 0)"
if [ "${SIZE:-0}" -lt 1024 ]; then
    restore_abort "快照文件过小（${SIZE} B），视为无有效快照"
fi
log_restore "发现快照：${SIZE} 字节（$((SIZE / 1024 / 1024)) MB）"

# ------------------------------------------------------------------
# 2) 完整性校验：gzip -t 顺序读一遍
#    损坏就放弃，绝不用半个包覆盖现有数据
# ------------------------------------------------------------------
if ! gzip -t "$SNAP_FILE" 2>/dev/null; then
    restore_abort "快照校验失败（gzip -t 未通过），放弃恢复以免覆盖现有数据"
fi
log_restore "快照完整性校验通过，开始解包覆盖 /root"

# ------------------------------------------------------------------
# 3) 解包
#    包内路径为 .hermes/... 与 bz-startup/...（相对 /root）
#    -p 保留权限（.hermes/memories 需 0700），--numeric-owner 避免 UID 映射
# ------------------------------------------------------------------
RESTORE_RC=0
tar -xzpf "$SNAP_FILE" -C "$TARGET_ROOT" --numeric-owner 2>>"$LOG" || RESTORE_RC=$?

if [ "$RESTORE_RC" -ne 0 ]; then
    log_restore "解包失败（rc=$RESTORE_RC），详见 $LOG；继续启动，不阻塞。"
    exit 0
fi

# ------------------------------------------------------------------
# 4) 闸门：关键条目是否真的落地
# ------------------------------------------------------------------
MISSING=""
[ -f "$TARGET_ROOT/.hermes/config.yaml" ] || MISSING="$MISSING config.yaml"
[ -d "$TARGET_ROOT/.hermes/memories" ]    || MISSING="$MISSING memories/"
[ -d "$TARGET_ROOT/.hermes/skills" ]      || MISSING="$MISSING skills/"

if [ -n "$MISSING" ]; then
    log_restore "警告：解包后缺少关键条目：$MISSING"
    log_restore "继续启动，由 Hermes 自行补齐缺失部分。"
else
    log_restore "解包完成，关键条目均已就位。"
fi

log_restore "恢复结束，移交 entrypoint 启动 gateway。"
exit 0
