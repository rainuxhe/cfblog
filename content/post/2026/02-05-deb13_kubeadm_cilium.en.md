+++
date = '2026-02-05T00:44:06+08:00'
draft = false
title = 'Deploying a Single-Node Kubernetes Cluster on Debian 13 with kubeadm and Cilium'
description = "This article provides a comprehensive guide on deploying a single-node Kubernetes cluster in a local virtual machine environment using Cilium as the network plugin."
isCJKLanguage = false
categories = ["devops"]
tags = ["kubernetes", "harbor", "containerd", "cilium"]
keywords = [
    "kubernetes",
    "containerd",
    "debian",
    "cilium",
    "harbor",
]
slug = "deb13-kubernetes-cilium"
+++

## Introduction

Deploying a Kubernetes cluster using kubeadm in a local virtual machine environment is an ideal choice for learning and experimentation. Considering potential network restrictions and image building requirements in real-world scenarios, this guide provides a detailed walkthrough of deploying a single-node Kubernetes cluster in a completely offline environment. By integrating Harbor as a private container registry, all Kubernetes component images are pulled from a local Harbor instance, ensuring deployment reliability and reproducibility.

This guide is suitable for technical professionals who wish to quickly set up a Kubernetes lab environment in restricted network conditions, covering the entire process from system initialization to Cilium network plugin configuration.

## Environment and Version Information

### Base Environment Configuration
- **Operating System**: Debian 13 (codename "Trixie")
- **Hardware Specifications**: 4 CPU cores / 4GB RAM / 40GB storage
- **Network Topology**: Single-node deployment (Control Plane + Worker combined)

### Software Version Inventory
| Component | Version | Description |
|-----------|---------|-------------|
| Kubernetes | v1.33.7 | Container orchestration platform |
| containerd | 2.2.1 | Container runtime |
| runc | 1.4.0 | OCI runtime specification implementation |
| CNI Plugins | 1.9.0 | Container Network Interface plugins |
| Harbor | v2.14.2 | Enterprise-grade container registry |
| Cilium | v1.18.6 | eBPF-powered networking and security solution |
| Helm | 3.19.5 | Kubernetes package manager |

### Network Planning
| IP Address | Hostname | Role |
|------------|----------|------|
| 192.168.0.22 | deb13-k8s-node1 | Kubernetes node |
| 192.168.0.42 | deb13-harbor | Harbor container registry |

> **Note**: This document assumes both hosts are on the same internal network with verified connectivity.

## System Initialization

Before installing Kubernetes components, necessary system initialization configurations must be performed to meet Kubernetes runtime requirements.

### 1. Install IPVS-related packages
IPVS (IP Virtual Server) is Linux kernel's load balancing implementation. Kubernetes requires related tools when running kube-proxy in IPVS mode.

```bash
# Execute only on Kubernetes node
sudo apt update
sudo apt install -y ipvsadm ipset
```

### 2. Configure hostname
For easier management and identification, it's recommended to set meaningful hostnames for each host.

```bash
# Harbor server
hostnamectl set-hostname deb13-harbor

# Kubernetes node
hostnamectl set-hostname deb13-k8s-node1
```

### 3. Configure local DNS resolution
Edit the `/etc/hosts` file to add hostname-to-IP address mappings:

```bash
cat >> /etc/hosts << EOF
192.168.0.22 deb13-k8s-node1
192.168.0.42 deb13-harbor
EOF
```

### 4. Load required kernel modules
Kubernetes depends on specific kernel modules to support container networking functionality. Create module loading configuration and apply immediately:

```bash
# Create module loading configuration file
cat << EOF > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# Load modules immediately
sudo modprobe overlay
sudo modprobe br_netfilter

# Verify module loading status
lsmod | grep -E "(overlay|br_netfilter)"
```

### 5. Configure system kernel parameters
Adjust kernel parameters to optimize the container runtime environment:

```bash
cat > /etc/sysctl.d/k8s.conf << EOF
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.swappiness = 0
EOF

# Apply configuration
sudo sysctl --system
```

> **Important**: If the system has swap enabled, it must be disabled before starting Kubernetes, otherwise kubelet will fail to start. Use the following command to temporarily disable swap:

```bash
sudo swapoff -a
# To permanently disable swap, comment out swap-related lines in /etc/fstab
```

