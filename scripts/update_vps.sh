#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# kiro-rs VPS 更新脚本
# 用途: 上传源码到 VPS -> 在 VPS 构建带版本号镜像 -> 重启服务
# 用法: bash scripts/update_vps.sh [--tag 0.6.1] [--ssh-target root@IP] [--remote-dir /opt/kiro-rs]
#
# 约束:
#   1. 远程部署目录必须位于 /opt/ 下
#   2. 镜像 tag 必填，默认 0.6.1
#   3. 镜像在 VPS 上基于上传源码构建
# ============================================================

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_TARGET="${SSH_TARGET:-root@138.197.121.229}"
REMOTE_DIR="${REMOTE_DIR:-/opt/kiro-rs}"
CONTROL_PATH="/tmp/kiro-rs-update.sock"
SERVICE_NAME="kiro-rs"
CONTAINER_NAME="kiro-rs"
IMAGE_NAME="${IMAGE_NAME:-kiro-rs}"
IMAGE_TAG="${IMAGE_TAG:-0.6.1}"
HOST_PORT="${HOST_PORT:-8990}"
CONTAINER_PORT="8990"
HEALTH_PATH="${HEALTH_PATH:-/admin}"

info()  { printf '\033[32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m  %s\n' "$*"; }
error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
用法:
  bash scripts/update_vps.sh --tag 0.6.1 [--ssh-target root@IP] [--remote-dir /opt/kiro-rs]

说明:
  上传当前源码到 VPS，在 VPS 上构建镜像并重启 kiro-rs 服务。
  SSH 密码只需在建立主连接时输入一次，后续操作复用同一连接。

