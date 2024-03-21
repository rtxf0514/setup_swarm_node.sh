#!/bin/sh

# 错误处理函数
handle_error() {
    local ERROR_MSG="$1"
    local LINE_NUMBER="$2"
    local INTERNAL_IP=$(hostname -I | awk '{print $1}')
    local EXTERNAL_IP=$(curl -s ifconfig.me || echo "0.0.0.0")
    local NODE_NAME=$(hostname)
    echo "Error occurred on line $LINE_NUMBER: $ERROR_MSG. Sending error details..."
    curl -X POST -d "internal_ip=$INTERNAL_IP&external_ip=$EXTERNAL_IP&node_name=$NODE_NAME&error_message=$ERROR_MSG&line_number=$LINE_NUMBER" https://example.com/error-handler
    exit 1
}

# 设置错误处理函数
trap 'handle_error "$BASH_COMMAND" "$LINENO"' ERR

# 检查命令是否存在函数
is_command_installed() {
    local COMMAND_NAME="$1"
    command -v $COMMAND_NAME >/dev/null 2>&1
}

# 检查参数是否提供正确
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <node_id> <node_name> <docker_swarm_ip>"
    exit 1
fi

NODE_ID=$1
NODE_NAME=$2
DOCKER_SWARM_IP=$3

# 设置节点名称
echo "Setting node name to $NODE_NAME"
hostnamectl set-hostname $NODE_NAME

# 获取包管理器
detect_package_manager() {
    if is_command_installed yum; then
        echo "yum"
    elif is_command_installed apt-get; then
        echo "apt-get"
    else
        handle_error "Unsupported package manager" $LINENO
    fi
}
PACKAGE_MANAGER=$(detect_package_manager)

# 更新软件包列表
# echo "Updating package lists..."
# $PACKAGE_MANAGER update || handle_error "Failed to update package lists" $LINENO

# 检查并安装包函数
check_and_install_packages() {
    local PACKAGES=("$@")
    echo "Checking and installing packages: ${PACKAGES[*]}..."
    for PACKAGE in "${PACKAGES[@]}"; do
        if ! is_command_installed "$PACKAGE"; then
            echo "$PACKAGE is not installed. Installing..."
            $PACKAGE_MANAGER install -y $PACKAGE || handle_error "Failed to install $PACKAGE" $LINENO
        else
            echo "$PACKAGE is already installed."
        fi
    done
}

# 安装 Docker 相关软件包
DOCKER_PACKAGES=(
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
    "docker-buildx-plugin"
    "docker-compose-plugin"
)

PACKAGE="docker"

# 安装 Docker
if ! is_command_installed "$PACKAGE"; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | bash || (
        echo "Failed to install Docker using get.docker.com. Trying alternative method..."
        if is_command_installed "apt-get"; then
            yum install -y yum-utils || handle_error "Failed to install yum-utils" $LINENO
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || handle_error "Failed to add Docker CE repository" $LINENO
            # 获取实际的 CentOS 版本号
            RELEASEVER=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release))
            # 如果 CentOS 版本低于 7.0，则设置 releasever 为 7.0
            sed -i "s/\$releasever/$RELEASEVER/g" /etc/yum.repos.d/docker-ce.repo || handle_error "Failed to replace releasever in Docker repo file" $LINENO
        fi
        check_and_install_packages "${DOCKER_PACKAGES[@]}"
    )
else
    echo "$PACKAGE is already installed."
fi

# 安装 curl
check_and_install_packages "curl"

# 检查 Docker Compose 是否已安装
if ! is_command_installed "docker-compose"; then
    DOCKER_COMPOSE_VERSION="2.25.0"
    echo "Installing Docker Compose v$DOCKER_COMPOSE_VERSION..."
    curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || handle_error "Failed to install Docker Compose" $LINENO
    chmod +x /usr/local/bin/docker-compose
else
    echo "Docker Compose is already installed."
fi

# 安装 NFS 客户端
check_and_install_packages "nfs-utils"

# 安装 ufw 防火墙管理工具
check_and_install_packages "ufw"

# 关闭防火墙
echo "Disabling firewall..."
if is_command_installed "firewalld"; then
    systemctl stop firewalld || handle_error "Failed to stop firewalld" $LINENO
    systemctl disable firewalld || handle_error "Failed to disable firewalld" $LINENO
elif is_command_installed "ufw"; then
    ufw disable || handle_error "Failed to disable ufw" $LINENO
else
    handle_error "Firewall management tool not found." $LINENO
fi

# 加入 Docker Swarm 网络
echo "Joining Docker Swarm network..."
docker swarm join --token $NODE_ID $DOCKER_SWARM_IP:2377 || handle_error "Failed to join Docker Swarm network" $LINENO

echo "Setup complete."
