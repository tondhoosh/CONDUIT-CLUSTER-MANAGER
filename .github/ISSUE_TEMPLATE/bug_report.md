---
name: Bug Report
about: Report a bug to help us improve Conduit Manager
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of what the bug is.

## Expected Behavior

What should happen?

## Actual Behavior

What actually happens?

## Steps to Reproduce

1. First step
2. Second step
3. Third step
4. ...

## Environment

**Operating System:**
- Distribution: [e.g., Ubuntu 22.04]
- Kernel: [output of `uname -r`]

**Conduit Manager:**
- Version: [e.g., v2.0.0-cluster]
- Installation method: [wget / git clone / other]

**Docker:**
- Version: [output of `docker --version`]
- Compose version (if applicable): [output of `docker-compose --version`]

**Nginx:**
- Version: [output of `nginx -v`]
- Package: [nginx / nginx-full / nginx-extras]

**VPS Specifications:**
- CPU: [e.g., 2 vCores]
- RAM: [e.g., 4GB]
- Storage: [e.g., 120GB NVMe SSD]
- Network: [e.g., 1Gbps]

**Container Configuration:**
- Number of containers: [e.g., 8]
- Max clients per container: [e.g., 250]
- Bandwidth limit: [e.g., 3 Mbps]

## Logs

<details>
<summary>Nginx Log</summary>

```
# Output of: tail -n 50 /var/log/conduit/nginx.log
[paste log here]
```

</details>

<details>
<summary>Container Log</summary>

```
# Output of: docker logs conduit-node-1 --tail 50
[paste log here]
```

</details>

<details>
<summary>Health Check Output</summary>

```
# Output of: sudo bash conduit-v2-complete.sh health
[paste output here]
```

</details>

## Additional Context

Add any other context about the problem here. Screenshots, configuration files, etc.

## Possible Solution (Optional)

If you have an idea of what might be causing the issue or how to fix it, please share.

## Checklist

- [ ] I have searched for similar issues before creating this one
- [ ] I am using the latest version of Conduit Manager
- [ ] I have included all relevant logs and error messages
- [ ] I have included my environment details
- [ ] I have provided clear steps to reproduce the issue
