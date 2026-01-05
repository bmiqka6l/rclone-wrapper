# Docker Rclone Wrapper (Auto-Sync Sidecar)

这是一个工具集，可以将任意 Docker 镜像（Nginx, Node, MySQL 等）自动封装成带有 **rclone 双向同步功能** 的镜像。
特别适用于 PAAS 平台（如 Render, Railway, Zeabur）等不支持持久化 Volume 的场景。

## 🚀 特性

- ✅ **支持 40+ 种云存储**：S3、Google Drive、OneDrive、Dropbox、Azure Blob、MinIO 等
- ✅ **自动双向同步**：启动时恢复数据，运行时定期备份
- ✅ **智能快照管理**：定期创建快照，自动清理旧快照
- ✅ **优雅关闭**：容器停止时自动执行最后一次备份
- ✅ **快速启动**：只同步实时数据，排除快照目录
- ✅ **完全兼容**：保持原始镜像的所有功能和行为
- ✅ **多发行版支持**：Alpine、Debian、Ubuntu、RHEL 等

## � 环境变用量配置

### 必填变量

| 变量名 | 说明 | 示例 |
|--------|------|------|
| `RW_RCLONE_CONFIG` | BASE64 编码的 rclone.conf | `W3MzXQp0eXBlID0gczM...` |
| `RW_BASE_DIR` | 云存储中的基础目录 | `my-app-data` |
| `RW_SYNC_MAP` | 路径映射（格式：`src_dir:/container/path`） | `data:/var/lib/app;conf:/etc/app` |

### 可选变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `RW_REMOTE_NAME` | 第一个 remote | rclone 配置中的 remote 名称 |
| `RW_INTERVAL` | `300` | 备份间隔（秒） |
| `RW_RCLONE_FLAGS` | `--transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3` | 额外的 rclone 参数 |
| `RW_DEBUG` | `false` | 启用调试日志 |

### 快照配置

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `RW_SNAPSHOT_ENABLED` | `true` | 是否启用快照 |
| `RW_SNAPSHOT_INTERVAL` | `900` | 快照间隔（秒，默认 15 分钟） |
| `RW_SNAPSHOT_KEEP_RECENT` | `10` | 保留最近 N 个快照 |
| `RW_SNAPSHOT_KEEP_DAYS` | `7` | 保留最近 N 天的每日快照 |

## ⚙️ 工作原理

```
┌─────────────────────────────────────────┐
│         Docker Container                │
│                                         │
│  1. Restore (启动时)                    │
│     └─> 从云存储下载数据到容器          │
│                                         │
│  2. Main App (前台运行)                 │
│     └─> 原始应用正常运行                │
│                                         │
│  3. Background Loops (后台)             │
│     ├─> 定期备份 (每 5 分钟)            │
│     └─> 定期快照 (每 15 分钟)           │
│                                         │
│  4. Graceful Shutdown (关闭时)          │
│     └─> 最后一次强制备份                │
└─────────────────────────────────────────┘
                  │
                  │ rclone
                  ▼
       ┌──────────────────────┐
       │   Cloud Storage      │
       │                      │
       │  BASE_DIR/           │
       │  ├─ data/            │  ← 实时数据
       │  ├─ conf/            │
       │  └─ snapshots/       │  ← 历史快照
       │     ├─ 20260105_120000/
       │     ├─ 20260105_121500/
       │     └─ ...           │
       └──────────────────────┘
```

## 📦 如何使用

### 1. 准备 rclone 配置

#### 方法一：使用 rclone config 交互式配置（推荐）

首先安装 rclone：

```bash
# Linux/macOS
curl https://rclone.org/install.sh | sudo bash

# Windows (使用 Scoop)
scoop install rclone

# 或者下载二进制文件
# https://rclone.org/downloads/
```

然后使用交互式配置创建 remote：

```bash
rclone config
```

#### 常用云存储配置示例

<details>
<summary><b>OneDrive 配置</b></summary>

```bash
# 1. 运行配置命令
rclone config

# 2. 选择 "n" 创建新 remote
# 3. 输入名称，例如：onedrive
# 4. 选择存储类型：输入 "onedrive" 或对应的编号
# 5. Client ID 和 Secret：直接回车（使用默认）
# 6. Region：选择 "1" (Microsoft Cloud Global)
# 7. Edit advanced config：选择 "n"
# 8. Auto config：选择 "y"（会打开浏览器授权）
# 9. 在浏览器中登录 Microsoft 账号并授权
# 10. 选择账号类型：
#     - "1" OneDrive Personal
#     - "2" OneDrive Business
#     - "3" SharePoint
# 11. 选择要使用的 Drive
# 12. 确认配置：选择 "y"
# 13. 退出：选择 "q"

# 配置完成后，查看配置文件
cat ~/.config/rclone/rclone.conf
```

