#!/bin/bash
# GPU集群组件检查脚本
# 使用方法: bash check_gpu_cluster_components.sh

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查标志
CHECKED=0
PASSED=0
FAILED=0
WARNINGS=0

print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_ok() {
    echo -e "${GREEN}✓ $1${NC}"
    ((PASSED++))
}

print_fail() {
    echo -e "${RED}✗ $1${NC}"
    echo -e "${RED}  └─ 修复建议: $2${NC}"
    ((FAILED++))
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    echo -e "${YELLOW}  └─ $2${NC}"
    ((WARNINGS++))
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_command() {
    ((CHECKED++))
    if command -v $1 &> /dev/null; then
        VERSION=$($2 2>&1 | head -n1)
        print_ok "$1 已安装: $VERSION"
        return 0
    else
        print_fail "$1 未安装" "$3"
        return 1
    fi
}

check_service() {
    ((CHECKED++))
    if systemctl is-active --quiet $1; then
        print_ok "服务 $1 正在运行"
        return 0
    else
        print_fail "服务 $1 未运行" "systemctl start $1 && systemctl enable $1"
        return 1
    fi
}

check_module() {
    ((CHECKED++))
    if lsmod | grep -q "^$1"; then
        print_ok "内核模块 $1 已加载"
        return 0
    else
        print_fail "内核模块 $1 未加载" "modprobe $1"
        return 1
    fi
}

# 1. 系统基础检查
print_header "1. 操作系统与内核检查"
OS_INFO=$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
KERNEL_VERSION=$(uname -r)
print_info "操作系统: $OS_INFO"
print_info "内核版本: $KERNEL_VERSION"

# 检查内核头文件
if [ -d "/lib/modules/$(uname -r)/build" ]; then
    print_ok "内核头文件已安装"
else
    print_fail "内核头文件未安装" "apt-get install linux-headers-$(uname -r)"
fi

# 2. NVIDIA GPU 检查
print_header "2. NVIDIA GPU 与驱动检查"

# 检查GPU硬件
if lspci | grep -i nvidia &> /dev/null; then
    GPU_COUNT=$(lspci | grep -i nvidia | wc -l)
    print_ok "检测到 $GPU_COUNT 块 NVIDIA GPU"
    lspci | grep -i nvidia | sed 's/^/  /'
else
    print_fail "未检测到 NVIDIA GPU" "请检查硬件连接或BIOS设置"
fi

# 检查NVIDIA驱动
check_command "nvidia-smi" "nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits" "请从NVIDIA官网下载驱动: https://www.nvidia.com/drivers"

# 检查CUDA
check_command "nvcc" "nvcc --version" "安装CUDA Toolkit: https://developer.nvidia.com/cuda-downloads"

# 检查内核模块
check_module "nvidia"
check_module "nvidia_uvm"
check_module "nvidia_drm"

# 3. 容器运行时检查
print_header "3. 容器运行时检查"

# Docker检查
check_command "docker" "docker --version" "安装Docker: https://docs.docker.com/engine/install/"
if command -v docker &> /dev/null; then
    check_service "docker"
    
    # 检查Docker是否加载nvidia runtime
    if docker info 2>&1 | grep -q "nvidia"; then
        print_ok "Docker 已配置 nvidia runtime"
    else
        print_fail "Docker 未配置 nvidia runtime" "请安装 nvidia-container-toolkit"
    fi
fi

# containerd检查
check_command "containerd" "containerd --version" "安装containerd: https://github.com/containerd/containerd/releases"
if command -v containerd &> /dev/null; then
    check_service "containerd"
fi

# 4. NVIDIA Container Toolkit 检查
print_header "4. NVIDIA Container Toolkit 检查"

# 检查nvidia-ctk命令
check_command "nvidia-ctk" "nvidia-ctk --version" "安装: apt-get install nvidia-container-toolkit"

# 检查运行时配置
if [ -f "/etc/docker/daemon.json" ] && grep -q "nvidia" /etc/docker/daemon.json; then
    print_ok "Docker daemon.json 已配置 nvidia runtime"
else
    print_fail "Docker daemon.json 未配置 nvidia runtime" "运行: nvidia-ctk runtime configure --runtime=docker"
fi

# 测试GPU容器
print_info "测试GPU容器运行..."
if docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
    print_ok "GPU容器测试通过"
else
    print_fail "GPU容器测试失败" "检查nvidia-container-toolkit配置并重启Docker"
fi

# 5. Kubernetes 组件检查
print_header "5. Kubernetes 组件检查"

# 检查kubeadm
check_command "kubeadm" "kubeadm version" "安装: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/"

# 检查kubelet
check_command "kubelet" "kubelet --version" "安装: apt-get install kubelet"

# 检查kubectl
check_command "kubectl" "kubectl version --client" "安装: apt-get install kubectl"

# 检查kubelet服务
if command -v kubelet &> /dev/null; then
    check_service "kubelet"
fi

# 检查集群状态
if command -v kubectl &> /dev/null; then
    print_info "检查Kubernetes集群状态..."
    if kubectl cluster-info &> /dev/null; then
        print_ok "Kubernetes集群可访问"
        
        # 检查节点状态
        kubectl get nodes -o wide
        
        # 检查GPU资源
        if kubectl get nodes -o json | grep -q "nvidia.com/gpu"; then
            print_ok "集群已识别GPU资源"
            kubectl get nodes -o jsonpath='{.items[*].status.capacity}' | grep -o '"nvidia.com/gpu":"[0-9]*"'
        else
            print_fail "集群未识别GPU资源" "检查GPU Device Plugin是否部署"
        fi
    else
        print_warning "Kubernetes集群未初始化" "运行: kubeadm init 初始化集群"
    fi
fi

# 6. GPU Operator 检查（可选但推荐）
print_header "6. NVIDIA GPU Operator 检查"

# 检查helm
check_command "helm" "helm version" "安装Helm: https://helm.sh/docs/intro/install/"

# 检查GPU Operator Pod
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    GPU_OPERATOR_PODS=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | wc -l)
    if [ "$GPU_OPERATOR_PODS" -gt 0 ]; then
        print_ok "GPU Operator已部署 ($GPU_OPERATOR_PODS pods)"
        kubectl get pods -n gpu-operator 2>/dev/null | sed 's/^/  /'
    else
        print_warning "GPU Operator未部署" "使用Helm安装: helm install gpu-operator nvidia/gpu-operator"
    fi
