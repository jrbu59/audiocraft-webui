#!/bin/bash

# === 通用工具函数 ===
command_exists() { command -v "$1" &> /dev/null; }
is_running() {
  local pid="$1"
  if [ -z "$pid" ]; then return 1; fi
  kill -0 "$pid" 2>/dev/null
}

# === 配置 ===
PID_DIR="logs"
PID_FILE="$PID_DIR/audiocraft-ui.pid"
LOG_FILE="$PID_DIR/webui.log"

# 确保日志目录存在
mkdir -p "$PID_DIR"

# === 参数解析 ===
ACTION="start"  # 默认行为
USE_CONDA=true
CONDA_ENV_NAME="audiocraft"
NEXT_IS_ENV=false

for arg in "$@"; do
  if [ "$NEXT_IS_ENV" = true ]; then
    CONDA_ENV_NAME="$arg"
    NEXT_IS_ENV=false
    continue
  fi
  case "$arg" in
    start|stop|status)
      ACTION="$arg"
      ;;
    --conda)
      USE_CONDA=true
      ;;
    --conda-env)
      NEXT_IS_ENV=true
      ;;
    *)
      ;;
  esac
done

# === 环境激活（仅在 start 时进行） ===
activate_env() {
  if [ "$USE_CONDA" == true ]; then
    echo "激活 Conda 环境: $CONDA_ENV_NAME ..."
    if command_exists conda; then
      CONDA_BASE="$(conda info --base 2>/dev/null)" || CONDA_BASE=""
      if [ -n "$CONDA_BASE" ] && [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
        # shellcheck source=/dev/null
        source "$CONDA_BASE/etc/profile.d/conda.sh"
      fi
      if conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV_NAME"; then
        conda activate "$CONDA_ENV_NAME" || { echo "激活 Conda 环境失败: $CONDA_ENV_NAME"; exit 1; }
      else
        echo "未找到 Conda 环境 '$CONDA_ENV_NAME'。可通过如下命令创建："
        echo "  conda create -n $CONDA_ENV_NAME python=3.10"
        exit 1
      fi
    else
      echo "未检测到 Conda，请安装后重试。"
      exit 1
    fi
  else
    if [ -d "venv" ]; then
      echo "激活 Python 虚拟环境..."
      # shellcheck source=/dev/null
      source venv/bin/activate || { echo "激活 venv 失败"; exit 1; }
    else
      echo "未找到虚拟环境 venv，请先运行安装脚本。"
      exit 1
    fi
  fi

  # 使用 Conda 提供的 C++ 运行时，避免系统 ABI 问题
  if [ -n "$CONDA_PREFIX" ] && [ -f "$CONDA_PREFIX/lib/libstdc++.so.6" ]; then
    echo "从 Conda 环境设置 LD_LIBRARY_PATH/LD_PRELOAD 以避免 CXXABI 问题..."
    export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
    export LD_PRELOAD="$CONDA_PREFIX/lib/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
  fi

  # 可选代理（如无需要可注释）
  export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890
}

deactivate_env() {
  if [ "$USE_CONDA" == true ]; then
    conda deactivate 2>/dev/null || true
  else
    deactivate 2>/dev/null || true
  fi
}

# === 单例检查 ===
check_already_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if is_running "$pid"; then
      echo "服务已在运行（PID: $pid）。如需停止：$0 stop"
      return 0
    else
      echo "检测到陈旧 PID 文件，清理后继续启动..."
      rm -f "$PID_FILE"
    fi
  fi
  return 1
}