配置文件示例：
```ini
[onedrive]
type = onedrive
token = {"access_token":"xxx","token_type":"Bearer","refresh_token":"xxx","expiry":"2024-01-01T00:00:00Z"}
drive_id = b!xxx
drive_type = personal
```

</details>

<details>
<summary><b>Google Drive 配置</b></summary>

```bash
# 1. 运行配置命令
rclone config

# 2. 选择 "n" 创建新 remote
# 3. 输入名称，例如：gdrive
# 4. 选择存储类型：输入 "drive" 或对应的编号
# 5. Client ID 和 Secret：直接回车（使用默认）
#    注意：使用默认可能有速率限制，建议创建自己的 OAuth 应用
#    参考：https://rclone.org/drive/#making-your-own-client-id
# 6. Scope：选择 "1" (Full access)
# 7. Root folder ID：直接回车（使用根目录）
# 8. Service Account File：直接回车
# 9. Edit advanced config：选择 "n"
# 10. Auto config：选择 "y"（会打开浏览器授权）
# 11. 在浏览器中登录 Google 账号并授权
# 12. Configure as team drive：选择 "n"
# 13. 确认配置：选择 "y"
# 14. 退出：选择 "q"

# 配置完成后，查看配置文件
cat ~/.config/rclone/rclone.conf
```

配置文件示例：
```ini
[gdrive]
type = drive
scope = drive
token = {"access_token":"xxx","token_type":"Bearer","refresh_token":"xxx","expiry":"2024-01-01T00:00:00Z"}
team_drive = 
```

</details>

<details>
<summary><b>S3 兼容存储配置（AWS S3 / MinIO / Backblaze B2 等）</b></summary>

```bash
# 1. 运行配置命令
rclone config

# 2. 选择 "n" 创建新 remote
# 3. 输入名称，例如：s3
# 4. 选择存储类型：输入 "s3" 或对应的编号
# 5. 选择 Provider：
#    - "1" AWS S3
#    - "2" Alibaba Cloud OSS
#    - "3" Ceph
#    - "4" DigitalOcean Spaces
#    - "5" Dreamhost
#    - "6" IBM COS
#    - "7" Minio
#    - "8" Wasabi
#    等等...
# 6. 选择认证方式：
#    - "1" 输入 AWS credentials
#    - "2" 从环境变量获取
#    - "3" 使用 IAM role
# 7. 输入 Access Key ID
# 8. 输入 Secret Access Key
# 9. Region：输入区域（如 us-east-1）或直接回车
# 10. Endpoint：
#     - AWS S3：直接回车（使用默认）
#     - MinIO：输入你的 MinIO 服务器地址（如 http://192.168.1.100:9000）
#     - Backblaze B2：输入对应区域的 endpoint（如 s3.us-west-004.backblazeb2.com）
#     - 其他 S3 兼容服务：查看服务商文档获取 endpoint
# 11. Location constraint：直接回车
# 12. ACL：直接回车（使用默认）
# 13. Edit advanced config：选择 "n"
# 14. 确认配置：选择 "y"
# 15. 退出：选择 "q"

# 配置完成后，查看配置文件
cat ~/.config/rclone/rclone.conf
```

配置文件示例（AWS S3）：
```ini
[s3]
type = s3
provider = AWS
access_key_id = AKIAIOSFODNN7EXAMPLE
secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region = us-east-1
```

配置文件示例（MinIO）：
```ini
[minio]
type = s3
provider = Minio
access_key_id = minioadmin
secret_access_key = minioadmin
endpoint = http://localhost:9000
```

</details>

<details>
<summary><b>WebDAV 配置（Nextcloud / ownCloud / 坚果云等）</b></summary>

```bash
# 1. 运行配置命令
rclone config

# 2. 选择 "n" 创建新 remote
# 3. 输入名称，例如：webdav
# 4. 选择存储类型：输入 "webdav" 或对应的编号
# 5. URL：输入 WebDAV 服务器地址
#    - Nextcloud: https://your-domain.com/remote.php/dav/files/USERNAME/
#    - ownCloud: https://your-domain.com/remote.php/webdav/
#    - 坚果云: https://dav.jianguoyun.com/dav/
# 6. Vendor：选择供应商
#    - "1" Nextcloud
#    - "2" ownCloud
#    - "3" Sharepoint
#    - "4" Other
# 7. User：输入用户名
# 8. Password：选择 "y" 并输入密码
# 9. Bearer token：直接回车
# 10. Edit advanced config：选择 "n"
# 11. 确认配置：选择 "y"
# 12. 退出：选择 "q"

# 配置完成后，查看配置文件
cat ~/.config/rclone/rclone.conf
```

