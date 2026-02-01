# Security Policy

## Supported Versions

We actively support the following versions with security updates:

| Version | Supported          | Support Until |
| ------- | ------------------ | ------------- |
| 2.0.x   | :white_check_mark: | Current       |
| 1.2.x   | :white_check_mark: | 2026-08-01    |
| < 1.2   | :x:                | Ended         |

## Reporting a Vulnerability

We take security seriously. If you discover a security vulnerability, please follow these steps:

### 1. Do Not Disclose Publicly

**Do not** create a public GitHub issue for security vulnerabilities. This helps protect users while we work on a fix.

### 2. Report Privately

Send a detailed report to:
- **Email:** [Create a security advisory on GitHub]
- **GitHub Security Advisory:** https://github.com/SamNet-dev/conduit-manager/security/advisories/new

### 3. Include in Your Report

Please include as much information as possible:

- **Description:** Clear description of the vulnerability
- **Impact:** Who is affected and what can an attacker do?
- **Reproduction:** Step-by-step instructions to reproduce
- **Version:** Which version(s) are affected
- **Patches:** If you have a fix, include it (optional)

**Example Report:**

```markdown
## Vulnerability: Command Injection in Health Check Script

**Impact:** Remote code execution if attacker controls container names

**Affected Versions:** v2.0.0-cluster

**Reproduction:**
1. Create container with malicious name: `conduit-node-1$(malicious_command)`
2. Run health check: `conduit-v2-complete.sh health`
3. Command executes with root privileges

**Suggested Fix:**
Always quote variables: `docker exec "${container_name}" ...`
```

### 4. Response Timeline

- **Initial Response:** Within 48 hours
- **Assessment:** Within 1 week
- **Fix Development:** Depends on severity (see below)
- **Public Disclosure:** After fix is released + 7 days

## Severity Levels

We assess vulnerabilities using the following criteria:

### Critical (Fix within 24-48 hours)

- Remote code execution as root
- Complete system compromise
- Data exfiltration of all user data
- Widespread impact affecting all users

**Example:** Command injection allowing arbitrary root access

### High (Fix within 1 week)

- Privilege escalation
- Authentication bypass
- Significant data exposure
- Denial of service affecting all users

**Example:** Container escape vulnerability

### Medium (Fix within 2 weeks)

- Limited information disclosure
- Partial denial of service
- Security feature bypass
- Affects specific configurations only

**Example:** Nginx config allows information leakage

### Low (Fix in next release)

- Minor information disclosure
- Low-impact denial of service
- Issues requiring local access
- Theoretical attacks with no known exploit

**Example:** Predictable temporary file names

## Security Best Practices

When using Conduit Manager, follow these best practices:

### System Hardening

1. **Keep System Updated:**
   ```bash
   apt update && apt upgrade -y  # Ubuntu/Debian
   yum update -y                 # CentOS/Rocky
   ```

2. **Enable Firewall:**
   ```bash
   ufw allow 22/tcp       # SSH
   ufw allow 443/tcp      # Conduit TCP
   ufw allow 443/udp      # Conduit UDP
   ufw enable
   ```

3. **Disable Root SSH Login:**
   ```bash
   # Edit /etc/ssh/sshd_config:
   PermitRootLogin no
   PasswordAuthentication no
   ```

4. **Use SSH Keys:**
   ```bash
   # Generate key on your local machine
   ssh-keygen -t ed25519
   ssh-copy-id user@your-vps
   ```

### Conduit Security

1. **Regular Backups:**
   ```bash
   # Backup node keys weekly
   0 0 * * 0 /usr/local/bin/conduit-v2-complete.sh backup
   ```

2. **Monitor Logs:**
   ```bash
   # Check for suspicious activity
   tail -f /var/log/conduit/nginx.log | grep -v "200\|101"
   ```

3. **Restrict Permissions:**
   ```bash
   # Verify backup permissions
   ls -la /opt/conduit/backups/  # Should show -rw------- (600)
   ```

4. **Update Regularly:**
   ```bash
   # Update to latest version monthly
   conduit-v2-complete.sh update
   ```

### Docker Security

1. **Keep Docker Updated:**
   ```bash
   apt update && apt install docker-ce docker-ce-cli
   ```

2. **Don't Run Untrusted Images:**
   ```bash
   # Only use official Psiphon image
   docker pull psiphon/conduit:latest
   ```

3. **Limit Container Capabilities:**
   - v2.0 already implements resource limits
   - Do not modify `--cpus` or `--memory` to unrestricted

### Network Security

