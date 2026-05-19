# Transparent Squid Proxy

This is a transparent proxy that allows/denies HTTP and HTTPS traffic based on domains.

It can be used by configuring your network to route all internet bound traffic to this proxy, meaning you do not need to explicitly configure proxy settings for all applications.

Set `allowed_domains` to a list of allowed domains, you must prefix each domain with a `.` to include subdomains.

## Limitations

- When the allowed domains are updated squid is **not** automatically restarted, you must manually run `systemctl restart squid` in the instance (log in with AWS SSM)

## Future improvements

- Pre-build AMI instead of installing everything in userdata at first boot
