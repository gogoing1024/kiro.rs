#!/bin/bash
# =============================================================================
# kiro.rs 一键部署脚本 (macOS + Colima)
# =============================================================================
# 在 macOS 上使用 Colima（免费的 Docker Desktop 替代方案）一键部署 kiro.rs。
#
# 脚本功能：
#   1. 自动安装依赖：Homebrew、Colima、Docker CLI、Docker Compose
#   2. 启动/配置 Colima 虚拟机（可自定义 CPU/内存/磁盘）
#   3. 生成 docker-compose.yml & 数据目录（首次启动由容器自动生成密钥）
#   4. 拉取（或本地构建）镜像并启动服务
#   5. 等待服务就绪，自动读取并展示 apiKey / adminApiKey
#
# 用法：
#   chmod +x macos-colima-deploy.sh
#   ./macos-colima-deploy.sh
#
# 环境变量（可选）：
#   COLIMA_CPU=4              Colima 虚拟机 CPU 核心数（默认 2）
#   COLIMA_MEMORY=8           Colima 虚拟机内存 GB（默认 4）
#   COLIMA_DISK=60            Colima 虚拟机磁盘 GB（默认 60）
#   COLIMA_ARCH=aarch64       Colima 虚拟机架构（默认自动检测）
#   DEPLOY_DIR=/opt/kiro-rs   部署目录（默认 /opt/kiro-rs）
#   SERVER_PORT=8778          宿主机与容器内监听端口（默认 8778）
#   SKIP_COLIMA_START=true    跳过 Colima 启动（已有 Docker 环境时使用）
#   SOURCE_DIR=/path/to/kiro.rs  本地源码目录（设置后从源码构建镜像，不拉远程）
#   KIRO_RS_IMAGE=...         远程镜像 tag（默认 zyphrzero/kiro-rs:latest）
# =============================================================================

set -euo pipefail

# ---- 颜色定义 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 可配置参数 ----
COLIMA_CPU="${COLIMA_CPU:-2}"
COLIMA_MEMORY="${COLIMA_MEMORY:-4}"
COLIMA_DISK="${COLIMA_DISK:-60}"
COLIMA_ARCH="${COLIMA_ARCH:-}"
# 部署目录默认放在 /opt 下；Colima 默认挂载范围可能不含 /opt，
# 脚本启动 Colima 时会显式挂载该目录，确保数据落在宿主机。
DEPLOY_DIR="${DEPLOY_DIR:-/opt/kiro-rs}"
SERVER_PORT="${SERVER_PORT:-8778}"
SKIP_COLIMA_START="${SKIP_COLIMA_START:-false}"
SOURCE_DIR="${SOURCE_DIR:-}"
KIRO_RS_IMAGE="${KIRO_RS_IMAGE:-zyphrzero/kiro-rs:latest}"

LOCAL_IMAGE_NAME="kiro-rs:local"
# ---- 辅助函数 ----
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_deploy_dir_exists() {
    if mkdir -p "${DEPLOY_DIR}" 2>/dev/null && [[ -w "${DEPLOY_DIR}" ]]; then
        :
    else
        sudo mkdir -p "${DEPLOY_DIR}"
        sudo chown "$(id -u):$(id -g)" "${DEPLOY_DIR}"
    fi
}

# 失败清理
cleanup_on_error() {
    error "部署过程中出现错误，请检查上方日志。"
    error "可重新运行此脚本继续部署（已生成的配置不会被覆盖）。"
    exit 1
}
trap cleanup_on_error ERR

# ---- 检测系统 ----
check_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "此脚本仅支持 macOS，当前系统: $(uname -s)"
        exit 1
    fi
    local arch
    arch="$(uname -m)"
    info "macOS $(sw_vers -productVersion) | 架构: ${arch}"
    if [[ -z "$COLIMA_ARCH" ]]; then
        case "$arch" in
            arm64) COLIMA_ARCH="aarch64" ;;
            *)     COLIMA_ARCH="x86_64"  ;;
        esac
    fi
}

# ---- 安装 Homebrew ----
ensure_homebrew() {
    if command_exists brew; then
        success "Homebrew 已安装"
        return
    fi
    step "安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # 确保 brew 在 PATH 中
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    success "Homebrew 安装完成"
}