配置文件示例（Nextcloud）：
```ini
[webdav]
type = webdav
url = https://cloud.example.com/remote.php/dav/files/username/
vendor = nextcloud
user = username
pass = *** ENCRYPTED ***
```

配置文件示例（坚果云）：
```ini
[jianguoyun]
type = webdav
url = https://dav.jianguoyun.com/dav/
vendor = other
user = your-email@example.com
pass = *** ENCRYPTED ***
```

</details>

#### 方法二：手动创建配置文件

如果你已经有凭证信息，可以直接创建配置文件：

```bash
# 创建配置文件
cat > rclone.conf << 'EOF'
[your-remote]
type = s3
provider = AWS
access_key_id = YOUR_KEY
secret_access_key = YOUR_SECRET
region = us-east-1
EOF
```

#### 转换为 BASE64

配置完成后，将配置文件转换为 BASE64：

```bash
# Linux/macOS
cat ~/.config/rclone/rclone.conf | base64 -w 0

# 或者转换单个 remote（推荐）
rclone config show your-remote | base64 -w 0

# Windows (PowerShell)
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -Raw ~/.config/rclone/rclone.conf)))
```

**注意**：
- 配置文件可能包含多个 remote，你可以只提取需要的部分
- 密码字段如果显示 `*** ENCRYPTED ***`，需要从实际配置文件中复制完整内容
- 建议为每个容器创建独立的 remote 配置，避免混淆

### 2. 验证配置

在使用配置前，建议先测试 rclone 配置是否正常工作：

```bash
# 列出 remote
rclone listremotes

# 列出 remote 中的文件（测试连接）
rclone ls your-remote:

# 创建测试目录
rclone mkdir your-remote:test-dir

# 上传测试文件
echo "test" > test.txt
rclone copy test.txt your-remote:test-dir/

# 列出测试目录
rclone ls your-remote:test-dir/

# 清理测试
rclone purge your-remote:test-dir/
rm test.txt
```

如果以上命令都能正常执行，说明配置正确。

### 3. 构建封装镜像

#### 方法一：使用 GitHub Actions 自动构建（推荐）

1. Fork 本仓库到你的 GitHub 账号
2. 进入仓库的 **Actions** 页面
3. 选择 **"Wrap Image (Rclone Sync)"** workflow
4. 点击 **"Run workflow"**
5. 输入参数：
   - **Base Image**: 你想封装的原镜像（如 `nginx:alpine`）
   - **Target Tag**: 新镜像的名字（如 `my-nginx-sync`）
6. 等待构建完成，获取镜像地址：
   ```
   ghcr.io/<你的用户名>/<Target Tag>:latest
   ```

#### 方法二：本地构建

如果你想在本地构建镜像：

```bash
# 1. 克隆仓库
git clone https://github.com/bmiqka6l/rclone-wrapper.git
cd your-repo/rclone-wrapper

# 2. 自动检测原镜像配置并构建
BASE_IMAGE="nginx:alpine"

# 拉取原镜像
docker pull $BASE_IMAGE

# 检测原镜像配置
ENTRYPOINT=$(docker inspect --format='{{range .Config.Entrypoint}}{{.}} {{end}}' $BASE_IMAGE | sed 's/ *$//')
CMD=$(docker inspect --format='{{range .Config.Cmd}}{{.}} {{end}}' $BASE_IMAGE | sed 's/ *$//')
WORKDIR=$(docker inspect --format='{{.Config.WorkingDir}}' $BASE_IMAGE)
if [ -z "$WORKDIR" ]; then WORKDIR="/"; fi

echo "Detected Config:"
echo "  Entrypoint: [$ENTRYPOINT]"
echo "  CMD: [$CMD]"
echo "  WorkDir: [$WORKDIR]"

# 构建封装镜像
docker build \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg ORIGINAL_ENTRYPOINT="$ENTRYPOINT" \
  --build-arg ORIGINAL_CMD="$CMD" \
  --build-arg ORIGINAL_WORKDIR="$WORKDIR" \
  -t my-nginx-sync \
  .
```

**注意**：
- 自动检测配置可以确保完全兼容原镜像
- 如果手动指定配置，请仔细检查原镜像的 ENTRYPOINT、CMD 和 WORKDIR
- 使用 `docker inspect <image>` 查看原镜像的完整配置