1. **Nginx Configuration:**
   - Do not expose backend ports (8081-8088) publicly
   - Keep Nginx updated: `apt install nginx`
   - Monitor Nginx logs: `/var/log/conduit/nginx.log`

2. **Rate Limiting (Optional):**
   ```nginx
   # Add to /etc/nginx/stream.d/conduit.conf
   limit_conn_zone $binary_remote_addr zone=addr:10m;
   server {
       limit_conn addr 100;
   }
   ```

3. **DDoS Protection:**
   - Use CloudFlare or similar CDN
   - Configure fail2ban for SSH brute force
   - Monitor bandwidth usage

### Telegram Bot Security

1. **Keep Token Secret:**
   ```bash
   # Never commit token to git
   # Store in /opt/conduit/telegram-token (permissions 600)
   ```

2. **Restrict Chat Access:**
   - Only use with your personal Telegram chat ID
   - Do not share bot token publicly
   - Regenerate token if compromised

3. **Limit Bot Permissions:**
   - Bot should only send messages (not admin)
   - Verify chat ID matches yours: `/start` in bot

## Known Security Considerations

### Bridge Networking

**Issue:** Containers communicate via localhost
**Mitigation:** This is intended behavior. Backend ports (8081-8088) are only accessible from localhost, not from external network.

**Verification:**
```bash
netstat -tulpn | grep 808  # Should show 127.0.0.1:808X
```

### System Tuning

**Issue:** Script modifies sysctl parameters
**Mitigation:** All changes are conservative and production-safe. Review before deployment:

```bash
# Review planned changes:
grep sysctl conduit-v2-complete.sh

# Verify current values:
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_congestion_control
```

### Root Privileges

**Issue:** Script requires root/sudo for:
- Docker management
- Nginx configuration
- System tuning (sysctl)
- Service management (systemd)

**Mitigation:**
- Review script before running
- Use sudo only when necessary
- Never run as root via SSH (use sudo instead)

**Verification:**
```bash
# Check script for suspicious commands:
grep -E "curl.*bash|wget.*bash|eval" conduit-v2-complete.sh
# Should return nothing suspicious
```

## Security Audits

We welcome security audits from the community. If you're conducting an audit:

1. **Inform us:** Let us know you're auditing (optional but appreciated)
2. **Scope:** Focus on:
   - Command injection vulnerabilities
   - Privilege escalation
   - Docker escape vectors
   - Nginx misconfiguration
   - Credential handling
3. **Report findings:** Use the reporting process above

## Third-Party Dependencies

### Docker

- **Source:** Docker Inc. (https://docker.com)
- **Security:** Docker has its own security team
- **Updates:** Follow Docker's security advisories

### Nginx

- **Source:** Nginx Inc. (https://nginx.org)
- **Security:** Nginx has established security record
- **Updates:** OS package manager handles updates

### Psiphon Conduit

- **Source:** Psiphon Inc. (https://psiphon.ca)
- **Security:** Psiphon's responsibility
- **Updates:** Pull latest image regularly

### GeoIP Database

- **Source:** MaxMind (GeoLite2)
- **Security:** Database only, no code execution
- **Privacy:** IP geolocation happens locally

## Vulnerability Disclosure Timeline

When we fix a vulnerability:

1. **Day 0:** Vulnerability reported
2. **Day 1-2:** Initial assessment and acknowledgment
3. **Day 2-7:** Develop and test fix
4. **Day 7:** Release patch
5. **Day 14:** Public disclosure (after 7 days grace period)

### Example Disclosure

```markdown
## CVE-2026-XXXXX: Command Injection in Health Check (Fixed)

**Severity:** High
**Affected:** v2.0.0-cluster
**Fixed In:** v2.0.1
**Reported:** 2026-01-15 by Security Researcher Name

**Description:**
Health check script was vulnerable to command injection via
specially crafted container names.

**Impact:**
Attackers with ability to create containers could execute
arbitrary commands as root.

**Mitigation:**
Upgrade to v2.0.1 or later.

**Credit:**
Thanks to [Researcher Name] for responsible disclosure.
```

## Security Resources

- **Psiphon Security:** https://psiphon.ca/en/security.html
- **Docker Security:** https://docs.docker.com/engine/security/
- **Nginx Security:** https://nginx.org/en/security_advisories.html
- **OWASP Top 10:** https://owasp.org/www-project-top-ten/

## Contact

For security-related questions (not vulnerabilities):
- GitHub Discussions: https://github.com/SamNet-dev/conduit-manager/discussions
- GitHub Issues: https://github.com/SamNet-dev/conduit-manager/issues

For vulnerabilities, use the private reporting methods above.

---

**Last Updated:** 2026-02-01
**Policy Version:** 1.0