# ---- 安装 Colima + Docker CLI ----
ensure_colima() {
    local need_install=()

    if ! command_exists colima; then
        need_install+=(colima)
    else
        success "Colima 已安装 ($(colima version | head -1))"
    fi

    if ! command_exists docker; then
        need_install+=(docker)
    else
        success "Docker CLI 已安装 ($(docker --version))"
    fi

    # docker compose v2 作为 docker 子命令
    if ! docker compose version >/dev/null 2>&1; then
        need_install+=(docker-compose)
    else
        success "Docker Compose 已安装 ($(docker compose version --short 2>/dev/null || echo 'v2'))"
    fi

    if [[ ${#need_install[@]} -gt 0 ]]; then
        step "通过 Homebrew 安装: ${need_install[*]}..."
        brew install "${need_install[@]}"
        success "依赖安装完成"
    fi
}

# ---- 启动 Colima ----
start_colima() {
    if [[ "$SKIP_COLIMA_START" == "true" ]]; then
        info "SKIP_COLIMA_START=true，跳过 Colima 启动"
        return
    fi

    # 检查 Colima 是否已在运行
    if colima status 2>/dev/null | grep -q "Running"; then
        success "Colima 已在运行"
        if docker info >/dev/null 2>&1; then
            success "Docker 连接正常"
            return
        else
            warn "Colima 运行中但 Docker 连接失败，尝试重启..."
            colima stop 2>/dev/null || true
        fi
    fi

    ensure_deploy_dir_exists

    step "启动 Colima 虚拟机 (CPU=${COLIMA_CPU}, 内存=${COLIMA_MEMORY}GB, 磁盘=${COLIMA_DISK}GB, 架构=${COLIMA_ARCH}, 挂载=${DEPLOY_DIR}:w)..."
    colima start \
        --cpu "$COLIMA_CPU" \
        --memory "$COLIMA_MEMORY" \
        --disk "$COLIMA_DISK" \
        --arch "$COLIMA_ARCH" \
        --mount "${DEPLOY_DIR}:w" \
        --vm-type=qemu

    # 等待 Docker 就绪
    local retries=30
    while ! docker info >/dev/null 2>&1; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            error "等待 Docker 就绪超时。请运行 'colima status' 检查状态。"
            exit 1
        fi
        sleep 2
    done
    success "Colima 启动完成，Docker 已就绪"
}
# ---- 从本地源码构建镜像 ----
build_local_image() {
    if [[ -z "$SOURCE_DIR" ]]; then
        return
    fi

    if [[ ! -f "${SOURCE_DIR}/Dockerfile" ]]; then
        error "SOURCE_DIR=${SOURCE_DIR} 中未找到 Dockerfile"
        exit 1
    fi

    step "从本地源码构建镜像: ${SOURCE_DIR}"
    info "镜像名称: ${LOCAL_IMAGE_NAME}"
    info "多阶段构建（bun 构建前端 → rust 编译后端），首次构建可能需要 5-15 分钟，请耐心等待..."

    docker build \
        -t "${LOCAL_IMAGE_NAME}" \
        -f "${SOURCE_DIR}/Dockerfile" \
        "${SOURCE_DIR}"

    success "本地镜像构建完成: ${LOCAL_IMAGE_NAME}"
}

# ---- 校验部署目录在 Colima 挂载范围内 ----
# 若部署目录未被 Colima 挂载，容器的 bind 挂载会落到 VM 本地磁盘，
# 导致宿主机看不到数据、无法备份、删 VM 即丢。
check_mount_scope() {
    if [[ "$SKIP_COLIMA_START" == "true" ]]; then
        return
    fi
    case "${DEPLOY_DIR}/" in
        "$HOME/"*) ;;  # 在 $HOME 下，通常已由 Colima 默认挂载
        *)
            if colima ssh -- mount 2>/dev/null | grep -F " on ${DEPLOY_DIR} " >/dev/null 2>&1; then
                success "Colima 已挂载部署目录: ${DEPLOY_DIR}"
            else
                error "部署目录 ${DEPLOY_DIR} 不在 \$HOME (${HOME}) 下，且未检测到 Colima 挂载。"
                error "请重启 Colima 并挂载该目录："
                error "  colima stop"
                error "  colima start --mount \"${DEPLOY_DIR}:w\""
                exit 1
            fi
            ;;
    esac
}

# ---- 准备部署目录 ----
prepare_deploy_dir() {
    step "准备部署目录: ${DEPLOY_DIR}"
    ensure_deploy_dir_exists

    # 数据持久化目录（容器内 /app/config），首次启动由容器自动生成
    # config.json / credentials.json
    mkdir -p "${DEPLOY_DIR}/data"
    ensure_app_port_config

    # 确定实际使用的镜像名
    local image_ref
    if [[ -n "$SOURCE_DIR" ]]; then
        image_ref="${LOCAL_IMAGE_NAME}"
    else
        image_ref="${KIRO_RS_IMAGE}"
    fi

    # 已存在配置时询问是否保留
    if [[ -f "${DEPLOY_DIR}/docker-compose.yml" ]]; then
        warn "检测到已有部署配置: ${DEPLOY_DIR}/docker-compose.yml"
        echo -n "  是否保留现有配置并仅更新服务？[Y/n] "
        read -r reply
        if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
            info "保留现有 data/ 与配置，仅更新镜像引用为: ${image_ref}"
            generate_compose "${image_ref}"
            return 0
        fi
    fi

    generate_compose "${image_ref}"
    success "配置文件已生成: ${DEPLOY_DIR}/docker-compose.yml"
}

# ---- 生成 docker-compose.yml ----
# 参数 $1: 镜像引用
generate_compose() {
    local image_ref="$1"
    cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:
  kiro-rs:
    image: ${image_ref}
    container_name: kiro-rs
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "${SERVER_PORT}:${SERVER_PORT}"
    volumes:
      - ./data/:/app/config/
    restart: unless-stopped
EOF
}

# ---- 确保容器内应用监听端口与宿主机端口一致 ----
ensure_app_port_config() {
    local config_file="${DEPLOY_DIR}/data/config.json"

    if [[ -f "$config_file" ]]; then
        CONFIG_FILE="$config_file" SERVER_PORT="$SERVER_PORT" ruby -rjson -e '
          path = ENV.fetch("CONFIG_FILE")
          port = Integer(ENV.fetch("SERVER_PORT"))
          data = JSON.parse(File.read(path))
          data["host"] = "0.0.0.0"
          data["port"] = port
          File.write(path, JSON.pretty_generate(data) + "\n")
        '
        success "已更新应用监听端口: ${config_file} -> ${SERVER_PORT}"
        return
    fi

    CONFIG_FILE="$config_file" SERVER_PORT="$SERVER_PORT" ruby -rjson -rsecurerandom -e '
      path = ENV.fetch("CONFIG_FILE")
      data = {
        "host" => "0.0.0.0",
        "port" => Integer(ENV.fetch("SERVER_PORT")),
        "apiKey" => "sk-kiro-rs-#{SecureRandom.alphanumeric(24)}",
        "adminApiKey" => "sk-admin-#{SecureRandom.alphanumeric(24)}",
        "region" => "us-east-1",
        "tlsBackend" => "rustls",
        "defaultEndpoint" => "ide"
      }
      File.write(path, JSON.pretty_generate(data) + "\n")
    '
    success "已生成应用配置: ${config_file}"
}
# ---- 启动服务 ----
start_services() {
    step "启动服务..."
    cd "${DEPLOY_DIR}"

    if [[ -z "$SOURCE_DIR" ]]; then
        # 远程模式：拉取镜像
        info "拉取镜像: ${KIRO_RS_IMAGE}..."
        docker compose pull
    else
        info "使用本地构建镜像: ${LOCAL_IMAGE_NAME}（跳过 pull）"
    fi

    docker compose up -d
    success "服务启动指令已发送"
}

# ---- 等待服务就绪 ----
# kiro.rs 无独立 /health 端点，通过容器状态 + /admin 静态页探测就绪
wait_for_ready() {
    step "等待服务就绪..."
    local timeout=90
    local elapsed=0
    local interval=3

    while [[ $elapsed -lt $timeout ]]; do
        local state
        state="$(docker inspect --format='{{.State.Status}}' kiro-rs 2>/dev/null || echo "missing")"

        # 探测 HTTP：/admin 返回任意 HTTP 状态码即视为端口已监听
        local http_code
        http_code="$(curl -s -o /dev/null -w "%{http_code}" \
            "http://localhost:${SERVER_PORT}/admin" 2>/dev/null || echo "000")"

        printf "\r  容器状态: %-10s | HTTP(/admin): %-4s  [%ds/%ds]" \
            "$state" "$http_code" "$elapsed" "$timeout"

        if [[ "$state" == "running" && "$http_code" != "000" ]]; then
            echo ""
            success "服务已就绪（HTTP ${http_code}）"
            return 0
        fi

        # 容器异常退出时立即报错
        if [[ "$state" == "exited" || "$state" == "dead" ]]; then
            echo ""
            error "容器异常退出，最近日志："
            docker compose -f "${DEPLOY_DIR}/docker-compose.yml" logs --tail=30 kiro-rs
            exit 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    warn "等待就绪超时（${timeout}s），服务可能仍在启动中。"
    warn "请运行以下命令查看状态："
    echo "  cd ${DEPLOY_DIR} && docker compose logs -f kiro-rs"
}

# ---- 读取自动生成的密钥 ----
# 首次启动容器会在 data/config.json 写入随机 apiKey / adminApiKey
read_keys() {
    local config_file="${DEPLOY_DIR}/data/config.json"
    local retries=10

    # 等待 config.json 落盘
    while [[ ! -f "$config_file" && $retries -gt 0 ]]; do
        sleep 1
        retries=$((retries - 1))
    done

    if [[ ! -f "$config_file" ]]; then
        warn "未找到 ${config_file}，密钥可能尚未生成，请稍后查看该文件。"
        return
    fi

    # 优先用 docker compose logs 抓取首启日志中的密钥（更直观）
    API_KEY="$(grep -oE '"apiKey"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null \
        | sed -E 's/.*"apiKey"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -1)"
    ADMIN_KEY="$(grep -oE '"adminApiKey"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null \
        | sed -E 's/.*"adminApiKey"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | head -1)"
}
# ---- 显示结果 ----
show_result() {
    echo ""
    echo -e "${GREEN}${BOLD}=========================================="
    echo "  ✅ kiro.rs 部署完成！"
    echo -e "==========================================${NC}"
    echo ""
    echo -e "  ${BOLD}API 地址:${NC}    http://localhost:${SERVER_PORT}/v1/messages"
    echo -e "  ${BOLD}管理面板:${NC}    http://localhost:${SERVER_PORT}/admin"
    echo -e "  ${BOLD}部署目录:${NC}    ${DEPLOY_DIR}"
    echo ""

    if [[ -n "${API_KEY:-}" || -n "${ADMIN_KEY:-}" ]]; then
        echo -e "  ${BOLD}密钥（已保存在 ${DEPLOY_DIR}/data/config.json）:${NC}"
        [[ -n "${API_KEY:-}" ]]   && echo "    apiKey      : ${API_KEY}    # 客户端调用，携带 x-api-key"
        [[ -n "${ADMIN_KEY:-}" ]] && echo "    adminApiKey : ${ADMIN_KEY}    # 登录管理面板"
        echo ""
        warn "上述密钥仅首次生成，请妥善保存。"
    else
        warn "未能自动读取密钥，请查看 ${DEPLOY_DIR}/data/config.json"
    fi
    echo ""

    echo -e "  ${BOLD}下一步:${NC}"
    echo "    1. 浏览器打开管理面板，用 adminApiKey 登录"
    echo "    2. 在「凭据管理」添加上游 Kiro 凭据（Social / IdC / API Key）"
    echo "    3. 即可通过 apiKey 调用 /v1/messages"
    echo ""

    echo -e "  ${BOLD}常用命令:${NC}"
    echo "    查看状态:   cd ${DEPLOY_DIR} && docker compose ps"
    echo "    查看日志:   cd ${DEPLOY_DIR} && docker compose logs -f kiro-rs"
    echo "    停止服务:   cd ${DEPLOY_DIR} && docker compose down"
    echo "    重启服务:   cd ${DEPLOY_DIR} && docker compose restart"
    if [[ -n "$SOURCE_DIR" ]]; then
        echo "    重新构建:   SOURCE_DIR=${SOURCE_DIR} $0"
    else
        echo "    更新版本:   cd ${DEPLOY_DIR} && docker compose pull && docker compose up -d"
    fi
    echo ""
    echo -e "  ${BOLD}Colima 管理:${NC}"
    echo "    查看状态:   colima status"
    echo "    停止 VM:    colima stop"
    echo "    启动 VM:    colima start"
    echo ""
    echo -e "  ${BOLD}备份:${NC}"
    echo "    cd ${DEPLOY_DIR} && docker compose down"
    echo "    tar czf kiro-rs-backup.tar.gz data/ docker-compose.yml"
    echo ""
}

# ---- 主流程 ----
main() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║   kiro.rs 一键部署 (macOS + Colima)      ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ -n "$SOURCE_DIR" ]]; then
        info "本地构建模式: SOURCE_DIR=${SOURCE_DIR}"
    else
        info "远程镜像模式: ${KIRO_RS_IMAGE}"
    fi
    echo ""

    check_macos
    ensure_homebrew
    ensure_colima
    start_colima
    check_mount_scope
    build_local_image
    prepare_deploy_dir
    start_services
    wait_for_ready
    read_keys
    show_result
}

main "$@"
