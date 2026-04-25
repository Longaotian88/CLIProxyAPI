#!/usr/bin/env bash

# CLIProxyAPI 升级脚本
# 功能：安全拉取最新代码、编译新版本并重启服务

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
CONFIG_FILE="$PROJECT_DIR/config.yaml"
LOCAL_START_SCRIPT="$PROJECT_DIR/start.local.sh"
EXAMPLE_START_SCRIPT="$PROJECT_DIR/start.example.sh"
BINARY_PATH="$PROJECT_DIR/cli-proxy-api"
LOG_FILE="/tmp/cliProxyAPI.log"
DEFAULT_PORT="8317"
STARTUP_TIMEOUT=30
TEMP_BINARY=""

cleanup() {
    if [[ -n "$TEMP_BINARY" && -f "$TEMP_BINARY" ]]; then
        rm -f "$TEMP_BINARY"
    fi
}
trap cleanup EXIT

print_section() {
    echo ""
    echo ">>> $1"
}

die() {
    echo "错误: $1" >&2
    exit 1
}

get_port() {
    local config_file="$1"
    local port=""

    if [[ -f "$config_file" ]]; then
        port="$(grep -E '^port:' "$config_file" | sed -E 's/^port: *["'"'"']?([0-9]+)["'"'"']?.*$/\1/' | head -n1 || true)"
    fi

    if [[ -n "$port" ]]; then
        printf '%s\n' "$port"
    else
        printf '%s\n' "$DEFAULT_PORT"
    fi
}

get_health_host() {
    local config_file="$1"
    local host_line
    local host

    if [[ ! -f "$config_file" ]]; then
        printf '127.0.0.1\n'
        return
    fi

    host_line="$(grep -E '^host:' "$config_file" | head -n1 || true)"

    if [[ -z "$host_line" ]]; then
        printf '127.0.0.1\n'
        return
    fi

    host="${host_line#host:}"
    host="${host#"${host%%[![:space:]]*}"}"
    host="${host%"${host##*[![:space:]]}"}"
    host="${host//\"/}"
    host="${host//\'/}"

    case "$host" in
        ""|"0.0.0.0"|"::")
            printf '127.0.0.1\n'
            ;;
        *)
            printf '%s\n' "$host"
            ;;
    esac
}

ensure_main_branch() {
    local branch
    branch="$(git branch --show-current)"

    if [[ "$branch" != "main" ]]; then
        die "当前分支是 '$branch'，请切换到 main 后再执行升级"
    fi
}

require_clean_tracked_files() {
    local changes
    changes="$(git status --porcelain --untracked-files=no)"

    if [[ -n "$changes" ]]; then
        echo "检测到本地 tracked 改动，已停止升级以避免覆盖："
        echo "$changes"
        echo ""
        echo "请先提交、暂存或手动处理这些改动后再执行 upgrade.sh"
        echo "机器本地启动/停止脚本请放到 start.local.sh / stop.local.sh，避免升级时被 tracked 改动拦住"
        exit 1
    fi
}