# === 启动 ===
do_start() {
  # 单例检查
  if check_already_running; then
    exit 0
  fi

  activate_env

  if [ ! -f "webui.py" ]; then
    echo "未找到 webui.py！"
    deactivate_env
    exit 1
  fi

  echo "以后台方式启动 Web UI ..."
  # 使用 nohup+setsid 后台运行并记录 PID 与日志
  nohup setsid python webui.py >> "$LOG_FILE" 2>&1 &
  local pid=$!

  # 处理 Flask/SockeIO 重载：解析最终存活的子进程 PID
  final_pid="$pid"
  for i in 1 2 3 4 5; do
    if is_running "$final_pid"; then
      # 若存在单一子进程，向下穿透一次
      child="$(ps -o pid= --ppid "$final_pid" 2>/dev/null | awk 'NR==1{print $1}')"
      if [ -n "$child" ] && is_running "$child"; then
        final_pid="$child"
        sleep 0.3
        continue
      fi
      break
    else
      # 父 PID 已退出，尝试按命令匹配最新的 webui.py 进程
      cand="$(pgrep -f -n "python .*webui.py" 2>/dev/null || pgrep -f -n "webui.py" 2>/dev/null)"
      if [ -n "$cand" ] && is_running "$cand"; then
        final_pid="$cand"
        break
      fi
      sleep 0.3
    fi
  done

  echo "$final_pid" > "$PID_FILE"
  disown "$final_pid" 2>/dev/null || true

  echo "已启动（PID: $final_pid）。日志：$LOG_FILE"

  # 启动健康检查：短时间内退出则视为失败并清理 PID
  for i in 1 2 3 4 5; do
    if ! is_running "$final_pid"; then
      echo "服务启动失败（进程已退出）。查看最近日志："
      tail -n 50 "$LOG_FILE" 2>/dev/null || true
      rm -f "$PID_FILE"
      deactivate_env
      exit 1
    fi
    sleep 0.5
  done
  deactivate_env
}

# === 停止 ===
do_stop() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if ! is_running "$pid"; then
      # 尝试修复 PID
      fix="$(pgrep -f -n "python .*webui.py" 2>/dev/null || pgrep -f -n "webui.py" 2>/dev/null)"
      if [ -n "$fix" ] && is_running "$fix"; then
        echo "$fix" > "$PID_FILE"
        pid="$fix"
      fi
    fi
    if is_running "$pid"; then
      echo "正在停止服务（PID: $pid）..."
      kill -TERM "$pid" 2>/dev/null || true
      # 等待最多 5 秒
      for i in 1 2 3 4 5; do
        if ! is_running "$pid"; then break; fi
        sleep 1
      done
      if is_running "$pid"; then
        echo "进程未退出，执行强制停止..."
        kill -KILL "$pid" 2>/dev/null || true
      fi
      rm -f "$PID_FILE"
      echo "服务已停止。"
      exit 0
    else
      echo "未检测到运行中的进程，但存在陈旧 PID 文件，已清理。"
      rm -f "$PID_FILE"
      # 继续尝试基于进程名停止（防御性）
    fi
  fi

  # 无 PID 文件，尝试基于进程名停止
  local killed=0
  if pgrep -f "webui.py" >/dev/null 2>&1; then
    echo "尝试通过进程名停止残留 webui.py 进程..."
    pkill -TERM -f "webui.py" 2>/dev/null || true
    killed=1
  fi
  if [ "$killed" -eq 1 ]; then
    echo "已发送停止信号。"
  else
    echo "未发现正在运行的服务。"
  fi
}

# === 状态 ===
do_status() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    if is_running "$pid"; then
      echo "运行中（PID: $pid）。日志：$LOG_FILE"
      return
    else
      # 尝试修复 PID 文件
      fix="$(pgrep -f -n "python .*webui.py" 2>/dev/null || pgrep -f -n "webui.py" 2>/dev/null)"
      if [ -n "$fix" ] && is_running "$fix"; then
        echo "$fix" > "$PID_FILE"
        echo "运行中（PID: $fix）。已修复陈旧 PID 文件。日志：$LOG_FILE"
        return
      else
        echo "未运行（存在陈旧 PID 文件）。"
        return
      fi
    fi
  fi
  # 无 PID 文件时，检查是否有进程名匹配
  if pgrep -f "webui.py" >/dev/null 2>&1; then
    echo "检测到运行中的 webui.py 进程，但未记录 PID 文件。"
  else
    echo "未运行。"
  fi
}

# === 主流程 ===
case "$ACTION" in
  start)
    do_start
    ;;
  stop)
    do_stop
    ;;
  status)
    do_status
    ;;
  *)
    echo "未知命令：$ACTION"
    echo "用法：$0 [start|stop|status] [--conda] [--conda-env NAME]"
    exit 1
    ;;
esac