参数:
  --tag           镜像版本号（默认 0.6.1，不能为空）
  --ssh-target    SSH 目标（默认 root@138.197.121.229）
  --remote-dir    远程部署目录（默认 /opt/kiro-rs，必须位于 /opt/ 下）
  --host-port     宿主机端口（默认 8990）
  --health-path   健康检查路径（默认 /admin）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            [ $# -ge 2 ] || error "--tag 缺少参数"
            IMAGE_TAG="$2"
            shift 2
            ;;
        --ssh-target)
            [ $# -ge 2 ] || error "--ssh-target 缺少参数"
            SSH_TARGET="$2"
            shift 2
            ;;
        --remote-dir)
            [ $# -ge 2 ] || error "--remote-dir 缺少参数"
            REMOTE_DIR="$2"
            shift 2
            ;;
        --host-port)
            [ $# -ge 2 ] || error "--host-port 缺少参数"
            HOST_PORT="$2"
            shift 2
            ;;
        --health-path)
            [ $# -ge 2 ] || error "--health-path 缺少参数"
            HEALTH_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "未知参数: $1"
            ;;
    esac
done

validate_inputs() {
    [ -n "${IMAGE_TAG}" ] || error "镜像 tag 不能为空"
    case "${REMOTE_DIR}" in
        /opt/*) ;;
        *) error "远程部署目录必须位于 /opt/ 下，当前为: ${REMOTE_DIR}" ;;
    esac
}

quote_remote() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

ssh_opts() {
    printf '%s\n' \
        "-o" "ControlMaster=auto" \
        "-o" "ControlPersist=600" \
        "-o" "ControlPath=${CONTROL_PATH}" \
        "-o" "StrictHostKeyChecking=accept-new"
}

remote() {
    ssh $(ssh_opts) "${SSH_TARGET}" "$@"
}

open_master_connection() {
    info "建立 SSH 主连接（仅此处可能需要输入密码）..."
    rm -f "${CONTROL_PATH}"
    ssh $(ssh_opts) -MNf "${SSH_TARGET}"
}

cleanup() {
    ssh $(ssh_opts) -O exit "${SSH_TARGET}" >/dev/null 2>&1 || true
    rm -f "${CONTROL_PATH}"
}

create_source_archive() {
    local tar_args=(
        --exclude=.git
        --exclude=.cache
        --exclude=.idea
        --exclude=target
        --exclude=admin-ui/node_modules
        --exclude=admin-ui/dist
        --exclude=admin-ui/.vite
        --exclude=data
        --exclude='*.tar.gz'
        --exclude=.DS_Store
        --exclude='._*'
        --exclude=config.json
        --exclude=credentials.json
        --exclude='credentials.*.json'
        --exclude=client_api_keys.json
        --exclude=kiro_balance_cache.json
        --exclude=kiro_stats.json
        --exclude=proxy_pool.json
        --exclude='usage_log.*.jsonl'
        --exclude=usage_stats.json
        --exclude=prompt_cache.json
        --exclude=traces.db
        --exclude=traces.db-shm
        --exclude=traces.db-wal
        -czf - -C "${ROOT_DIR}" .
    )

    if [ "$(uname -s)" = "Darwin" ]; then
        COPYFILE_DISABLE=1 tar --no-mac-metadata "${tar_args[@]}"
    else
        tar "${tar_args[@]}"
    fi
}

upload_source() {
    local remote_dir
    remote_dir="$(quote_remote "${REMOTE_DIR}")"

    info "打包并上传源码到 ${SSH_TARGET}:${REMOTE_DIR}/source ..."
    create_source_archive | remote "set -Eeuo pipefail
        rm -rf ${remote_dir}/source.tmp
        mkdir -p ${remote_dir}/source.tmp
        tar -xzf - -C ${remote_dir}/source.tmp
        if [ -d ${remote_dir}/source ]; then
            rm -rf ${remote_dir}/source.prev
            mv ${remote_dir}/source ${remote_dir}/source.prev
        fi
        mv ${remote_dir}/source.tmp ${remote_dir}/source"
    info "源码上传完成。"
}

ensure_remote_compose() {
    local remote_dir
    remote_dir="$(quote_remote "${REMOTE_DIR}")"

    info "写入远程 docker-compose.yml，镜像版本为 ${IMAGE_NAME}:${IMAGE_TAG} ..."
    remote "mkdir -p ${remote_dir}/data"
    create_remote_compose | remote "cat > ${remote_dir}/docker-compose.yml"
}

create_remote_compose() {
    cat <<EOF
services:
  ${SERVICE_NAME}:
    build:
      context: ./source
      dockerfile: Dockerfile
    image: ${IMAGE_NAME}:${IMAGE_TAG}
    container_name: ${CONTAINER_NAME}
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "${HOST_PORT}:${CONTAINER_PORT}"
    volumes:
      - ./data/:/app/config/
    restart: unless-stopped
EOF
}

rebuild_and_restart() {
    local remote_dir service_name image_name image_tag
    remote_dir="$(quote_remote "${REMOTE_DIR}")"
    service_name="$(quote_remote "${SERVICE_NAME}")"
    image_name="$(quote_remote "${IMAGE_NAME}")"
    image_tag="$(quote_remote "${IMAGE_TAG}")"

    info "在 VPS 上构建镜像 ${IMAGE_NAME}:${IMAGE_TAG} 并重启服务..."
    remote "cd ${remote_dir} && docker compose build --no-cache ${service_name} && docker image inspect ${image_name}:${image_tag} >/dev/null && docker compose up -d --remove-orphans ${service_name}"
    info "构建并重启完成。"
}

wait_for_health() {
    info "等待服务健康检查通过..."
    local max_wait=60
    local target_host="${SSH_TARGET#*@}"

    for i in $(seq 1 "${max_wait}"); do
        local http_code status
        http_code="$(remote "curl -fsS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:${HOST_PORT}${HEALTH_PATH}' 2>/dev/null" || true)"
        if [ "${http_code}" = "200" ]; then
            info "健康检查已通过。"
            return
        fi

        status="$(remote "docker inspect --format '{{.State.Status}}' '${CONTAINER_NAME}' 2>/dev/null" || true)"
        case "${status}" in
            exited|dead)
                warn "容器状态异常: ${status}，拉取最近日志..."
                remote "docker logs --tail 80 '${CONTAINER_NAME}'" || true
                error "部署失败，容器未正常启动。"
                ;;
            *)
                printf "\r  等待中... (%d/%d) http://%s:%s%s" "$i" "$max_wait" "${target_host}" "${HOST_PORT}" "${HEALTH_PATH}"
                sleep 5
                ;;
        esac
    done

    echo ""
    warn "健康检查超时，拉取容器日志..."
    remote "docker logs --tail 120 '${CONTAINER_NAME}'" || true
    error "服务未在 $((max_wait * 5)) 秒内通过健康检查。"
}

print_summary() {
    local remote_dir target_host
    remote_dir="$(quote_remote "${REMOTE_DIR}")"
    target_host="${SSH_TARGET#*@}"

    echo ""
    info "更新部署完成。"
    echo "  VPS:      ${SSH_TARGET}"
    echo "  镜像版本: ${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  部署目录: ${REMOTE_DIR}"
    echo "  管理面板: http://${target_host}:${HOST_PORT}/admin"
    echo "  健康检查: http://${target_host}:${HOST_PORT}${HEALTH_PATH}"
    echo ""
    remote "cd ${remote_dir} && docker compose ps"
}

main() {
    validate_inputs
    trap cleanup EXIT
    open_master_connection
    upload_source
    ensure_remote_compose
    rebuild_and_restart
    wait_for_health
    print_summary
}

main "$@"
