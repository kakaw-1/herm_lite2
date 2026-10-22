#!/bin/bash
# Hermes Lite entrypoint
# Gateway 只在容器启动时启动一次，不做自动重启。

set -e

export HOME="${HOME:-/root}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ============================================================
# 基础配置
# ============================================================

# ModelScope Health / 状态页
export HEALTH_HOST="0.0.0.0"
export HEALTH_PORT="${HEALTH_PORT:-7860}"

# Hermes Gateway API
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-false}"
export API_SERVER_HOST="127.0.0.1"
export API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# Hermes Dashboard
# 环境变量设置 HERMES_DASHBOARD_PORT=9110 时会直接使用 9110。
export HERMES_DASHBOARD_HOST="127.0.0.1"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"

# Web Shell
export WEB_SHELL_PORT="${WEB_SHELL_PORT:-2222}"

# 允许 root 运行 Gateway
export HERMES_ALLOW_ROOT_GATEWAY="${HERMES_ALLOW_ROOT_GATEWAY:-1}"


# ============================================================
# 1) 数据恢复（有包就解，没包就原生首启）+ 每日快照守护
# ============================================================
#
# 恢复完全由网络盘决定，不靠任何开关：
#
#   /mnt/workspace/hermes-snapshot/hermes.tar.gz 存在
#        → 校验通过后解包覆盖 /root，再启动
#   不存在 / 损坏 / 盘未挂载
#        → 什么都不做，按空 ~/.hermes 走原生首启
#
# SKIP_RESTORE=1 仅作为强制跳过恢复的手动保险，默认不需要。
# ------------------------------------------------------------

if [ "${SKIP_RESTORE:-}" = "1" ]; then

    echo "检测到 SKIP_RESTORE=1，跳过开机恢复。"

else

    /bz/boot_restore.sh || true

fi

# 每日快照守护：60 秒轮询，北京时间 05:00 覆盖写唯一一份 tar.gz
nohup /bz/snap_daily.sh --daemon \
    >/tmp/hermes-snapshot.log \
    2>&1 &

echo "[entrypoint] 每日快照守护已启动（北京时间 05:00 覆盖写）。"


# ============================================================
# 2) 用户自定义初始化
# ============================================================

if [ -x /root/bz-startup/main.sh ]; then
    /root/bz-startup/main.sh
fi


# ============================================================
# 3) 远程访问
# ============================================================

source /remote-access/start_remote_access.sh


# 远程访问相关进程已经拿到所需变量，
# 后续不再传递这些敏感环境变量。
unset \
    WEB_SHELL_PASSWORD \
    WEB_SHELL_HTTP_PASSWORD \
    CF_TUNNEL_TOKEN \
    TUNNEL_TOKEN \
    || true


# ============================================================
# 4) Hermes Gateway API
# ============================================================

case "$API_SERVER_ENABLED" in

    1|true|TRUE|yes|YES|on|ON)

        if [ -z "${API_SERVER_KEY:-}" ]; then

            API_SERVER_KEY="$(
                python - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
            )"

            export API_SERVER_KEY

            echo "Hermes Gateway API 已启用在 127.0.0.1:${API_SERVER_PORT}；未提供 API_SERVER_KEY，已生成本实例临时 key。"

        fi

        ;;

esac


# ============================================================
# 5) 可选本地服务
# ============================================================
#
# 这里只启动 Dashboard。
# Health 已经不再由 start_local_services.sh 启动。
# ============================================================

source /runtime/start_local_services.sh


# ============================================================
# 6) 启动 Gateway
# ============================================================
#
# 注意：
#
# Gateway 只启动这一次。
#
# 如果之后：
#
#   - Gateway 崩溃
#   - Gateway 被 kill
#   - Gateway 手动停止
#
# entrypoint 不会重新执行 hermes gateway run。
#
# ============================================================

echo "[entrypoint] 启动 Hermes Gateway（仅启动一次，不自动拉起）..."