stop_process_on_port() {
    local port="$1"
    local pid
    local pids=()
    local alive=0

    while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
    done < <(lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)

    if [[ ${#pids[@]} -eq 0 ]]; then
        echo "服务未运行，跳过停止步骤"
        return 0
    fi

    echo "找到监听端口 $port 的进程: ${pids[*]}"
    kill -15 "${pids[@]}" 2>/dev/null || true

    for ((i=1; i<=10; i++)); do
        alive=0
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive=1
                break
            fi
        done

        if [[ $alive -eq 0 ]]; then
            echo "进程已停止"
            return 0
        fi

        sleep 1
    done

    echo "进程仍未退出，强制终止..."
    kill -9 "${pids[@]}" 2>/dev/null || true
    sleep 1

    alive=0
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            alive=1
            break
        fi
    done

    if [[ $alive -eq 1 ]]; then
        die "无法停止监听端口 $port 的旧进程"
    fi

    echo "进程已强制终止"
}

probe_service() {
    local host="$1"
    local port="$2"
    local http_code=""

    http_code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://${host}:${port}/" || true)"
    if [[ "$http_code" == "200" ]]; then
        printf 'http\n'
        return 0
    fi

    http_code="$(curl -sk --max-time 2 -o /dev/null -w '%{http_code}' "https://${host}:${port}/" || true)"
    if [[ "$http_code" == "200" ]]; then
        printf 'https\n'
        return 0
    fi

    return 1
}

wait_for_service() {
    local host="$1"
    local port="$2"
    local scheme=""

    echo "等待服务就绪 (${host}:${port})..."
    for ((i=1; i<=STARTUP_TIMEOUT; i++)); do
        if scheme="$(probe_service "$host" "$port")"; then
            echo "服务运行正常 (${scheme}://${host}:${port}/, HTTP 200)"
            return 0
        fi
        sleep 1
    done

    return 1
}

echo "========================================"
echo "  CLIProxyAPI 升级脚本"
echo "========================================"
echo ""

cd "$PROJECT_DIR"

print_section "步骤 1: 检查升级前置条件"
[[ -f "$PROJECT_DIR/go.mod" ]] || die "未在 $PROJECT_DIR 找到 go.mod"
[[ -f "$CONFIG_FILE" ]] || die "未找到配置文件: $CONFIG_FILE"

CURRENT_PORT="$(get_port "$CONFIG_FILE")"
ensure_main_branch

echo "项目目录: $PROJECT_DIR"
echo "当前分支: main"
echo "当前服务端口: $CURRENT_PORT"

print_section "步骤 2: 拉取最新代码并同步到 fork"
git fetch upstream
git merge upstream/main --no-edit
git push origin main

[[ -f "$CONFIG_FILE" ]] || die "更新后未找到配置文件: $CONFIG_FILE"

TARGET_PORT="$(get_port "$CONFIG_FILE")"
HEALTH_HOST="$(get_health_host "$CONFIG_FILE")"
VERSION="$(git describe --tags --always --dirty)"
COMMIT="$(git rev-parse --short HEAD)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "代码已更新到最新 main"
echo "新版本端口: $TARGET_PORT"
echo "健康检查地址: ${HEALTH_HOST}:${TARGET_PORT}"

print_section "步骤 3: 编译项目"
echo "Version: $VERSION"
echo "Commit: $COMMIT"
echo "Build Date: $BUILD_DATE"

echo "下载依赖..."
go mod download

TEMP_BINARY="$(mktemp "$PROJECT_DIR/cli-proxy-api.build.XXXXXX")"
rm -f "$TEMP_BINARY"

echo "编译新版本..."
go build \
    -o "$TEMP_BINARY" \
    -ldflags "-X main.Version=${VERSION} -X main.Commit=${COMMIT} -X main.BuildDate=${BUILD_DATE}" \
    ./cmd/server

[[ -f "$TEMP_BINARY" ]] || die "编译失败，未生成新二进制文件"
chmod +x "$TEMP_BINARY"

echo "编译成功"

print_section "步骤 4: 停止旧服务"
stop_process_on_port "$CURRENT_PORT"

print_section "步骤 5: 安装新版本并启动服务"
mv -f "$TEMP_BINARY" "$BINARY_PATH"
TEMP_BINARY=""

START_COMMAND=()
START_MODE_LABEL="compiled binary"

if [[ -f "$LOCAL_START_SCRIPT" ]]; then
    START_COMMAND=(env CLIPROXYAPI_START_MODE=binary bash "$LOCAL_START_SCRIPT" --config "$CONFIG_FILE")
    START_MODE_LABEL="start.local.sh"
elif [[ -f "$EXAMPLE_START_SCRIPT" ]]; then
    START_COMMAND=(env CLIPROXYAPI_START_MODE=binary bash "$EXAMPLE_START_SCRIPT" --config "$CONFIG_FILE")
    START_MODE_LABEL="start.example.sh"
else
    START_COMMAND=("$BINARY_PATH" -config "$CONFIG_FILE")
fi

nohup "${START_COMMAND[@]}" > "$LOG_FILE" 2>&1 &
NEW_PID=$!

echo "服务已启动 (PID: $NEW_PID)"
echo "启动入口: $START_MODE_LABEL"

if ! wait_for_service "$HEALTH_HOST" "$TARGET_PORT"; then
    echo "错误: 服务未在 ${STARTUP_TIMEOUT} 秒内通过健康检查" >&2
    echo "请检查日志: $LOG_FILE" >&2
    exit 1
fi

echo ""
echo "========================================"
echo "  升级完成!"
echo "========================================"
echo ""
echo "Version: $VERSION"
echo "Commit: $COMMIT"
echo "Build Date: $BUILD_DATE"
echo "日志文件: $LOG_FILE"
echo "可执行文件: $BINARY_PATH"
