#!/bin/bash
set -euo pipefail

sudo dnf upgrade -y
sudo dnf install -y unzip wget

sudo rpm --import https://rpm.grafana.com/gpg.key
cat <<EOF | sudo tee /etc/yum.repos.d/grafana.repo
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

sudo dnf install -y grafana
sudo systemctl enable --now grafana-server

sudo wget -q https://github.com/grafana/loki/releases/download/v2.8.2/loki-linux-amd64.zip
unzip -o loki-linux-amd64.zip
sudo mv -f loki-linux-amd64 /usr/local/bin/loki
sudo chmod a+x /usr/local/bin/loki

sudo useradd --system --no-create-home loki || true
sudo mkdir -p /etc/loki /var/lib/loki
sudo tee /etc/loki/loki-config.yaml >/dev/null <<'EOF'
auth_enabled: false
server:
  http_listen_address: 0.0.0.0
  http_listen_port: 3100
  grpc_listen_port: 9096
common:
  path_prefix: /var/lib/loki
  storage:
    filesystem:
      chunks_directory: /var/lib/loki/chunks
      rules_directory: /var/lib/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
EOF
sudo chown -R loki:loki /etc/loki /var/lib/loki

sudo tee /etc/systemd/system/loki.service >/dev/null <<'UNIT'
[Unit]
Description=Loki Log Aggregation System
After=network.target

[Service]
User=loki
ExecStart=/usr/local/bin/loki -config.file /etc/loki/loki-config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now loki
