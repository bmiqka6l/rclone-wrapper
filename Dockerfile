ARG BASE_IMAGE=alpine:latest

# 多阶段构建：从 rclone 官方镜像复制二进制
FROM rclone/rclone:latest AS rclone-source

FROM ${BASE_IMAGE}

# 1. 接收原始镜像元数据
ARG ORIGINAL_ENTRYPOINT=""
ENV RW_ORIGINAL_ENTRYPOINT=$ORIGINAL_ENTRYPOINT

ARG ORIGINAL_CMD=""
ENV RW_ORIGINAL_CMD=$ORIGINAL_CMD

ARG ORIGINAL_WORKDIR="/"
ENV RW_ORIGINAL_WORKDIR=$ORIGINAL_WORKDIR

# 强制切回 Root 以便安装依赖
USER root

# 复制 rclone 二进制
COPY --from=rclone-source /usr/local/bin/rclone /usr/local/bin/rclone

# 智能安装依赖 (兼容 Alpine/Debian/RHEL)
RUN set -e; \
    if command -v apk > /dev/null; then \
        apk add --no-cache bash ca-certificates; \
    elif command -v apt-get > /dev/null; then \
        apt-get update && apt-get install -y bash ca-certificates && rm -rf /var/lib/apt/lists/*; \
    elif command -v microdnf > /dev/null; then \
        microdnf install -y bash ca-certificates; \
    elif command -v yum > /dev/null; then \
        yum install -y bash ca-certificates; \
    else \
        echo "Error: Unsupported package manager (distroless?)."; \
        exit 1; \
    fi

COPY rclone-wrapper.sh /usr/local/bin/rclone-wrapper.sh
RUN chmod +x /usr/local/bin/rclone-wrapper.sh

ENTRYPOINT ["/usr/local/bin/rclone-wrapper.sh"]