### 4. 运行容器

```bash
docker run -d \
  -e RW_RCLONE_CONFIG="<BASE64_ENCODED_CONFIG>" \
  -e RW_BASE_DIR="my-app-data" \
  -e RW_SYNC_MAP="html:/usr/share/nginx/html;conf:/etc/nginx" \
  -e RW_REMOTE_NAME="s3" \
  -e RW_INTERVAL="300" \
  -p 80:80 \
  my-nginx-with-sync
```

## � 配置示例配

### AWS S3

```ini
[s3]
type = s3
provider = AWS
access_key_id = AKIAIOSFODNN7EXAMPLE
secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region = us-east-1
```

### Google Cloud Storage

```ini
[gcs]
type = google cloud storage
project_number = 123456789
service_account_file = /path/to/service-account.json
```

### Azure Blob Storage

```ini
[azure]
type = azureblob
account = mystorageaccount
key = YOUR_STORAGE_KEY
```

### MinIO (本地测试)

```ini
[minio]
type = s3
provider = Minio
access_key_id = minioadmin
secret_access_key = minioadmin
endpoint = http://localhost:9000
```

## 🔧 常见场景

### Nginx 静态网站

```bash
docker run -d \
  -e RW_RCLONE_CONFIG="$(cat rclone.conf | base64 -w 0)" \
  -e RW_BASE_DIR="my-website" \
  -e RW_SYNC_MAP="html:/usr/share/nginx/html" \
  -e RW_REMOTE_NAME="s3" \
  -p 80:80 \
  my-nginx-with-sync
```

### MySQL 数据库

```bash
docker run -d \
  -e RW_RCLONE_CONFIG="$(cat rclone.conf | base64 -w 0)" \
  -e RW_BASE_DIR="my-mysql" \
  -e RW_SYNC_MAP="data:/var/lib/mysql" \
  -e RW_REMOTE_NAME="s3" \
  -e RW_INTERVAL="600" \
  -e MYSQL_ROOT_PASSWORD="password" \
  -p 3306:3306 \
  my-mysql-with-sync
```

### Node.js 应用

```bash
docker run -d \
  -e RW_RCLONE_CONFIG="$(cat rclone.conf | base64 -w 0)" \
  -e RW_BASE_DIR="my-node-app" \
  -e RW_SYNC_MAP="uploads:/app/uploads;logs:/app/logs" \
  -e RW_REMOTE_NAME="s3" \
  -p 3000:3000 \
  my-node-app-with-sync
```

## 🚨 注意事项

### 性能优化

- **启动速度**：wrapper 只同步实时数据，自动排除快照目录
- **增量同步**：rclone 自动检测文件变化，只传输修改的部分
- **自定义参数**：通过 `RW_RCLONE_FLAGS` 环境变量传递额外的 rclone 参数

### 数据安全

- **快照保护**：默认保留 10 个最近快照 + 7 天历史快照
- **优雅关闭**：容器停止时自动执行最后一次备份
- **错误容错**：备份失败不影响主应用运行

### 使用限制

- **大文件**：适合中小型数据（< 10GB），大文件建议使用专用备份方案
- **高频写入**：不适合高频写入场景（如日志文件），建议调整备份间隔
- **网络依赖**：需要稳定的网络连接，建议配置重试机制

## 🐛 故障排查

### 容器启动失败

```bash
# 查看日志
docker logs <container_id>

# 常见错误：
# 1. "Missing required environment variables" - 检查必填环境变量
# 2. "Invalid rclone configuration" - 检查 BASE64 编码是否正确
# 3. "Failed to decode RW_RCLONE_CONFIG" - 检查 BASE64 格式
```

### 数据未同步

```bash
# 启用调试模式
docker run -e RW_DEBUG="true" ...

# 检查 rclone 配置
docker exec <container_id> rclone listremotes

# 手动测试同步
docker exec <container_id> rclone ls s3:my-app-data
```

### 快照未创建

```bash
# 检查快照是否启用
docker exec <container_id> env | grep SNAPSHOT

# 查看快照列表
docker exec <container_id> rclone lsf s3:my-app-data/snapshots --dirs-only
```

### rclone 配置问题

**问题：配置文件中密码显示为 `*** ENCRYPTED ***`**

解决方法：
```bash
# 方法1：使用 rclone config show 获取完整配置
rclone config show your-remote

# 方法2：直接读取配置文件
cat ~/.config/rclone/rclone.conf

# 方法3：使用 --obscure 参数加密密码
rclone obscure "your-password"
# 然后在配置文件中使用加密后的密码
```