fi

# 7. 监控组件检查
print_header "7. 监控组件检查"

# DCGM Exporter检查
if command -v kubectl &> /dev/null; then
    DCGM_PODS=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep dcgm | wc -l)
    if [ "$DCGM_PODS" -gt 0 ]; then
        print_ok "DCGM Exporter已部署"
    else
        print_warning "DCGM Exporter未部署" "安装: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/main/dcgm-exporter.yaml"
    fi
fi

# Node Exporter检查
if systemctl is-active --quiet node-exporter; then
    print_ok "Node Exporter服务正在运行"
else
    print_warning "Node Exporter未运行" "安装: apt-get install prometheus-node-exporter"
fi

# 8. 网络插件检查
print_header "8. 网络插件检查"

if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    CNI_PODS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -E "calico|flannel|cilium|weave" | wc -l)
    if [ "$CNI_PODS" -gt 0 ]; then
        print_ok "CNI网络插件已部署"
        kubectl get pods -n kube-system 2>/dev/null | grep -E "calico|flannel|cilium|weave" | sed 's/^/  /'
    else
        print_fail "CNI网络插件未部署" "安装Calico: kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml"
    fi
fi

# 9. 生成总结报告
print_header "检查完成 - 总结报告"

echo -e "${BLUE}检查项总数: $CHECKED${NC}"
echo -e "${GREEN}通过项: $PASSED${NC}"
echo -e "${RED}失败项: $FAILED${NC}"
echo -e "${YELLOW}警告项: $WARNINGS${NC}"

if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}✓ 所有关键组件已就绪！${NC}"
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ 存在可选组件未安装，建议根据需求补充${NC}"
    fi
else
    echo -e "\n${RED}✗ 检测到 $FAILED 个关键组件缺失，请按修复建议安装${NC}"
fi

# 10. 提供快速安装命令
if [ $FAILED -gt 0 ]; then
    print_header "快速修复命令参考"
    
    cat << 'EOF'
# 一键安装基础依赖（Ubuntu）
apt-get update && apt-get install -y \
  linux-headers-$(uname -r) \
  docker.io \
  containerd \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# 安装NVIDIA驱动（示例）
chmod +x NVIDIA-Linux-x86_64-535.129.03.run
./NVIDIA-Linux-x86_64-535.129.03.run --silent --dkms

# 安装NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# 安装Kubernetes组件
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet=1.28.5-00 kubeadm=1.28.5-00 kubectl=1.28.5-00
apt-mark hold kubelet kubeadm kubectl
EOF
fi
