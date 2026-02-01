# Contributing to Conduit Manager v2.0

Thank you for considering contributing to the Conduit Manager High-Performance Cluster Edition! This document provides guidelines and best practices for contributing.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Code Style Guidelines](#code-style-guidelines)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Reporting Bugs](#reporting-bugs)
- [Suggesting Enhancements](#suggesting-enhancements)

---

## 🤝 Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors, regardless of background or identity.

### Expected Behavior

- Be respectful and considerate
- Welcome newcomers and help them get started
- Provide constructive feedback
- Focus on what is best for the project and community

### Unacceptable Behavior

- Harassment, discrimination, or offensive comments
- Personal attacks or trolling
- Publishing others' private information
- Any conduct that would be considered unprofessional

---

## 🚀 Getting Started

### Prerequisites

- Linux development environment (Ubuntu 20.04+ recommended)
- Docker installed (`docker --version`)
- Bash shell knowledge
- Git installed (`git --version`)
- Root/sudo access for testing

### Fork and Clone

```bash
# Fork the repository on GitHub, then:
git clone https://github.com/YOUR-USERNAME/conduit-manager.git
cd conduit-manager

# Add upstream remote
git remote add upstream https://github.com/SamNet-dev/conduit-manager.git
```

### Project Structure

```
conduit-manager/
├── conduit-v2.0.sh              # Core foundation script (CLI only)
├── conduit-v2-ui-module.sh      # Interactive menu module
├── conduit-v2-telegram-module.sh # Telegram bot module
├── conduit-v2-tools-module.sh   # QR, backup/restore module
├── conduit-v2-complete.sh       # Merged complete script
├── merge-v2-modules.sh          # Module merger utility
├── conduit.sh                   # Legacy v1.2 script
├── README-v2.md                 # v2.0 documentation
├── README.md                    # v1.2 documentation (legacy)
├── DEPLOYMENT-GUIDE.md          # Deployment instructions
├── CONTRIBUTING.md              # This file
├── LICENSE                      # MIT License
├── plans/                       # Architecture documents
│   ├── conduit-v2-architecture.md
│   ├── hardware-specific-config.md
│   ├── psiphon-compliance-validation.md
│   └── devops-review-and-hardening.md
└── docs/                        # Additional documentation
    ├── IMPLEMENTATION-STATUS.md
    ├── INTEGRATION-GUIDE.md
    └── FINAL-STATUS.md
```

---

## 💻 Development Workflow

### Branch Naming Convention

Use descriptive branch names:

```bash
feature/add-ipv6-support       # New features
bugfix/fix-nginx-reload        # Bug fixes
hotfix/critical-security-fix   # Critical fixes
docs/update-deployment-guide   # Documentation updates
refactor/improve-health-check  # Code refactoring
```

### Create a Branch

```bash
# Update your fork
git fetch upstream
git checkout main
git merge upstream/main

# Create feature branch
git checkout -b feature/your-feature-name
```

### Making Changes

1. **Small, focused commits**: Each commit should represent a single logical change
2. **Test your changes**: See [Testing](#testing) section
3. **Update documentation**: If your change affects user-facing behavior
4. **Follow code style**: See [Code Style Guidelines](#code-style-guidelines)

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style (formatting, no logic change)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

**Examples:**

```bash
feat(nginx): add IPv6 support to load balancer

- Added IPv6 listen directives to nginx.conf
- Updated health checks to support IPv6
- Added IPv6 detection in generate_nginx_conf()

Closes #42
```

```bash
fix(health-check): prevent false positives for slow containers

Container health checks were timing out after 5 seconds,
causing false positives during high load. Increased timeout
to 15 seconds and added retry logic.

Fixes #127
```

---

## 📝 Code Style Guidelines

### Bash Scripting Standards

#### 1. Shebang and Options

```bash
#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures
```

#### 2. Function Naming

Use lowercase with underscores:

```bash
# Good
generate_nginx_conf() { ... }
health_check_containers() { ... }

# Avoid
GenerateNginxConf() { ... }
healthCheckContainers() { ... }
```

#### 3. Variable Naming

- **Constants:** UPPERCASE with underscores
- **Local variables:** lowercase with underscores
- **Function parameters:** lowercase with underscores

```bash
# Constants
INSTALL_DIR="/opt/conduit"
MAX_CONTAINERS=40

# Local variables
local container_name="conduit-node-1"
local backend_port=8081

# Function parameters
run_container() {
    local index=$1
    local max_clients=$2
}
```

#### 4. Quoting

Always quote variables unless you explicitly need word splitting:

```bash
# Good
echo "${container_name}"
docker run --name "${container_name}"

# Risky (unquoted)
echo $container_name
docker run --name $container_name
```

#### 5. Error Handling

Use explicit error handling:

```bash
# Good
if ! docker ps &>/dev/null; then
    log_error "Docker is not running"
    return 1
fi

# Better
run_docker_command() {
    if ! docker ps &>/dev/null; then
        log_error "Docker is not running"
        return 1
    fi
    # ... rest of function
}
```

#### 6. Comments

- Use `#` for single-line comments
- Use comment blocks for function documentation
- Explain WHY, not WHAT (code should be self-explanatory)

```bash
#═══════════════════════════════════════════════════════════════════════════
# Generate Nginx Layer 4 Load Balancer Configuration
#═══════════════════════════════════════════════════════════════════════════
# Creates /etc/nginx/stream.d/conduit.conf with:
#   - TCP upstream with least_conn algorithm
#   - UDP upstream with hash-based session affinity
#   - Health checks every 30 seconds
#   - Automatic failover on container failure
#
# Args:
#   None (uses global CONTAINER_COUNT, BACKEND_PORT_START)
# Returns:
#   0 on success, 1 on failure
# Side effects:
#   - Writes /etc/nginx/stream.d/conduit.conf
#   - Reloads Nginx if running
#═══════════════════════════════════════════════════════════════════════════
generate_nginx_conf() {
    # Detect Nginx configuration directory structure
    # (Different distros use different paths)
    if [ -d "/etc/nginx/stream.d" ]; then
        stream_dir="/etc/nginx/stream.d"
    elif [ -d "/etc/nginx/conf.d" ]; then
        stream_dir="/etc/nginx/conf.d"
    else
        mkdir -p "/etc/nginx/stream.d"
        stream_dir="/etc/nginx/stream.d"
    fi
    
    # ... rest of function
}
```

#### 7. Logging Functions

Use consistent logging:

```bash
log_info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}
```

#### 8. Formatting

- **Indentation:** 4 spaces (no tabs)
- **Line length:** Max 100 characters (soft limit)
- **Function braces:** Opening brace on same line as function name

```bash
# Good
generate_nginx_conf() {
    local stream_conf="/etc/nginx/stream.d/conduit.conf"
    
    if [ ! -d "$(dirname "$stream_conf")" ]; then
        mkdir -p "$(dirname "$stream_conf")"
    fi
}
```

---

## 🧪 Testing

### Local Testing

#### 1. Syntax Check

```bash
# Check bash syntax
bash -n conduit-v2-complete.sh
shellcheck conduit-v2-complete.sh  # Install: apt install shellcheck
```

#### 2. Test on Clean VPS

Use a test VPS (not production) to validate:

```bash
# Deploy on test VPS
scp conduit-v2-complete.sh root@test-vps:/root/
ssh root@test-vps

# Run deployment
sudo bash conduit-v2-complete.sh

# Test basic operations
sudo bash conduit-v2-complete.sh status
sudo bash conduit-v2-complete.sh health
sudo bash conduit-v2-complete.sh scale 4
```

#### 3. Test Specific Functions

Add test functions at the bottom of your module:

```bash
# Add to end of your module file
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Only run if script is executed directly (not sourced)
    echo "Testing your_function..."
    your_function test_arg1 test_arg2
    echo "Test complete"
fi
```

### Test Checklist

Before submitting a PR, verify:

- [ ] Script passes `shellcheck` with no errors
- [ ] Tested on Ubuntu 20.04/22.04
- [ ] Tested on Debian 11/12 (if applicable)
- [ ] Tested on CentOS/Rocky 8+ (if applicable)
- [ ] Docker containers start successfully
- [ ] Nginx starts and proxies correctly
- [ ] Health checks pass
- [ ] Menu system works (if UI changes)
- [ ] Telegram notifications work (if Telegram changes)
- [ ] Backup/restore works (if affecting persistence)
- [ ] Uninstall removes everything cleanly

---

## 📤 Submitting Changes

### Create Pull Request

```bash
# Commit your changes
git add .
git commit -m "feat(scope): description"

# Push to your fork
git push origin feature/your-feature-name

# Open PR on GitHub
# Go to: https://github.com/SamNet-dev/conduit-manager/compare
```

### PR Guidelines

**Title Format:**
```
<type>(<scope>): <description>
```

**PR Description Template:**

```markdown
## Description
Brief description of what this PR does.

## Motivation
Why is this change needed? What problem does it solve?

## Changes
- List of specific changes
- Another change
- Yet another change

## Testing
Describe how you tested these changes:
- OS tested: Ubuntu 22.04
- Docker version: 24.0.7
- VPS specs: 2 vCore / 4GB RAM
- Test results: All health checks passed

## Checklist
- [ ] Code follows project style guidelines
- [ ] Tested on at least one Linux distribution
- [ ] Documentation updated (if user-facing changes)
- [ ] Passes shellcheck with no errors
- [ ] Commit messages follow convention
- [ ] No breaking changes (or documented in PR)

## Related Issues
Closes #42
Related to #38
```

### PR Review Process

1. **Automated checks:** ShellCheck, syntax validation (if configured)
2. **Maintainer review:** Code quality, architecture, testing
3. **Discussion:** Address review comments
4. **Approval:** At least one maintainer approval required
5. **Merge:** Squash and merge (maintains clean history)

---

## 🐛 Reporting Bugs

### Before Reporting

1. **Search existing issues:** Your bug may already be reported
2. **Try latest version:** Bug might be fixed in recent release
3. **Check documentation:** Issue might be configuration error

### Bug Report Template

Create issue on GitHub with:

```markdown
## Bug Description
Clear description of the bug.

## Expected Behavior
What should happen?

## Actual Behavior
What actually happens?

## Steps to Reproduce
1. First step
2. Second step
3. Third step

## Environment
- **OS:** Ubuntu 22.04
- **Docker version:** `docker --version` output
- **Script version:** v2.0.0-cluster
- **VPS specs:** 2 vCore / 4GB RAM / 120GB SSD

## Logs
```bash
# Relevant log output
tail -f /var/log/conduit/nginx.log
```

## Additional Context
Screenshots, configuration files, etc.
```

---

## 💡 Suggesting Enhancements

### Feature Request Template

```markdown
## Feature Description
Clear description of the proposed feature.

## Use Case
Who would benefit? Why is this needed?

## Proposed Solution
How should this work? Include examples if possible.

## Alternatives Considered
What other approaches did you consider?

## Additional Context
Mockups, examples from other projects, etc.
```

### Enhancement Guidelines

**Good feature requests:**
- Solve real problems for multiple users
- Align with project goals (performance, stability, usability)
- Don't significantly increase complexity
- Are feasible to implement and maintain

**Examples:**

✅ **Good:** "Add IPv6 support to Nginx load balancer"
- Solves real problem (dual-stack networks)
- Aligns with performance goals
- Clear implementation path

❌ **Not suitable:** "Add GUI web interface"
- Significant scope increase
- Maintenance burden
- Conflicts with lightweight design philosophy

---

## 📚 Documentation Guidelines

### Writing Style

- **Clear and concise:** Avoid jargon, explain technical terms
- **Examples:** Show, don't just tell
- **Structure:** Use headings, lists, tables for readability
- **Code blocks:** Syntax highlighting with language tags

### Markdown Formatting

```markdown
# Main Heading (H1) - Only one per document

## Section Heading (H2)

### Subsection (H3)

**Bold for emphasis**
*Italic for terms*
`code` for inline code
```

### Code Blocks

Use language tags for syntax highlighting:

```markdown
```bash
# Bash scripts
sudo bash conduit-v2-complete.sh
```

```nginx
# Nginx configuration
upstream conduit_tcp {
    least_conn;
    server 127.0.0.1:8081;
}
```

```json
{
    "setting": "value"
}
```
```

### Documentation Locations

- **README-v2.md:** Main documentation, quick start, features
- **DEPLOYMENT-GUIDE.md:** Step-by-step deployment instructions
- **plans/*.md:** Technical architecture and design documents
- **docs/*.md:** Implementation details, status updates
- **Code comments:** Function documentation, complex logic explanation

---

## 🏆 Recognition

Contributors will be:
- Listed in GitHub contributors page
- Mentioned in release notes (for significant contributions)
- Credited in documentation (for major features)

---

## 📞 Getting Help

**Stuck? Need help?**

- **GitHub Discussions:** Ask questions, share ideas
- **GitHub Issues:** Report bugs, request features
- **Documentation:** Check [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)
- **Architecture:** Review [plans/conduit-v2-architecture.md](plans/conduit-v2-architecture.md)

---

## 📜 License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

**Thank you for contributing to Conduit Manager v2.0! 🙏**
