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
    RCLONE_FLAGS="--transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3"
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
    
    if [ -z "$RCLONE_CONFIG_B64" ] || [ -z "$BASE_DIR" ] || [ -z "$SYNC_MAP" ]; then
        log_error "Missing required environment variables!"
        log_error "Required: RW_RCLONE_CONFIG, RW_BASE_DIR, RW_SYNC_MAP"
        log_warn "Wrapper will start container without sync functionality"
        return 1
    fi
    
    mkdir -p /root/.config/rclone
    if ! echo "$RCLONE_CONFIG_B64" | base64 -d > /root/.config/rclone/rclone.conf 2>/dev/null; then
        log_error "Failed to decode RW_RCLONE_CONFIG (invalid BASE64)"
        log_warn "Wrapper will start container without sync functionality"
        return 1
    fi
    
    log_debug "Rclone config written to /root/.config/rclone/rclone.conf"
    
    if ! rclone listremotes > /dev/null 2>&1; then
        log_error "Invalid rclone configuration (rclone listremotes failed)"
        log_warn "Wrapper will start container without sync functionality"
        return 1
    fi
    
    if [ -z "$REMOTE_NAME" ]; then
        REMOTE_NAME=$(rclone listremotes | head -n1 | tr -d ':')
        log_info "Auto-detected remote: $REMOTE_NAME"
    fi
    
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
    return 0
}

# ==================== 3. 数据恢复模块（ZIP 方式）====================

