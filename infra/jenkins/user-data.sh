#!/bin/bash
# First-boot setup for the Jenkins controller (Amazon Linux 2023).
# Progress: /var/log/jenkins-bootstrap.log ; done when /var/lib/jenkins-bootstrap.done exists.
set -euxo pipefail
exec > >(tee -a /var/log/jenkins-bootstrap.log) 2>&1

# 1. Swap: a 1 GB instance cannot hold Jenkins + a Liquibase JVM container without it.
if ! swapon --show | grep -q /swapfile; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/90-swappiness.conf

# 2. Tools the pipeline needs: Java for Jenkins, Docker for Liquibase, Python for the
#    linter and experiment scripts, git, jq. (AWS CLI v2 ships with AL2023.)
dnf -y install java-21-amazon-corretto-headless docker git jq python3.11 python3.11-pip fontconfig

# 3. Jenkins LTS from the official repository.
curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm-stable/jenkins.repo
dnf -y install jenkins

# Keep the controller heap small so builds and Docker have room.
# Temp files go to disk: AL2023's /tmp is a RAM-backed tmpfs (~half of RAM), below
# Jenkins' 1 GB free-temp-space threshold, which would take the built-in node offline.
install -d -o jenkins -g jenkins /var/lib/jenkins/tmp
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Xms256m -Xmx512m -Djava.io.tmpdir=/var/lib/jenkins/tmp"
TimeoutStartSec=600
EOF

# 4. Jenkins runs `docker run` for Liquibase.
systemctl enable --now docker
usermod -aG docker jenkins

systemctl daemon-reload
systemctl enable --now jenkins

touch /var/lib/jenkins-bootstrap.done
echo "Jenkins bootstrap finished"