## Harbor Private Container Registry Deployment

Harbor, as an enterprise-grade container registry, provides reliable image distribution capabilities for Kubernetes deployments in offline environments.

### 1. Prepare Harbor installation package
Download the offline installation package (approximately 600MB) from the [Harbor GitHub Releases](https://github.com/goharbor/harbor/releases) page. Ensure Docker and Docker Compose are properly installed before installing Harbor.

### 2. Generate self-signed TLS certificates
Since Harbor enforces HTTPS connections, we need to generate self-signed certificates for the Harbor server. Create a certificate generation script:

```bash
# Create certificate directory
mkdir -p ~/apps/harbor/certs
cd ~/apps/harbor/certs

# Create certificate generation script
cat > gen-harbor-crt.sh << 'EOF'
#!/bin/bash

# --- Configuration parameters ---
DOMAIN="deb13-harbor"       # Harbor domain name
IP="192.168.0.42"           # Harbor server internal IP
DAYS=3650                   # Validity period: 10 years

# 1. Generate private key (without password)
openssl genrsa -out harbor.key 2048

# 2. Create OpenSSL configuration file to include SAN
cat > harbor.conf << CONF_EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${DOMAIN}

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
IP.1 = ${IP}
CONF_EOF

# 3. Generate self-signed certificate
openssl req -x509 -nodes -days ${DAYS} -key harbor.key -out harbor.crt -config harbor.conf -extensions v3_req

# 4. Verify certificate (check for Subject Alternative Name field)
echo "--------------------------------------------------"
echo "Certificate verification:"
openssl x509 -in harbor.crt -text -noout | grep -A 1 "Subject Alternative Name"

echo "--------------------------------------------------"
echo "Generation successful!"
echo "Server usage: harbor.crt, harbor.key"
echo "Client (K8s node) usage: harbor.crt"
EOF

# Execute certificate generation
chmod +x gen-harbor-crt.sh
./gen-harbor-crt.sh
```

### 3. Configure Harbor
Copy and modify the Harbor configuration from the template file:

```bash
# Copy configuration template
cp harbor.yml.tmpl harbor.yml

# Modify key configuration items
```

Key configuration items:
```yaml
# Harbor access address
hostname: 192.168.0.42

# HTTPS configuration
https:
  port: 443
  certificate: /home/rainux/apps/harbor/certs/harbor.crt
  private_key: /home/rainux/apps/harbor/certs/harbor.key

# Administrator password (set a strong password)
harbor_admin_password: your-harbor-password

# Database password
database:
  password: your-db-password

# Data storage path
data_volume: /home/rainux/apps/harbor/data

# Log configuration
log:
  location: /home/rainux/apps/harbor/logs

# Enable metrics monitoring
metric:
  enabled: true
  port: 9090
  path: /metrics
```

### 4. Start Harbor service
```bash
cd ~/apps/harbor
sudo ./install.sh
```

### 5. Initialize Harbor projects
Access Harbor via web interface (https://192.168.0.42), log in with the configured administrator password, and create the following two public projects:

- `google_containers`: For storing Kubernetes core component images
- `cilium`: For storing Cilium network plugin related images

> **Configuration Update Note**: To modify Harbor configuration, execute the following commands to apply changes:
> ```bash
> sudo ./prepare
> docker-compose down -v
> sudo docker-compose up -d
> ```

## Containerd Container Runtime Configuration

Containerd, as a lightweight container runtime, is one of the recommended runtime options for Kubernetes.

### 1. Download required components
Download the following components from official GitHub repositories:
- [containerd](https://github.com/containerd/containerd/releases)
- [runc](https://github.com/opencontainers/runc/releases)  
- [CNI Plugins](https://github.com/containernetworking/plugins/releases)

### 2. Install runc
```bash
# Note: The filename in the original document may contain a typo; it should be runc.amd64
chmod +x runc.amd64
sudo mv runc.amd64 /usr/local/bin/runc
```

### 3. Install CNI plugins
```bash
sudo mkdir -p /opt/cni/bin/
sudo tar xf cni-plugins-linux-amd64-v1.9.0.tgz -C /opt/cni/bin/
```

### 4. Install containerd
```bash
sudo tar xf containerd-2.2.1-linux-amd64.tar.gz
sudo mv bin/* /usr/local/bin/
```

### 5. Configure containerd
Generate default configuration and make necessary modifications:

```bash
# Create Harbor certificate directory
sudo mkdir -p /etc/containerd/certs.d/192.168.0.42/

# Generate default configuration
sudo containerd config default > /etc/containerd/config.toml

# Copy Harbor certificate
sudo cp ~/apps/harbor/certs/harbor.crt /etc/containerd/certs.d/192.168.0.42/ca.crt
```

Key configuration modifications:
```toml
# Set Pod sandbox image source
[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = '192.168.0.42/google_containers/pause:3.10'

# Configure private registry
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'

# Enable systemd cgroup driver
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
```

### 6. Configure systemd service
Obtain the service file from the [official repository](https://raw.githubusercontent.com/containerd/containerd/main/containerd.service):

```bash
sudo curl -o /usr/lib/systemd/system/containerd.service https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
```

### 7. Start containerd service
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now containerd
```

## Kubernetes Component Deployment

### 1. Install Kubernetes binaries
Download `kubernetes-server-linux-amd64.tar.gz` from [Kubernetes GitHub Releases](https://github.com/kubernetes/kubernetes/releases) and extract core components:

```bash
# Extract and install core components
tar xf kubernetes-server-linux-amd64.tar.gz
sudo cp kubernetes/server/bin/{kubeadm,kubelet,kubectl} /usr/local/bin/

# Verify required image list
kubeadm config images list --kubernetes-version v1.33.7
```

Push all listed images (including pause, coredns, etcd, etc.) from official sources to the `google_containers` project in your Harbor registry after retagging.

### 2. Configure kubelet systemd service
Create the main service file `/usr/lib/systemd/system/kubelet.service`:

```ini
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### 3. Create kubeadm configuration directory
```bash
sudo mkdir -p /usr/lib/systemd/system/kubelet.service.d/
```

### 4. Configure kubeadm drop-in file
Create `/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf`:

```ini
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/sysconfig/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
```

### 5. Start kubelet service
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now kubelet
```

## Cluster Initialization

### 1. Create kubeadm configuration file
Create `kubeadm-config.yaml` configuration file:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.7
imageRepository: 192.168.0.42/google_containers  # Point to local Harbor registry
networking:
  podSubnet: "10.10.0.0/16"   # Cilium default Pod subnet
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
imageGCHighThresholdPercent: 70   # Start cleaning images when disk usage exceeds 70%
imageGCLowThresholdPercent: 60    # Stop cleaning when disk usage reaches 60%
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"  # Although we'll use Cilium instead of kube-proxy, configuration is still needed during initialization
```

### 2. Execute cluster initialization
```bash
sudo kubeadm init --config kubeadm-config.yaml --ignore-preflight-errors=ImagePull
```

### 3. Clean up kube-proxy (replaced by Cilium)
Since we'll use Cilium as our networking solution, we can remove kube-proxy:

```bash
# Delete kube-proxy DaemonSet
kubectl delete ds kube-proxy -n kube-system

# Clean up iptables rule residues on all nodes
sudo kube-proxy --cleanup
```

### 4. Verify initialization status
After initialization completes, configure kubectl and check cluster status:

```bash
# Configure kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Check node status (should show NotReady since CNI is not yet installed)
kubectl get nodes
kubectl get namespaces
```

## Cilium Network Plugin Deployment

Cilium provides high-performance networking, security, and observability features based on eBPF technology.

### 1. Install cilium-cli
Download and install the command-line tool from [Cilium CLI Releases](https://github.com/cilium/cilium-cli/releases).

### 2. Prepare Cilium images
Push required Cilium images to Harbor registry:

```bash
#!/bin/bash

set -euo pipefail

images=(
    cilium/cilium:v1.18.6
    cilium/hubble-relay:v1.18.6
    cilium/hubble-ui-backend:v0.13.3
    cilium/hubble-ui:v0.13.3
    cilium/cilium-envoy:v1.35.9-1767794330-db497dd19e346b39d81d7b5c0dedf6c812bcc5c9
    cilium/certgen:v0.3.1
    cilium/startup-script:1755531540-60ee83e
)

src_registry="quay.io"
target_registry="192.168.0.42"

for image in "${images[@]}"; do
    echo "Processing image: ${image}"
    docker pull "${src_registry}/${image}"
    docker tag "${src_registry}/${image}" "${target_registry}/${image}"
    docker push "${target_registry}/${image}"
done
```

### 3. Obtain Helm Chart
```bash
helm repo add cilium https://helm.cilium.io/
helm pull cilium/cilium --version 1.18.6
tar xf cilium-1.18.6.tgz
mv cilium cilium-chart
```

### 4. Configure Chart Values
First, replace all image registry addresses:

```bash
sed -i 's#quay.io#192.168.0.42#g' ./cilium-chart/values.yaml
```

Key configuration adjustments:
```yaml
# Enable kube-proxy replacement mode
kubeProxyReplacement: true

# Specify Kubernetes API server address
k8sServiceHost: "192.168.0.22"
k8sServicePort: 6443

# Single-node deployment, set operator replicas to 1
operator:
  replicas: 1

# Enable Hubble observability components
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

# Configure IPAM CIDR range
ipam:
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.10.0.0/16"
```

> **Image Digest Note**: The docker pull and push approach may cause image digests to change. If image pulling fails, set `useDigest` to `false` in `values.yaml`.

### 5. Install Cilium
```bash
# Execute installation
cilium install --chart-directory ./cilium-chart

# Check installation status
cilium status

# Remove control-plane taint to allow Pod scheduling
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

### 6. Verify cluster status
After all Pods are running normally, verify cluster readiness:

```bash
# Check Pod status across all namespaces
kubectl get pods -A

# Verify node status (should show Ready)
kubectl get nodes

# Check Cilium component status
cilium status --verbose
```

## Adding Worker Nodes (Extended Deployment)

After completing single-node cluster deployment, to scale to a multi-node cluster, perform the following steps on new nodes:

*New nodes must first complete system initialization, Containerd configuration, and kube component configuration as described above*

### 1. Generate node join token
Generate a 24-hour valid join token on the Control Plane node:

```bash
kubeadm token create --print-join-command
```

This command will output a join command similar to:
```bash
kubeadm join 192.168.0.22:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

### 2. Execute join command on new node
Execute the above command on the new node, ignoring image preflight errors:

```bash
sudo kubeadm join 192.168.0.22:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --ignore-preflight-errors=ImagePull
```

### 3. Verify node join status
```bash
# Check node list
kubectl get nodes

# Verify Cilium status
cilium status

# Clean up iptables rules (if kube-proxy is disabled)
sudo iptables -F
```

Cilium will automatically deploy agent Pods on new nodes to ensure network connectivity.

## Private Registry Authentication Configuration

For pulling images from non-public projects in Harbor, appropriate authentication mechanisms must be configured.

### Method 1: Pod-level imagePullSecrets (Recommended)

Suitable for scenarios requiring fine-grained control over image pull permissions.

#### 1. Create Docker Registry Secret
```bash
kubectl create secret docker-registry harbor-pull-secret \
  --docker-server=192.168.0.42 \
  --docker-username=<your-username> \
  --docker-password=<your-password> \
  --docker-email=<your-email>
```

#### 2. Reference Secret in Pod definition
```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: my-app
    image: 192.168.0.42/private-project/my-image:v1
  imagePullSecrets:
  - name: harbor-pull-secret
```

### Method 2: ServiceAccount Binding (Convenient Approach)

Suitable for scenarios where all Pods in a namespace need access to private registries.

```bash
# Bind Secret to default ServiceAccount
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
```

This configuration will automatically inherit image pull permissions for all newly created Pods in the namespace.

### Method 3: Containerd Global Authentication (Suitable for Lab Environments)

Configure global authentication at the Containerd level, suitable for personal lab environments.

Edit `/etc/containerd/config.toml`:
```toml
[plugins."io.containerd.grpc.v1.cri".registry.configs."192.168.0.42".auth]
  username = "your-username"
  password = "your-password"
  # Or use base64-encoded credentials: auth = "base64(username:password)"
```

> **Security Reminder**: Method 3 stores credentials in plaintext in configuration files and is not recommended for production environments.

## Additional Notes

Compared to binary deployment, using kubeadm eliminates the need for manual certificate management and simplifies adding new nodes. It would be beneficial to create an Ansible playbook to further streamline node addition.