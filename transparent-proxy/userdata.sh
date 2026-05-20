#!/usr/bin/sh
set -ex


############################################################
# 1. Kernel Routing & Sysctl Tuning for TPROXY
############################################################

export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

# Use DPkg::Lock::Timeout=180 to avoid failing if an automatic update is in progress
apt-get update -y -o DPkg::Lock::Timeout=180
apt-get install -y -o DPkg::Lock::Timeout=180 iptables-persistent netfilter-persistent haproxy unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

# ens5 should be the default NIC, if it isn't this will error out
ip addr show ens5

# Disable Strict Reverse Path Forwarding (required for TPROXY)
# Enable nonlocal bind (required for HAProxy transparent mode)
cat << 'SYSCTL' > /etc/sysctl.d/99-tproxy.conf
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.ens5.rp_filter = 0
SYSCTL
sysctl --system

############################################################
# 2. Configure iptables for TPROXY
############################################################

# Create Netplan routing policy and route to persist the TPROXY rules across network events (DHCP renewals)
cat << 'NETPLAN' > /etc/netplan/99-tproxy.yaml
network:
  version: 2
  ethernets:
    ens5:
      routing-policy:
        - from: 0.0.0.0/0
          mark: 1
          table: 100
    lo:
      routes:
        - to: 0.0.0.0/0
          type: local
          table: 100
NETPLAN
netplan generate
netplan apply

# Flush any existing rules
iptables -t nat -F
iptables -t mangle -F
ip6tables -F

# IMPORTANT: Reject IPv6 forwarding so EKS nodes instantly fall back to IPv4
ip6tables -A FORWARD -i ens5 -j REJECT

# DIVERT chain to prevent re-intercepting established TPROXY connections
iptables -t mangle -N DIVERT
iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT

# Intercept standard HTTP and HTTPS
iptables -t mangle -A PREROUTING -i ens5 -p tcp --dport 80 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 3128
iptables -t mangle -A PREROUTING -i ens5 -p tcp --dport 443 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 3129

# Masquerade outbound traffic leaving the proxy (EXCLUDING AWS Metadata)
iptables -t nat -A POSTROUTING -o ens5 ! -d 169.254.169.254/32 -j MASQUERADE

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
systemctl enable netfilter-persistent
systemctl restart netfilter-persistent

############################################################
# 3. Configure HAProxy
############################################################

mkdir -p /etc/haproxy
touch /etc/haproxy/allowlist.txt
chown haproxy:haproxy /etc/haproxy/allowlist.txt

cat << 'HAPROXY' > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0 debug
    user haproxy
    group haproxy
    daemon

defaults
    log global
    option tcplog
    timeout connect 5s
    timeout client  300s
    timeout server  300s

frontend http_transparent
    bind *:3128 transparent
    mode http

    # 1. Capture the Host header into slot 0
    http-request capture req.hdr(host) len 128

    # 2. Use the captured value in the log-format (captures are accessed via %[capture.req.hdr(0)])
    log-format %ci:%cp\ [%t]\ %ft\ %b/%s\ %Tw/%Tc/%Tt\ %B\ %ts\ %ac/%fc/%bc/%sc/%rc\ %sq/%bq\ HOST:%[capture.req.hdr(0)]

    # 3. Filter
    acl allowed_http req.hdr(host) -i -m reg -f /etc/haproxy/allowlist.txt
    http-request deny if !allowed_http

    default_backend backend_http

frontend https_transparent
    bind *:3129 transparent
    mode tcp

    # 1. Wait for TLS ClientHello
    tcp-request inspect-delay 5s

    # 2. Extract SNI and save it to a session variable "sess.sni"
    tcp-request content set-var(sess.sni) req_ssl_sni

    # 3. Log using the variable we just saved
    log-format %ci:%cp\ [%t]\ %ft\ %b/%s\ %Tw/%Tc/%Tt\ %B\ %ts\ %ac/%fc/%bc/%sc/%rc\ %sq/%bq\ SNI:%[var(sess.sni)]

    # 4. Accept if SNI is valid
    tcp-request content accept if { req_ssl_hello_type 1 } { req_ssl_sni -i -m reg -f /etc/haproxy/allowlist.txt }

    # 5. Reject everything else
    tcp-request content reject

    default_backend backend_https

backend backend_http
    mode http
    server original_dst 0.0.0.0:0

backend backend_https
    mode tcp
    server original_dst 0.0.0.0:0
HAPROXY

# Isolate HAProxy logs for CloudWatch
cat << 'RSYSLOG' > /etc/rsyslog.d/99-haproxy.conf
local0.* /var/log/haproxy.log
& stop
RSYSLOG
systemctl restart rsyslog

# Systemd override: Give HAProxy network admin rights for the transparent bind
mkdir -p /etc/systemd/system/haproxy.service.d
cat << 'SYSTEMD_OVERRIDE' > /etc/systemd/system/haproxy.service.d/override.conf
[Service]
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStartPre=/usr/local/bin/aws s3 cp s3://${s3_config_bucket}/${name}-transparent-proxy/allowlist.txt /etc/haproxy/allowlist.txt
ExecStartPre=/bin/chown haproxy:haproxy /etc/haproxy/allowlist.txt
SYSTEMD_OVERRIDE

systemctl daemon-reload
systemctl restart haproxy
systemctl enable haproxy


############################################################
# 4. CloudWatch agent
############################################################

wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

cat << 'CWAGENT' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/haproxy.log",
            "log_group_name": "${name}/transparent-proxy",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWAGENT

# Start and enable the CloudWatch agent using the config
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
systemctl enable --now amazon-cloudwatch-agent

echo "userdata completed!"