**问题：OneDrive/Google Drive token 过期**

解决方法：
```bash
# 重新授权
rclone config reconnect your-remote

# 或者删除并重新创建 remote
rclone config delete your-remote
rclone config
```

**问题：WebDAV 连接失败**

检查清单：
- URL 是否正确（注意末尾的斜杠）
- 用户名和密码是否正确
- 服务器是否支持 WebDAV
- 防火墙是否允许连接

```bash
# 测试连接
rclone lsd webdav:

# 查看详细错误信息
rclone lsd webdav: -vv
```

**问题：S3 兼容存储连接失败**

检查清单：
- Endpoint 是否正确
- Access Key 和 Secret Key 是否正确
- Region 是否匹配
- Bucket 是否存在且有权限

```bash
# 测试连接
rclone lsd s3:

# 列出所有 buckets
rclone lsd s3:

# 创建 bucket（如果不存在）
rclone mkdir s3:my-bucket
```

## ❓ 常见问题 (FAQ)

<details>
<summary><b>Q: 如何在无浏览器环境中配置 OneDrive/Google Drive？</b></summary>

A: 使用远程授权模式：

```bash
# 在有浏览器的机器上运行
rclone authorize "onedrive"  # 或 "drive"

# 复制输出的 token，然后在服务器上配置时粘贴
rclone config
# 选择 "Use auto config? n"
# 粘贴 token
```

</details>

<details>
<summary><b>Q: 如何使用多个 remote？</b></summary>

A: 在配置文件中添加多个 remote 配置：

```ini
[s3-backup]
type = s3
...

[gdrive-backup]
type = drive
...
```

然后在环境变量中指定：
```bash
-e RW_REMOTE_NAME="s3-backup"
```

</details>

<details>
<summary><b>Q: 如何加密云存储数据？</b></summary>

A: 使用 rclone 的 crypt 功能：

```bash
# 配置加密 remote
rclone config
# 选择 "crypt" 类型
# 指定要加密的 remote（如 s3:my-bucket）
# 设置密码

# 使用加密 remote
-e RW_REMOTE_NAME="encrypted-remote"
```

</details>

<details>
<summary><b>Q: 如何优化传输性能？</b></summary>

A: wrapper 已经设置了合理的默认参数：
```
--transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3
```

如果需要调整：

```bash
# 提高并发（适合大量小文件）
-e RW_RCLONE_FLAGS="--transfers=8 --checkers=16 --contimeout=60s --timeout=300s --retries=3"

# 限制带宽（避免占用过多网络）
-e RW_RCLONE_FLAGS="--bwlimit 10M --transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3"

# 大文件优化（增加缓冲区）
-e RW_RCLONE_FLAGS="--buffer-size=32M --transfers=4 --checkers=8 --contimeout=60s --timeout=300s --retries=3"
```

**注意**：设置 `RW_RCLONE_FLAGS` 会完全覆盖默认参数，建议保留超时和重试设置。

</details>

<details>
<summary><b>Q: 如何处理大文件？</b></summary>

A: 调整 rclone 参数：

```bash
-e RW_RCLONE_FLAGS="--transfers=2 --checkers=4 --buffer-size=64M --timeout=600s"
```

对于非常大的文件（> 1GB），建议：
- 减少并发数（--transfers=1 或 2）
- 增加缓冲区（--buffer-size=64M 或更大）
- 延长超时时间（--timeout=600s 或更长）
- 增加备份间隔（RW_INTERVAL=600 或更长）

</details>

<details>
<summary><b>Q: 配置文件太大，BASE64 编码后超过环境变量限制怎么办？</b></summary>

A: 方法1：只包含需要的 remote
```bash
rclone config show your-remote | base64 -w 0
```

方法2：挂载配置文件
```bash
docker run -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf ...
# 不设置 RW_RCLONE_CONFIG 环境变量
```

</details>

## 📚 与 git-wrapper 的对比

| 特性 | git-wrapper | rclone-wrapper |
|------|-------------|----------------|
| 存储后端 | Git 仓库 | 40+ 种云存储 |
| 大文件支持 | ❌ 不适合 | ✅ 支持 |
| 版本历史 | ✅ Git 提交历史 | ✅ 快照机制 |
| 启动速度 | 慢（需要 clone） | 快（增量同步） |
| 存储成本 | 免费（GitHub） | 按量付费 |
| 适用场景 | 配置文件、小型数据 | 任意大小数据 |

## 📄 License

MIT License

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！
