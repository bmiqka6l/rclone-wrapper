#!/bin/bash
set -e

# ==================== 0. 环境变量读取 ====================

# 必填配置
RCLONE_CONFIG_B64="$RW_RCLONE_CONFIG"
BASE_DIR="$RW_BASE_DIR"
SYNC_MAP="$RW_SYNC_MAP"

# 可选配置
REMOTE_NAME="${RW_REMOTE_NAME:-}"
INTERVAL="${RW_INTERVAL:-300}"
RCLONE_FLAGS="${RW_RCLONE_FLAGS:-}"

# 默认 rclone 优化参数（如果用户未指定）
if [ -z "$RCLONE_FLAGS" ]; then
    # 设置合理的默认值：
    # --transfers=4: 并发传输 4 个文件（平衡速度和资源）
    # --checkers=8: 并发检查 8 个文件
    # --contimeout=60s: 连接超时 60 秒
    # --timeout=300s: 传输超时 5 分钟
    # --retries=3: 失败重试 3 次
    RCLONE_FLAGS="--transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3"
    log_debug "Using default rclone flags: $RCLONE_FLAGS"
fi

# 快照配置
SNAPSHOT_ENABLED="${RW_SNAPSHOT_ENABLED:-true}"
SNAPSHOT_INTERVAL="${RW_SNAPSHOT_INTERVAL:-900}"
SNAPSHOT_KEEP_RECENT="${RW_SNAPSHOT_KEEP_RECENT:-10}"
SNAPSHOT_KEEP_DAYS="${RW_SNAPSHOT_KEEP_DAYS:-7}"

# 调试配置
DEBUG="${RW_DEBUG:-false}"

# 继承的原始镜像参数
ORIGINAL_ENTRYPOINT="$RW_ORIGINAL_ENTRYPOINT"
ORIGINAL_CMD="$RW_ORIGINAL_CMD"
ORIGINAL_WORKDIR="$RW_ORIGINAL_WORKDIR"

# 全局变量
APP_PID=""
BACKUP_PID=""
SNAPSHOT_PID=""

# ==================== 1. 日志函数 ====================

