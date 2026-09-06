#!/bin/bash
set -euo pipefail

sudo dnf upgrade -y
sudo dnf install -y wget unzip httpd

wget -q https://github.com/grafana/loki/releases/download/v2.8.2/promtail-linux-amd64.zip
unzip -o promtail-linux-amd64.zip
sudo mv -f promtail-linux-amd64 /usr/local/bin/promtail
sudo chmod a+x /usr/local/bin/promtail
sudo mkdir -p /etc/promtail

sudo tee /etc/promtail/promtail-config.yaml >/dev/null <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/log/positions.yaml

clients:
  - url: http://${loki_push_host}:3100/loki/api/v1/push

scrape_configs:
  - job_name: webserver_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: webserver
          instance: $${HOSTNAME}
          __path__: /var/log/httpd/access_log
  - job_name: system_logs
    static_configs:
      - targets:
          - localhost
        labels:
          job: system
          instance: $${HOSTNAME}
          __path__: /var/log/*.log
EOF

sudo tee /etc/systemd/system/promtail.service >/dev/null <<'UNIT'
[Unit]
Description=Promtail Log Collector
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/promtail -config.file /etc/promtail/promtail-config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now promtail

systemctl enable --now httpd

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-ipv4 > /tmp/local_ipv4
curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/availability-zone > /tmp/az
curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/ > /tmp/macid

macid=$(cat /tmp/macid)
local_ipv4=$(cat /tmp/local_ipv4)
az=$(cat /tmp/az)
vpc=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$${macid}/vpc-id")

cat >/var/www/html/index.html <<HTML
<!doctype html>
<html lang="en" class="h-100">
<head>
<title>Details for EC2 instance</title>
</head>
<body>
<div>
<h1>AWS Instance Details</h1>
<h1>Samurai Katana</h1>
<p><b>Instance Name:</b> $(hostname -f) </p>
<p><b>Instance Private Ip Address: </b> $${local_ipv4}</p>
<p><b>Availability Zone: </b> $${az}</p>
<p><b>Virtual Private Cloud (VPC):</b> $${vpc}</p>
</div>
</body>
</html>
HTML

rm -f /tmp/local_ipv4 /tmp/az /tmp/macid
sudo systemctl restart httpd
echo "Setup complete. Promtail forwarding to Loki at ${loki_push_host}."