restore_data() {
    log_info ">>> Restoring data from cloud storage..."
    local start_time=$(date +%s)
    
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    for MAPPING in "${MAPPINGS[@]}"; do
        if [ -z "$MAPPING" ]; then
            continue
        fi
        
        IFS=':' read -ra PARTS <<< "$MAPPING"
        local path_type=""
        local src_dir=""
        local local_path=""
        
        if [ ${#PARTS[@]} -eq 3 ]; then
            path_type="${PARTS[0]}"
            src_dir="${PARTS[1]}"
            local_path="${PARTS[2]}"
        elif [ ${#PARTS[@]} -eq 2 ]; then
            src_dir="${PARTS[0]}"
            local_path="${PARTS[1]}"
            if [[ "$local_path" =~ \.[a-zA-Z0-9]+$ ]]; then
                path_type="file"
            else
                path_type="dir"
            fi
        else
            log_error "Invalid SYNC_MAP format: $MAPPING"
            continue
        fi
        
        local remote_zip="${REMOTE_NAME}:${BASE_DIR}/${src_dir}.zip"
        
        log_info "Restoring: $remote_zip -> $local_path (type: $path_type)"
        
        if ! rclone lsf "$remote_zip" > /dev/null 2>&1; then
            log_warn "Remote zip not found (new container init): $remote_zip"
            
            if [ "$path_type" = "dir" ]; then
                log_info "Creating directory for app: $local_path"
                mkdir -p "$local_path"
            else
                log_info "Skipping file creation, let app initialize: $local_path"
            fi
            
            continue
        fi
        
        log_debug "Removing old local data: $local_path"
        rm -rf "$local_path"
        
        mkdir -p "$(dirname "$local_path")"
        
        local temp_dir="/tmp/rclone-restore-$$-$(date +%s)"
        mkdir -p "$temp_dir"
        
        log_debug "Downloading zip from cloud: $remote_zip -> $temp_dir/data.zip"
        if rclone copyto "$remote_zip" "$temp_dir/data.zip" \
            ${RCLONE_FLAGS} \
            --log-level INFO 2>&1 | grep -v "^20" || true; then
            
            log_debug "Extracting zip: $temp_dir/data.zip"
            
            if [ "$path_type" = "file" ]; then
                unzip -q "$temp_dir/data.zip" -d "$temp_dir/extract" 2>/dev/null || true
                local first_file=$(find "$temp_dir/extract" -type f | head -n1)
                if [ -n "$first_file" ]; then
                    cp "$first_file" "$local_path"
                fi
            else
                mkdir -p "$local_path"
                unzip -q "$temp_dir/data.zip" -d "$local_path" 2>/dev/null || true
            fi
            
            rm -rf "$temp_dir"
            
            log_info "Restore success: $src_dir"
        else
            log_error "Restore failed: $src_dir (continuing anyway)"
            rm -rf "$temp_dir"
        fi
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Restore complete (${elapsed}s)"
}

# ==================== 4. 数据备份模块（ZIP 方式）====================

backup_data() {
    log_info ">>> Backing up data to cloud storage..."
    local start_time=$(date +%s)
    
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    for MAPPING in "${MAPPINGS[@]}"; do
        if [ -z "$MAPPING" ]; then
            continue
        fi
        
        IFS=':' read -ra PARTS <<< "$MAPPING"
        local path_type=""
        local src_dir=""
        local local_path=""
        
        if [ ${#PARTS[@]} -eq 3 ]; then
            path_type="${PARTS[0]}"
            src_dir="${PARTS[1]}"
            local_path="${PARTS[2]}"
        elif [ ${#PARTS[@]} -eq 2 ]; then
            src_dir="${PARTS[0]}"
            local_path="${PARTS[1]}"
            path_type="auto"
        else
            log_error "Invalid SYNC_MAP format: $MAPPING"
            continue
        fi
        
        local remote_zip="${REMOTE_NAME}:${BASE_DIR}/${src_dir}.zip"
        
        if [ ! -e "$local_path" ]; then
            log_warn "Local path not found, skipping: $local_path"
            continue
        fi
        
        if [ "$path_type" = "auto" ]; then
            if [ -f "$local_path" ]; then
                path_type="file"
            elif [ -d "$local_path" ]; then
                path_type="dir"
            else
                log_warn "Unknown path type: $local_path"
                continue
            fi
        fi
        
        log_info "Backing up: $local_path -> $remote_zip (type: $path_type)"
        
        local temp_dir="/tmp/rclone-backup-$$-$(date +%s)"
        mkdir -p "$temp_dir/staging"
        
        log_debug "Copying to staging: $local_path -> $temp_dir/staging"
        
        if [ "$path_type" = "file" ]; then
            if [ -f "$local_path" ]; then
                cp "$local_path" "$temp_dir/staging/"
            else
                log_warn "Path type mismatch: expected file, got directory: $local_path"
                rm -rf "$temp_dir"
                continue
            fi
        else
            if [ -d "$local_path" ]; then
                if [ "$(ls -A $local_path 2>/dev/null)" ]; then
                    cp -r "$local_path"/* "$temp_dir/staging/" 2>/dev/null || true
                    cp -r "$local_path"/.[!.]* "$temp_dir/staging/" 2>/dev/null || true
                fi
            else
                log_warn "Path type mismatch: expected directory, got file: $local_path"
                rm -rf "$temp_dir"
                continue
            fi
        fi
        
        log_debug "Creating zip archive: $temp_dir/staging -> $temp_dir/data.zip"
        (cd "$temp_dir/staging" && zip -qr "$temp_dir/data.zip" . 2>/dev/null) || true
        
        log_debug "Uploading zip to cloud: $temp_dir/data.zip -> $remote_zip"
        
        if rclone copyto "$temp_dir/data.zip" "$remote_zip" \
            ${RCLONE_FLAGS} \
            --log-level INFO 2>&1 | grep -v "^20" || true; then
            log_info "Backup success: $src_dir"
        else
            log_error "Backup failed: $src_dir (will retry next cycle)"
        fi
        
        rm -rf "$temp_dir"
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Backup complete (${elapsed}s)"
}

# ==================== 5. 快照管理模块（ZIP 方式）====================

create_snapshot() {
    if [ "$SNAPSHOT_ENABLED" != "true" ]; then
        return
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local snapshot_base="${REMOTE_NAME}:${BASE_DIR}/snapshots"
    
    log_info ">>> Creating snapshot: $timestamp"
    local start_time=$(date +%s)
    
    IFS=';' read -ra MAPPINGS <<< "$SYNC_MAP"
    
    for MAPPING in "${MAPPINGS[@]}"; do
        if [ -z "$MAPPING" ]; then
            continue
        fi
        
        IFS=':' read -ra PARTS <<< "$MAPPING"
        local src_dir=""
        local local_path=""
        
        if [ ${#PARTS[@]} -eq 3 ]; then
            src_dir="${PARTS[1]}"
            local_path="${PARTS[2]}"
        elif [ ${#PARTS[@]} -eq 2 ]; then
            src_dir="${PARTS[0]}"
            local_path="${PARTS[1]}"
        else
            continue
        fi
        
        if [ ! -e "$local_path" ]; then
            log_debug "Local path not found, skipping snapshot: $local_path"
            continue
        fi
        
        local snapshot_zip="${snapshot_base}/${timestamp}_${src_dir}.zip"
        
        log_debug "Snapshotting: $local_path -> $snapshot_zip"
        
        local temp_dir="/tmp/rclone-snapshot-$$-$(date +%s)"
        mkdir -p "$temp_dir/staging"
        
        log_debug "Copying to staging: $local_path -> $temp_dir/staging"
        
        if [ -f "$local_path" ]; then
            cp "$local_path" "$temp_dir/staging/"
        elif [ -d "$local_path" ]; then
            if [ "$(ls -A $local_path 2>/dev/null)" ]; then
                cp -r "$local_path"/* "$temp_dir/staging/" 2>/dev/null || true
                cp -r "$local_path"/.[!.]* "$temp_dir/staging/" 2>/dev/null || true
            fi
        fi
        
        log_debug "Creating zip archive: $temp_dir/staging -> $temp_dir/snapshot.zip"
        (cd "$temp_dir/staging" && zip -qr "$temp_dir/snapshot.zip" . 2>/dev/null) || true
        
        if rclone copyto "$temp_dir/snapshot.zip" "$snapshot_zip" \
            ${RCLONE_FLAGS} \
            --log-level ERROR 2>&1 | grep -v "^20" || true; then
            log_debug "Snapshot success: $src_dir"
        else
            log_error "Snapshot failed: $src_dir"
        fi
        
        rm -rf "$temp_dir"
    done
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "Snapshot complete (${elapsed}s)"
    
    cleanup_snapshots
}

cleanup_snapshots() {
    log_debug ">>> Cleaning up old snapshots..."
    
    local snapshots_base="${REMOTE_NAME}:${BASE_DIR}/snapshots"
    
    local snapshots=$(rclone lsf "$snapshots_base" --files-only 2>/dev/null | grep '\.zip$' | sort -r || echo "")
    
    if [ -z "$snapshots" ]; then
        log_debug "No snapshots found"
        return
    fi
    
    local keep_list=""
    local count=0
    
    for snapshot in $snapshots; do
        if [ $count -lt $SNAPSHOT_KEEP_RECENT ]; then
            keep_list="$keep_list $snapshot"
            count=$((count + 1))
        fi
    done
    
    local cutoff_date=$(date -d "$SNAPSHOT_KEEP_DAYS days ago" +%Y%m%d 2>/dev/null || date -v-${SNAPSHOT_KEEP_DAYS}d +%Y%m%d 2>/dev/null || echo "19700101")
    local daily_snapshots=$(echo "$snapshots" | grep -E "^[0-9]{8}_" | cut -d'_' -f1 | sort -u || echo "")
    
    for day in $daily_snapshots; do
        if [ "$day" -ge "$cutoff_date" ]; then
            local first_of_day=$(echo "$snapshots" | grep "^${day}_" | tail -n1)
            if [ -n "$first_of_day" ]; then
                keep_list="$keep_list $first_of_day"
            fi
        fi
    done
    
    for snapshot in $snapshots; do
        if ! echo "$keep_list" | grep -q "$snapshot"; then
            log_info "Deleting old snapshot: $snapshot"
            rclone deletefile "${snapshots_base}/${snapshot}" --log-level ERROR 2>&1 | grep -v "^20" || true
        fi
    done
    
    log_debug "Snapshot cleanup complete"
}

# ==================== 6. 信号处理和优雅关闭 ====================

shutdown_handler() {
    log_info "!!! Shutting down..."
    
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        log_info "Stopping main app (PID: $APP_PID)"
        kill -SIGTERM "$APP_PID" 2>/dev/null || true
        
        local timeout=30
        while [ $timeout -gt 0 ] && kill -0 "$APP_PID" 2>/dev/null; do
            sleep 1
            timeout=$((timeout - 1))
        done
        
        if kill -0 "$APP_PID" 2>/dev/null; then
            log_warn "Force killing app (timeout)"
            kill -SIGKILL "$APP_PID" 2>/dev/null || true
        fi
    fi
    
    if [ -n "$BACKUP_PID" ]; then
        kill -SIGTERM "$BACKUP_PID" 2>/dev/null || true
    fi
    
    if [ -n "$SNAPSHOT_PID" ]; then
        kill -SIGTERM "$SNAPSHOT_PID" 2>/dev/null || true
    fi
    
    log_info "Performing final backup..."
    backup_data
    
    log_info "Shutdown complete"
    exit 0
}

# ==================== 7. 主应用启动模块 ====================

start_main_app() {
    log_info ">>> Starting main app..."
    
    if [ -n "$ORIGINAL_WORKDIR" ]; then
        log_debug "Changing to workdir: $ORIGINAL_WORKDIR"
        cd "$ORIGINAL_WORKDIR" || cd /
    else
        cd /
    fi
    
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
    
    set -m
    $cmd_str 2>&1 &
    APP_PID=$!
    
    log_debug "App PID: $APP_PID"
    
    sleep 3
    
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log_error "App died immediately after start"
        wait "$APP_PID" 2>/dev/null || true
        local exit_code=$?
        log_error "App exit code: $exit_code"
        exit $exit_code
    fi
    
    log_info "App is running (PID: $APP_PID)"
    
    wait "$APP_PID"
}

# ==================== 8. 主流程 ====================

main() {
    log_info "========================================="
    log_info "  Rclone Wrapper Starting"
    log_info "========================================="
    
    if init_config; then
        restore_data
        
        trap 'shutdown_handler' SIGTERM SIGINT
        
        (
            while true; do
                sleep "$INTERVAL"
                backup_data
            done
        ) &
        BACKUP_PID=$!
        log_info "Backup loop started (PID: $BACKUP_PID, interval: ${INTERVAL}s)"
        
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
    else
        log_warn "Sync functionality disabled due to configuration error"
        log_info "Container will start normally without backup/restore"
    fi
    
    start_main_app "$@"
}

main "$@"