log_info() {
    echo "[RcloneWrapper] [INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo "[RcloneWrapper] [WARN] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() {
    echo "[RcloneWrapper] [ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "[RcloneWrapper] [DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*"
    fi
}

# ==================== 2. 配置管理模块 ====================

init_config() {
    log_info ">>> Initializing configuration..."
    
    # 验证必填环境变量
    if [ -z "$RCLONE_CONFIG_B64" ] || [ -z "$BASE_DIR" ] || [ -z "$SYNC_MAP" ]; then
        log_error "Missing required environment variables!"
        log_error "Required: RW_RCLONE_CONFIG, RW_BASE_DIR, RW_SYNC_MAP"
        exit 1
    fi
    
    # 解码并写入 rclone 配置
    mkdir -p /root/.config/rclone
    if ! echo "$RCLONE_CONFIG_B64" | base64 -d > /root/.config/rclone/rclone.conf 2>/dev/null; then
        log_error "Failed to decode RW_RCLONE_CONFIG (invalid BASE64)"
        exit 1
    fi
    
    log_debug "Rclone config written to /root/.config/rclone/rclone.conf"
    
    # 验证 rclone 配置有效性
    if ! rclone listremotes > /dev/null 2>&1; then
        log_error "Invalid rclone configuration (rclone listremotes failed)"
        exit 1
    fi
    
    # 确定 REMOTE_NAME
    if [ -z "$REMOTE_NAME" ]; then
        REMOTE_NAME=$(rclone listremotes | head -n1 | tr -d ':')
        log_info "Auto-detected remote: $REMOTE_NAME"
    fi
    
    # 输出配置摘要（脱敏）
    log_info "Configuration Summary:"
    log_info "  Remote: $REMOTE_NAME"
    log_info "  Base Dir: $BASE_DIR"
    log_info "  Sync Map: $SYNC_MAP"
    log_info "  Backup Interval: ${INTERVAL}s"
    log_info "  Snapshot Enabled: $SNAPSHOT_ENABLED"
    if [ "$SNAPSHOT_ENABLED" = "true" ]; then
        log_info "  Snapshot Interval: ${SNAPSHOT_INTERVAL}s"
        log_info "  Snapshot Keep Recent: $SNAPSHOT_KEEP_RECENT"
        log_info "  Snapshot Keep Days: $SNAPSHOT_KEEP_DAYS"
    fi
    log_info "  Rclone Config Length: ${#RCLONE_CONFIG_B64} chars (BASE64)"
    
    log_info "Configuration initialized successfully"
}

# ==================== 3. 数据恢复模块 ====================

restore_data() {
    log_info ">>> Restoring data from cloud storage..."
    local start_time=$(date +%s)
    
    # 解析 SYNC_MAP: src_dir1:/container/path1;src_dir2:/container/path2
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    for MAPPING in "${MAPPINGS[@]}"; do
        # 跳过空映射
        if [ -z "$MAPPING" ]; then
            continue
        fi
        
        # 解析映射：src_dir:/container/path
        SRC_DIR=$(echo "$MAPPING" | cut -d':' -f1)
        LOCAL_PATH=$(echo "$MAPPING" | cut -d':' -f2)
        REMOTE_PATH="${REMOTE_NAME}:${BASE_DIR}/${SRC_DIR}"
        
        log_info "Restoring: $REMOTE_PATH -> $LOCAL_PATH"
        
        # 检查远程路径是否存在
        if ! rclone lsf "$REMOTE_PATH" > /dev/null 2>&1; then
            log_warn "Remote path not found (new container init): $REMOTE_PATH"
            log_info "Creating empty directory: $LOCAL_PATH"
            mkdir -p "$LOCAL_PATH"
            continue
        fi
        
        # 删除本地旧数据并创建新目录
        log_debug "Removing old local data: $LOCAL_PATH"
        rm -rf "$LOCAL_PATH"
        mkdir -p "$LOCAL_PATH"
        
        # 执行 rclone sync（云端 -> 本地），排除快照目录
        log_debug "Syncing from cloud to local..."
        if rclone sync "$REMOTE_PATH" "$LOCAL_PATH" \
            --exclude "snapshots/**" \
            ${RCLONE_FLAGS} \
            --log-level INFO 2>&1 | grep -v "^20" || true; then
            log_info "Restore success: $SRC_DIR"
        else
            log_error "Restore failed: $SRC_DIR (continuing anyway)"
        fi
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Restore complete (${elapsed}s)"
}

# ==================== 4. 数据备份模块 ====================

backup_data() {
    log_info ">>> Backing up data to cloud storage..."
    local start_time=$(date +%s)
    
    # 解析 SYNC_MAP
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    for MAPPING in "${MAPPINGS[@]}"; do
        # 跳过空映射
        if [ -z "$MAPPING" ]; then
            continue
        fi
        
        # 解析映射
        SRC_DIR=$(echo "$MAPPING" | cut -d':' -f1)
        LOCAL_PATH=$(echo "$MAPPING" | cut -d':' -f2)
        REMOTE_PATH="${REMOTE_NAME}:${BASE_DIR}/${SRC_DIR}"
        
        # 检查本地路径是否存在
        if [ ! -e "$LOCAL_PATH" ]; then
            log_warn "Local path not found, skipping: $LOCAL_PATH"
            continue
        fi
        
        log_info "Backing up: $LOCAL_PATH -> $REMOTE_PATH"
        
        # 执行 rclone sync（本地 -> 云端）
        log_debug "Syncing from local to cloud..."
        if rclone sync "$LOCAL_PATH" "$REMOTE_PATH" \
            ${RCLONE_FLAGS} \
            --log-level INFO 2>&1 | grep -v "^20" || true; then
            log_info "Backup success: $SRC_DIR"
        else
            log_error "Backup failed: $SRC_DIR (will retry next cycle)"
        fi
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Backup complete (${elapsed}s)"
}

# ==================== 5. 快照管理模块 ====================

create_snapshot() {
    if [ "$SNAPSHOT_ENABLED" != "true" ]; then
        return
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local snapshot_base="${REMOTE_NAME}:${BASE_DIR}/snapshots/${timestamp}"
    
    log_info ">>> Creating snapshot: $timestamp"
    local start_time=$(date +%s)
    
    # 解析 SYNC_MAP
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    for MAPPING in "${MAPPINGS[@]}"; do
        # 跳过空映射
        if [ -z "$MAPPING" ]; then
            continue
        fi
        
        # 解析映射
        SRC_DIR=$(echo "$MAPPING" | cut -d':' -f1)
        LOCAL_PATH=$(echo "$MAPPING" | cut -d':' -f2)
        SNAPSHOT_PATH="${snapshot_base}/${SRC_DIR}"
        
        # 检查本地路径是否存在
        if [ ! -e "$LOCAL_PATH" ]; then
            log_debug "Local path not found, skipping snapshot: $LOCAL_PATH"
            continue
        fi
        
        log_debug "Snapshotting: $LOCAL_PATH -> $SNAPSHOT_PATH"
        
        # 使用 rclone copy（而非 sync）保留历史版本
        if rclone copy "$LOCAL_PATH" "$SNAPSHOT_PATH" \
            ${RCLONE_FLAGS} \
            --log-level ERROR 2>&1 | grep -v "^20" || true; then
            log_debug "Snapshot success: $SRC_DIR"
        else
            log_error "Snapshot failed: $SRC_DIR"
        fi
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Snapshot complete (${elapsed}s)"
    
    # 清理旧快照
    cleanup_snapshots
}

cleanup_snapshots() {
    log_debug ">>> Cleaning up old snapshots..."
    
    local snapshots_base="${REMOTE_NAME}:${BASE_DIR}/snapshots"
    
    # 获取所有快照列表（按时间排序，最新的在前）
    local snapshots=$(rclone lsf "$snapshots_base" --dirs-only 2>/dev/null | sort -r || echo "")
    
    if [ -z "$snapshots" ]; then
        log_debug "No snapshots found"
        return
    fi
    
    # 保留最近 N 个快照
    local keep_list=""
    local count=0
    
    for snapshot in $snapshots; do
        if [ $count -lt $SNAPSHOT_KEEP_RECENT ]; then
            keep_list="$keep_list $snapshot"
            count=$((count + 1))
        fi
    done
    
    # 保留最近 N 天的每日快照（每天保留最早的一个）
    local cutoff_date=$(date -d "$SNAPSHOT_KEEP_DAYS days ago" +%Y%m%d 2>/dev/null || date -v-${SNAPSHOT_KEEP_DAYS}d +%Y%m%d 2>/dev/null || echo "19700101")
    local daily_snapshots=$(echo "$snapshots" | grep -E "^[0-9]{8}_" | cut -d'_' -f1 | sort -u || echo "")
    
    for day in $daily_snapshots; do
        if [ "$day" -ge "$cutoff_date" ]; then
            # 找到该天最早的快照（列表已按时间倒序，所以取最后一个）
            local first_of_day=$(echo "$snapshots" | grep "^${day}_" | tail -n1)
            if [ -n "$first_of_day" ]; then
                keep_list="$keep_list $first_of_day"
            fi
        fi
    done
    
    # 删除不在保留列表中的快照
    for snapshot in $snapshots; do
        if ! echo "$keep_list" | grep -q "$snapshot"; then
            log_info "Deleting old snapshot: $snapshot"
            rclone purge "${snapshots_base}/${snapshot}" --log-level ERROR 2>&1 | grep -v "^20" || true
        fi
    done
    
    log_debug "Snapshot cleanup complete"
}

# ==================== 6. 信号处理和优雅关闭 ====================

shutdown_handler() {
    log_info "!!! Shutting down..."
    
    # 1. 停止主应用进程
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        log_info "Stopping main app (PID: $APP_PID)"
        kill -SIGTERM "$APP_PID" 2>/dev/null || true
        
        # 等待最多 30 秒
        local timeout=30
        while [ $timeout -gt 0 ] && kill -0 "$APP_PID" 2>/dev/null; do
            sleep 1
            timeout=$((timeout - 1))
        done
        
        # 强制杀死
        if kill -0 "$APP_PID" 2>/dev/null; then
            log_warn "Force killing app (timeout)"
            kill -SIGKILL "$APP_PID" 2>/dev/null || true
        fi
    fi
    
    # 2. 停止后台进程
    if [ -n "$BACKUP_PID" ]; then
        kill -SIGTERM "$BACKUP_PID" 2>/dev/null || true
    fi
    
    if [ -n "$SNAPSHOT_PID" ]; then
        kill -SIGTERM "$SNAPSHOT_PID" 2>/dev/null || true
    fi
    
    # 3. 最后一次强制备份
    log_info "Performing final backup..."
    backup_data
    
    log_info "Shutdown complete"
    exit 0
}

# ==================== 7. 主应用启动模块 ====================

start_main_app() {
    log_info ">>> Starting main app..."
    
    # 切换到原始工作目录
    if [ -n "$ORIGINAL_WORKDIR" ]; then
        log_debug "Changing to workdir: $ORIGINAL_WORKDIR"
        cd "$ORIGINAL_WORKDIR" || cd /
    else
        cd /
    fi
    
    # 构造命令
    local final_args=""
    if [ -n "$*" ]; then
        final_args="$*"
    else
        final_args="$ORIGINAL_CMD"
    fi
    
    local cmd_str=""
    if [ -n "$ORIGINAL_ENTRYPOINT" ]; then
        cmd_str="$ORIGINAL_ENTRYPOINT $final_args"
    else
        cmd_str="$final_args"
    fi
    
    if [ -z "$cmd_str" ]; then
        log_error "No command specified (ENTRYPOINT and CMD are both empty)"
        exit 1
    fi
    
    log_debug "WorkDir: $ORIGINAL_WORKDIR"
    log_debug "Entrypoint: $ORIGINAL_ENTRYPOINT"
    log_debug "CMD: $ORIGINAL_CMD"
    log_debug "Executing: $cmd_str"
    
    # 启动主应用（前台进程）
    set -m
    $cmd_str 2>&1 &
    APP_PID=$!
    
    log_debug "App PID: $APP_PID"
    
    # 验证启动成功（等待 3 秒）
    sleep 3
    
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log_error "App died immediately after start"
        wait "$APP_PID" 2>/dev/null || true
        local exit_code=$?
        log_error "App exit code: $exit_code"
        exit $exit_code
    fi
    
    log_info "App is running (PID: $APP_PID)"
    
    # 等待主应用退出
    wait "$APP_PID"
}

# ==================== 8. 主流程 ====================

main() {
    log_info "========================================="
    log_info "  Rclone Wrapper Starting"
    log_info "========================================="
    
    # 1. 初始化配置
    init_config
    
    # 2. 恢复数据
    restore_data
    
    # 3. 注册信号处理器
    trap 'shutdown_handler' SIGTERM SIGINT
    
    # 4. 启动后台备份循环
    (
        while true; do
            sleep "$INTERVAL"
            backup_data
        done
    ) &
    BACKUP_PID=$!
    log_info "Backup loop started (PID: $BACKUP_PID, interval: ${INTERVAL}s)"
    
    # 5. 启动后台快照循环（如果启用）
    if [ "$SNAPSHOT_ENABLED" = "true" ]; then
        (
            while true; do
                sleep "$SNAPSHOT_INTERVAL"
                create_snapshot
            done
        ) &
        SNAPSHOT_PID=$!
        log_info "Snapshot loop started (PID: $SNAPSHOT_PID, interval: ${SNAPSHOT_INTERVAL}s)"
    fi
    
    # 6. 启动主应用（前台，会阻塞直到应用退出）
    start_main_app "$@"
}

# 执行主流程
main "$@"

