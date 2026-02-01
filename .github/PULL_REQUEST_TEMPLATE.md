# Pull Request

## Description

Briefly describe what this PR does and why.

## Type of Change

Please check the relevant option:

- [ ] 🐛 **Bug fix** (non-breaking change that fixes an issue)
- [ ] ✨ **New feature** (non-breaking change that adds functionality)
- [ ] 💥 **Breaking change** (fix or feature that causes existing functionality to change)
- [ ] 📚 **Documentation** (changes to documentation only)
- [ ] 🎨 **Code style** (formatting, renaming, no functional changes)
- [ ] ♻️ **Refactoring** (code changes that neither fix bugs nor add features)
- [ ] ⚡ **Performance** (code changes that improve performance)
- [ ] ✅ **Test** (adding or updating tests)
- [ ] 🔧 **Chore** (other changes that don't modify src or test files)

## Related Issue

Closes #(issue number)
Fixes #(issue number)
Related to #(issue number)

## Motivation and Context

Why is this change needed? What problem does it solve?

## Changes Made

List the specific changes made in this PR:

- Change 1
- Change 2
- Change 3

## Testing Performed

### Test Environment

- **OS:** Ubuntu 22.04
- **Docker version:** 24.0.7
- **Nginx version:** 1.22.1
- **VPS specs:** 2 vCore / 4GB RAM
- **Container count:** 8
- **Test duration:** 24 hours

### Test Cases

- [ ] Fresh installation on clean VPS
- [ ] Upgrade from v1.2
- [ ] Upgrade from v2.0.0
- [ ] Start/stop/restart operations
- [ ] Container scaling (up and down)
- [ ] Health check passes
- [ ] Nginx status shows all backends
- [ ] Dashboard displays correctly
- [ ] Telegram notifications work (if applicable)
- [ ] QR code generation works (if applicable)
- [ ] Backup/restore works (if applicable)
- [ ] Uninstall removes everything cleanly

### Test Results

<details>
<summary>Test Output</summary>

```bash
# Paste relevant test command output here
```

</details>

## Screenshots (if applicable)

Add screenshots to demonstrate UI changes or new features.

## Code Quality Checklist

- [ ] My code follows the project's code style guidelines
- [ ] I have performed a self-review of my code
- [ ] I have commented my code, particularly in hard-to-understand areas
- [ ] My changes generate no new warnings
- [ ] I have tested my changes on at least one Linux distribution
- [ ] New and existing tests pass locally with my changes
- [ ] I have run `shellcheck` and addressed all errors/warnings

## Documentation Checklist

- [ ] I have updated the README if needed
- [ ] I have updated CHANGELOG.md
- [ ] I have updated relevant documentation in `docs/` or `plans/`
- [ ] I have added/updated code comments
- [ ] I have updated the help text (if CLI changes)
- [ ] I have updated the menu text (if UI changes)

## Breaking Changes

If this PR introduces breaking changes, describe them here and provide migration instructions.

**Before:**
```bash
# Old behavior
```

**After:**
```bash
# New behavior
```

**Migration:**
```bash
# Steps to migrate
```

## Dependencies

List any new dependencies added or removed.

**Added:**
- None

**Removed:**
- None

**Updated:**
- None

## Performance Impact

Describe any performance implications of this change.

- [ ] No performance impact
- [ ] Performance improved (describe)
- [ ] Performance degraded (describe and justify)

## Security Impact

Describe any security implications of this change.

- [ ] No security impact
- [ ] Security improved (describe)
- [ ] Security consideration (describe)

## Deployment Notes

Special instructions for deploying this change (if any).

## Rollback Plan

If this change needs to be rolled back, how should it be done?

## Additional Notes

Any other information that reviewers should know.

---

## Reviewer Checklist

For maintainers reviewing this PR:

- [ ] Code follows project conventions
- [ ] Changes are well-documented
- [ ] Tests are adequate and pass
- [ ] No security issues introduced
- [ ] Performance is acceptable
- [ ] Breaking changes are justified and documented
- [ ] CHANGELOG.md updated
- [ ] Documentation updated
