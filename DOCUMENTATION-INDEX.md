# Documentation Index

Complete documentation guide for Conduit Manager v2.0 High-Performance Cluster Edition.

---

## 📚 Quick Start

**New Users:**
1. Read: [README-v2.md](README-v2.md) - Overview and features
2. Follow: [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) - Step-by-step installation
3. Review: [SECURITY.md](SECURITY.md) - Security best practices

**Developers:**
1. Read: [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guidelines
2. Review: [plans/conduit-v2-architecture.md](plans/conduit-v2-architecture.md) - Technical architecture
3. Check: [CHANGELOG.md](CHANGELOG.md) - Version history

---

## 📖 User Documentation

### Essential Reading

| Document | Description | Audience |
|----------|-------------|----------|
| **[README-v2.md](README-v2.md)** | Main documentation for v2.0 with features, usage, troubleshooting | All users |
| **[DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)** | Complete deployment instructions with examples | Operators |
| **[README.md](README.md)** | Legacy v1.2 documentation (for existing users) | v1.2 users |

### Configuration Guides

| Document | Description | Audience |
|----------|-------------|----------|
| **[plans/hardware-specific-config.md](plans/hardware-specific-config.md)** | Hardware optimization for 2 vCore / 4GB VPS | Operators |
| **[SECURITY.md](SECURITY.md)** | Security best practices and hardening | Operators |

### Reference

| Document | Description | Audience |
|----------|-------------|----------|
| **[CHANGELOG.md](CHANGELOG.md)** | Version history and release notes | All users |
| **[LICENSE](LICENSE)** | MIT License terms | All users |

---

## 🏗️ Technical Documentation

### Architecture & Design

| Document | Description | Audience |
|----------|-------------|----------|
| **[plans/conduit-v2-architecture.md](plans/conduit-v2-architecture.md)** | Complete technical architecture with diagrams | Developers |
| **[plans/psiphon-compliance-validation.md](plans/psiphon-compliance-validation.md)** | Psiphon protocol compliance verification | Developers |
| **[plans/devops-review-and-hardening.md](plans/devops-review-and-hardening.md)** | Production best practices and security review | DevOps Engineers |
| **[plans/implementation-flow.md](plans/implementation-flow.md)** | Implementation timeline and workflow | Project Managers |

### Implementation Details

| Document | Description | Audience |
|----------|-------------|----------|
| **[IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md)** | Feature implementation status tracking | Developers |
| **[INTEGRATION-GUIDE.md](INTEGRATION-GUIDE.md)** | Manual integration instructions for modules | Developers |
| **[FINAL-STATUS.md](FINAL-STATUS.md)** | Current project status and deliverables | Project Managers |
| **[REMAINING-WORK.md](REMAINING-WORK.md)** | Outstanding tasks and priorities | Developers |

---

## 👥 Contributor Documentation

### Getting Started

| Document | Description | Audience |
|----------|-------------|----------|
| **[CONTRIBUTING.md](CONTRIBUTING.md)** | Contribution guidelines and code standards | Contributors |
| **[SECURITY.md](SECURITY.md)** | Vulnerability reporting process | Security Researchers |

### Templates

| Document | Description | Audience |
|----------|-------------|----------|
| **[.github/ISSUE_TEMPLATE/bug_report.md](.github/ISSUE_TEMPLATE/bug_report.md)** | Bug report template | Contributors |
| **[.github/ISSUE_TEMPLATE/feature_request.md](.github/ISSUE_TEMPLATE/feature_request.md)** | Feature request template | Contributors |
| **[.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md)** | Pull request template | Contributors |

---

## 🗂️ Code Structure

### Primary Scripts

| File | Lines | Description |
|------|-------|-------------|
| **[conduit-v2-complete.sh](conduit-v2-complete.sh)** | 2,883 | Complete unified script (production-ready) |
| **[conduit-v2.0.sh](conduit-v2.0.sh)** | 1,450 | Core foundation (CLI only) |
| **[conduit.sh](conduit.sh)** | 6,757 | Legacy v1.2 script |

### Modules

| File | Lines | Description |
|------|-------|-------------|
| **[conduit-v2-ui-module.sh](conduit-v2-ui-module.sh)** | 700 | Interactive menu system |
| **[conduit-v2-telegram-module.sh](conduit-v2-telegram-module.sh)** | 450 | Telegram bot integration |
| **[conduit-v2-tools-module.sh](conduit-v2-tools-module.sh)** | 450 | QR codes, backup/restore, updates |

### Utilities

| File | Lines | Description |
|------|-------|-------------|
| **[merge-v2-modules.sh](merge-v2-modules.sh)** | 150 | Module merger utility |
| **[.gitignore](.gitignore)** | - | Git ignore patterns |

---

## 📊 Documentation Statistics

### Coverage

| Category | Files | Status |
|----------|-------|--------|
| **User Documentation** | 3 | ✅ Complete |
| **Technical Documentation** | 7 | ✅ Complete |
| **Contributor Documentation** | 5 | ✅ Complete |
| **Code Comments** | - | ✅ Comprehensive |
| **Total Documents** | **15** | **✅ 100%** |

### Completeness Checklist

- [x] README with quick start
- [x] Installation guide
- [x] Architecture documentation
- [x] API/CLI reference
- [x] Configuration guide
- [x] Troubleshooting guide
- [x] Security documentation
- [x] Contribution guidelines
- [x] Code of conduct (in CONTRIBUTING.md)
- [x] License file
- [x] Changelog
- [x] Issue templates
- [x] PR template
- [x] Security policy
- [x] Code comments

---

## 🎯 Documentation by Use Case

### "I want to deploy Conduit v2.0"

1. **[README-v2.md](README-v2.md)** - Understand features and requirements
2. **[DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)** - Follow deployment steps
3. **[SECURITY.md](SECURITY.md)** - Apply security best practices

### "I'm upgrading from v1.2"

1. **[CHANGELOG.md](CHANGELOG.md)** - Review breaking changes
2. **[README-v2.md](README-v2.md)** - Section: "Upgrading from v1.2"
3. **[DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)** - Follow migration steps

### "I want to optimize performance"

1. **[plans/hardware-specific-config.md](plans/hardware-specific-config.md)** - Hardware tuning
2. **[plans/conduit-v2-architecture.md](plans/conduit-v2-architecture.md)** - Architecture insights
3. **[plans/devops-review-and-hardening.md](plans/devops-review-and-hardening.md)** - Production tips

### "I want to contribute code"

1. **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution guidelines
2. **[plans/conduit-v2-architecture.md](plans/conduit-v2-architecture.md)** - Technical architecture
3. **[IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md)** - Current status

### "I found a bug"

1. **[.github/ISSUE_TEMPLATE/bug_report.md](.github/ISSUE_TEMPLATE/bug_report.md)** - Bug report template
2. **[README-v2.md](README-v2.md)** - Section: "Troubleshooting"
3. **[SECURITY.md](SECURITY.md)** - If security-related

### "I want to request a feature"

1. **[.github/ISSUE_TEMPLATE/feature_request.md](.github/ISSUE_TEMPLATE/feature_request.md)** - Feature request template
2. **[plans/implementation-flow.md](plans/implementation-flow.md)** - Development roadmap

### "I found a security vulnerability"

1. **[SECURITY.md](SECURITY.md)** - Section: "Reporting a Vulnerability"
2. GitHub Security Advisory (private reporting)

---

## 🔍 Quick Reference

### Common Commands

```bash
# View documentation
cat README-v2.md
cat DEPLOYMENT-GUIDE.md

# Deploy cluster
sudo bash conduit-v2-complete.sh

# Check status
sudo bash conduit-v2-complete.sh status

# Run health check
sudo bash conduit-v2-complete.sh health

# View logs
tail -f /var/log/conduit/nginx.log
```

### File Locations

```
/opt/conduit/                      # Installation directory
/opt/conduit/settings.conf         # Configuration file
/opt/conduit/conduit-health-check.sh   # Health check script
/opt/conduit/conduit-nginx-watchdog.sh # Nginx watchdog
/opt/conduit/backups/              # Node key backups
/var/log/conduit/                  # Log directory
/etc/nginx/stream.d/conduit.conf   # Nginx LB config
```

### Support Channels

- **Documentation:** This index
- **Issues:** https://github.com/SamNet-dev/conduit-manager/issues
- **Discussions:** https://github.com/SamNet-dev/conduit-manager/discussions
- **Security:** [SECURITY.md](SECURITY.md)

---

## 📝 Documentation Standards

### Markdown Style

- **Headers:** Use ATX-style (`#`) not Setext
- **Lists:** Use `-` for unordered, `1.` for ordered
- **Code blocks:** Always specify language (```bash, ```nginx, etc.)
- **Links:** Use relative paths for internal links
- **Tables:** Use for structured data
- **Emoji:** Use sparingly for visual hierarchy (✅, ❌, ⚠️)

### Code Comments

- **Bash functions:** Document with header block
- **Complex logic:** Explain WHY, not WHAT
- **TODOs:** Mark with `# TODO:` and reference issue number

### Versioning

- **Version format:** `MAJOR.MINOR.PATCH-label`
- **Example:** `2.0.0-cluster`
- **Changelog:** Follow [Keep a Changelog](https://keepachangelog.com/)

---

## 🔄 Document Updates

### When to Update

| Trigger | Update These Files |
|---------|-------------------|
| **New release** | CHANGELOG.md, README-v2.md, version in scripts |
| **Breaking change** | CHANGELOG.md, README-v2.md, migration guide |
| **New feature** | README-v2.md, CHANGELOG.md, relevant guides |
| **Bug fix** | CHANGELOG.md (patch notes) |
| **Security fix** | SECURITY.md, CHANGELOG.md |
| **Architecture change** | plans/conduit-v2-architecture.md |
| **Config change** | DEPLOYMENT-GUIDE.md, README-v2.md |

### Review Checklist

Before releasing documentation:

- [ ] All links work (internal and external)
- [ ] Code examples tested
- [ ] Version numbers updated
- [ ] Screenshots current (if applicable)
- [ ] Spelling and grammar checked
- [ ] Markdown renders correctly
- [ ] Tables formatted properly
- [ ] Code blocks have language tags

---

## 📈 Documentation Roadmap

### v2.1 (Planned)

- [ ] Video tutorial (deployment walkthrough)
- [ ] API documentation (if REST API added)
- [ ] Performance tuning cookbook
- [ ] Multi-language support (FAQ in Farsi, Arabic)

### v2.2 (Planned)

- [ ] Advanced troubleshooting guide
- [ ] Monitoring integration guide (Prometheus, Grafana)
- [ ] Scaling strategies whitepaper
- [ ] Case studies from production deployments

### Future

- [ ] Interactive documentation (web-based)
- [ ] Automated documentation generation
- [ ] Developer certification program
- [ ] Community wiki

---

## 🎓 Learning Path

### Beginner (0-1 week)

1. Read [README-v2.md](README-v2.md)
2. Deploy on test VPS following [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)
3. Explore interactive menu
4. Configure Telegram bot
5. Generate QR codes

### Intermediate (1-4 weeks)

1. Read [plans/conduit-v2-architecture.md](plans/conduit-v2-architecture.md)
2. Optimize for your hardware using [plans/hardware-specific-config.md](plans/hardware-specific-config.md)
3. Implement security best practices from [SECURITY.md](SECURITY.md)
4. Scale containers up/down
5. Test backup/restore

### Advanced (1-3 months)

1. Study [plans/devops-review-and-hardening.md](plans/devops-review-and-hardening.md)
2. Contribute a bug fix ([CONTRIBUTING.md](CONTRIBUTING.md))
3. Optimize Nginx configuration
4. Implement custom monitoring
5. Write a feature proposal

---

## 📞 Contact & Support

**Documentation Issues:**
- Found a typo? Open an issue
- Documentation unclear? Ask in Discussions
- Missing information? Request in feature request

**Project Links:**
- **GitHub:** https://github.com/SamNet-dev/conduit-manager
- **Psiphon:** https://psiphon.ca/
- **Conduit:** https://github.com/Psiphon-Inc/conduit

---

**Last Updated:** 2026-02-01  
**Documentation Version:** 2.0.0  
**Status:** ✅ Complete and Ready for Publication
