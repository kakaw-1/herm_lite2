#!/bin/bash
# 用户自定义启动脚本（每次开机无条件执行，必须幂等）。
#
# 注意：entrypoint 以 PATH=/opt/hermes/.venv/bin:... 运行本脚本，
# 裸 `python3`/`pip` 会解析到 venv（无 pip 可执行），解释器一律写死绝对路径。
#
# 本脚本只做"必须早于 Hermes 启动"的轻量工作：
#   * 飞书网关依赖自愈（首启/重建后重装）
#   * 可选后台服务的自愈拉起（脚本不存在就静默跳过）
# 其余工具（camoufox 等）统一由 cron 任务在 Hermes 启动后调用
# ~/.hermes/scripts/tool-install.sh 安装，避免阻塞启动。

VENV_PY=/opt/hermes/.venv/bin/python3
UV_BIN=/root/.local/bin/uv
STARTUP_LOG=/tmp/bz-startup.log

# --- 飞书机器人网关依赖 自愈安装 ---
# venv 由 uv 创建、无 pip 可执行文件，装包统一走 uv pip install --python <venv>
{
  echo "===== $(date '+%F %T') bz-startup: 飞书依赖检查 ====="
  if ! "$VENV_PY" -c "import lark_oapi, websockets, qrcode" 2>/dev/null; then
    echo "[$(date '+%T')] 缺少飞书依赖，执行 uv pip install lark-oapi websockets qrcode ..."
    if [ -x "$UV_BIN" ]; then
      "$UV_BIN" pip install --python "$VENV_PY" lark-oapi websockets qrcode \
        || echo "[$(date '+%T')] ERROR: 飞书依赖安装失败"
    else
      echo "[$(date '+%T')] ERROR: 未找到 $UV_BIN，无法安装飞书依赖"
    fi
  else
    echo "[$(date '+%T')] 飞书依赖已就绪，跳过"
  fi
  echo "===== $(date '+%F %T') 完成 ====="
} >> "$STARTUP_LOG" 2>&1

# --- 可选后台服务自愈（空实例上这些脚本不存在，静默跳过）---
# Resin 代理池 + opencode2api：幂等，进程在就静默退出。
RESIN_BOOT=/root/.hermes/scripts/resin_boot.sh
if [ -f "$RESIN_BOOT" ]; then
  setsid nohup bash "$RESIN_BOOT" >/dev/null 2>&1 < /dev/null &
else
  echo "[$(date '+%T')] resin_boot.sh 不存在，跳过（本实例未部署代理栈）" >> "$STARTUP_LOG" 2>&1
fi

# --- 备份链相关目录占位（部分脚本假定这些路径存在）---
for d in /root/.openclaw /root/.codex /root/.claude; do mkdir -p "$d"; done
[ -f /root/.zsh_history ] || touch /root/.zsh_history

exit 0
