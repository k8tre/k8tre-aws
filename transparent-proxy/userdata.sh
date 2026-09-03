#!/usr/bin/bash
set -ex

export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections


############################################################
# Install proxy
############################################################

# Use DPkg::Lock::Timeout=180 to avoid failing if an automatic update is in progress
apt-get update -y -o DPkg::Lock::Timeout=180
apt-get install -y -o DPkg::Lock::Timeout=180 \
  iptables-persistent \
  jq \
  netfilter-persistent \
  openssl \
  squid-openssl \
  unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install


############################################################
# Setup routing and iptables
############################################################

INTERFACE=$(ip -j route show default | jq -r '.[0].dev')
if [ -z "$INTERFACE" ] || [ "$INTERFACE" = "null" ]; then
  echo "ERROR: Failed to find default network interface"
  exit 1
fi
echo "Using network interface: $INTERFACE"
ip addr show "$INTERFACE"

cat << 'SYSCTL' > /etc/sysctl.d/99-proxy.conf
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system

# Flush any existing rules
iptables -t nat -F
iptables -t mangle -F
ip6tables -F

# Reject IPv6 forwarding so EKS nodes instantly fall back to IPv4
ip6tables -A FORWARD -i "$INTERFACE" -j REJECT

# Redirect HTTP and HTTPS traffic
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3128
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 3129

# Masquerade outbound traffic leaving the proxy
# iptables -t nat -A POSTROUTING -o "$INTERFACE" ! -d 169.254.169.254/32 -j MASQUERADE
iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
systemctl enable netfilter-persistent
systemctl restart netfilter-persistent


############################################################
# Configure Squid
############################################################

# Generate dummy SSL certificate required for Squid's transparent peering framework
mkdir -p /etc/squid/ssl
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
  -subj "/C=UK/O=K8TRE/CN=transparent-proxy" \
  -keyout /etc/squid/ssl/dummy.pem -out /etc/squid/ssl/dummy.pem
chown -R proxy:proxy /etc/squid/ssl
chmod 400 /etc/squid/ssl/dummy.pem

# Initialize the SSL certificate database for the certgen helper
mkdir -p /var/lib/squid
rm -rf /var/lib/squid/ssl_db
/usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB
# Give the squid user ownership of the new database
chown -R proxy:proxy /var/lib/squid

# Ensure file exists before first s3 copy, must be non-empty
echo localhost > /etc/squid/allowlist.txt
chown proxy:proxy /etc/squid/allowlist.txt

# Overwrite default Squid configuration for transparent peek-and-splice
cat << 'SQUID' > /etc/squid/squid.conf
# Fix public hostname warning (unable to detect)
visible_hostname squid-proxy

######################################################################
# Access Control Lists

# This is complicated because for HTTPS we want to check the SNI host, but
# if it's allowed we want to pass the request through unchanged without
# replacing it with our dummy certificate
acl SSL_port port 443

# Define an ACL that matches Step 1 only of the TLS handshake
acl step1 at_step SslBump1

acl allowed_domains dstdomain "/etc/squid/allowlist.txt"
acl allowed_domains_ssl ssl::server_name "/etc/squid/allowlist.txt"

# Avoid warning in the HTTP rule when HTTPS is blocked, since there's no response
acl hasResponse has response
acl http_blocked http_status 403
acl http_blocked_safe all-of hasResponse http_blocked

# HTTPS/TLS block rules (handshake terminated, no response returned)
acl ssl_blocked_hier hier_code HIER_NONE
acl ssl_blocked_status transaction_initiator client
acl ssl_blocked all-of CONNECT ssl_blocked_hier ssl_blocked_status !allowed_domains_ssl

# Combine them into a single "any_blocked" rule
acl any_blocked any-of http_blocked_safe ssl_blocked


######################################################################
# Logging

# Custom log format that includes SNI server name
# Note HTTPS will always result in the initial connect log, but no tunnel will be created
logformat transparent_sni %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %ssl::>sni %Sh/%<A %mt
access_log daemon:/var/log/squid/access.log transparent_sni

# Log blocked requests only
access_log daemon:/var/log/squid/blocked.log transparent_sni any_blocked


######################################################################
# Filtering

# Standard forward-proxy port (required by Squid to start)
http_port localhost:3130

# Intercept standard HTTP
http_port 3128 intercept

# Intercept HTTPS (using ssl-bump parsing)
https_port 3129 intercept ssl-bump cert=/etc/squid/ssl/dummy.pem generate-host-certificates=on dynamic_cert_mem_cache_size=4MB

# Point to the initialized cert database
sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB

# SSL Bump configuration
# ONLY peek if at step 1, to prevent the dummy certificate being returned to client
ssl_bump peek step1
# If the SNI matches our whitelist, splice (pass through untouched)
ssl_bump splice allowed_domains_ssl
# Otherwise terminate the connection.
ssl_bump terminate all

# Disable caching since we're only interested in restricting domains
cache deny all

# Allow standard HTTP traffic if it matches the whitelist
http_access allow allowed_domains
# Allow intercepted HTTPS IP addresses to pass this initial check.
http_access allow SSL_port
# Block everything else
http_access deny all
SQUID

# Create a systemd drop-in directory to override Squid's default startup mechanics
mkdir -p /etc/systemd/system/squid.service.d

# Systemd override
# - Fetch allowlist before starting
# - Allow network admin for the transparent bind
cat << 'SYSTEMD_OVERRIDE' > /etc/systemd/system/squid.service.d/override.conf
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStartPre=/usr/local/bin/aws s3 cp s3://${s3_config_bucket}/${name}-transparent-proxy/allowlist.txt /etc/squid/allowlist.txt
ExecStartPre=/bin/chown proxy:proxy /etc/squid/allowlist.txt
SYSTEMD_OVERRIDE

systemctl daemon-reload
systemctl restart squid
systemctl enable squid


############################################################
# CloudWatch agent
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
            "file_path": "/var/log/squid/access.log",
            "log_group_name": "${name}/transparent-proxy",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/squid/blocked.log",
            "log_group_name": "${name}/transparent-proxy/blocked",
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