"$@" \
    > >(tee -a /tmp/hermes-gateway.log) \
    2>&1 &


GATEWAY_PID=$!


echo "[entrypoint] Gateway pid=$GATEWAY_PID"


# ============================================================
# 7) 启动 Health
# ============================================================
#
# Health 是容器生命周期锚点。
#
# Gateway 即使退出：
#
#   Health 仍然运行
#   entrypoint 仍然运行
#   容器仍然运行
#
# ============================================================

echo "[entrypoint] 启动 ModelScope 状态页：http://0.0.0.0:${HEALTH_PORT}"


env \
    -u API_SERVER_KEY \
    -u SSH_PASSWORD \
    -u CF_TUNNEL_TOKEN \
    -u TUNNEL_TOKEN \
    python /health/health_server.py \
    > >(tee -a /tmp/hermes-health.log) \
    2>&1 &


HEALTH_PID=$!


echo "[entrypoint] Health pid=$HEALTH_PID"


# ============================================================
# 8) 容器停止信号处理
# ============================================================
#
# entrypoint.sh 保持 PID 1。
#
# ModelScope / Docker 停止容器时：
#
#   SIGTERM
#      ├── Gateway（如果还活着）
#      └── Health
#
# ============================================================

shutdown() {

    local signal="${1:-TERM}"


    # 防止重复触发
    trap - TERM INT


    echo "[entrypoint] 收到 ${signal}，正在停止 Health 与 Gateway..."


    # --------------------------------------------------------
    # 停止 Gateway
    # --------------------------------------------------------

    if kill -0 "$GATEWAY_PID" 2>/dev/null; then

        echo "[entrypoint] 停止 Gateway (pid=$GATEWAY_PID)..."

        kill -TERM \
            "$GATEWAY_PID" \
            2>/dev/null \
            || true

    fi


    # --------------------------------------------------------
    # 停止 Health
    # --------------------------------------------------------

    if kill -0 "$HEALTH_PID" 2>/dev/null; then

        echo "[entrypoint] 停止 Health (pid=$HEALTH_PID)..."

        kill -TERM \
            "$HEALTH_PID" \
            2>/dev/null \
            || true

    fi


    # --------------------------------------------------------
    # 等待进程退出
    # --------------------------------------------------------

    wait \
        "$GATEWAY_PID" \
        2>/dev/null \
        || true


    wait \
        "$HEALTH_PID" \
        2>/dev/null \
        || true


    echo "[entrypoint] 主服务已停止。"


    exit 0
}


trap 'shutdown TERM' TERM
trap 'shutdown INT' INT


# ============================================================
# 9) Health 决定容器生命周期
# ============================================================
#
# 这里只等待 Health。
#
# 不等待 Gateway。
#
# 所以：
#
# Gateway exit
#     ↓
# 不重启 Gateway
#     ↓
# Health 仍然运行
#     ↓
# entrypoint 仍然运行
#     ↓
# 容器保持运行
#
#
# 只有 Health 退出：
#
# Health exit
#     ↓
# 停止仍存活的 Gateway
#     ↓
# entrypoint 退出
#     ↓
# 容器退出
#
# ============================================================

if wait "$HEALTH_PID"; then

    HEALTH_RC=0

else

    HEALTH_RC=$?

fi


echo "[entrypoint] Health server 已退出 (code=$HEALTH_RC)，准备结束容器。"


# ============================================================
# Health 退出后清理 Gateway
# ============================================================

if kill -0 "$GATEWAY_PID" 2>/dev/null; then

    echo "[entrypoint] Health 已退出，停止 Gateway (pid=$GATEWAY_PID)..."

    kill -TERM \
        "$GATEWAY_PID" \
        2>/dev/null \
        || true

fi


wait \
    "$GATEWAY_PID" \
    2>/dev/null \
    || true


exit "$HEALTH_RC"
