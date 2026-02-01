---
name: Feature Request
about: Suggest a new feature or enhancement for Conduit Manager
title: '[FEATURE] '
labels: enhancement
assignees: ''
---

## Feature Description

A clear and concise description of the feature you'd like to see.

## Problem Statement

What problem does this feature solve? Who would benefit from it?

**Example:** "As a VPS operator with limited bandwidth, I need to set global bandwidth limits across all containers so that..."

## Proposed Solution

Describe how you envision this feature working.

**Example:** 
```bash
# Add global bandwidth limit setting
conduit-v2-complete.sh set-global-bandwidth 1000  # 1000 Mbps total
```

**Menu UI:**
```
Settings Menu:
  1. Container count: 8
  2. Max clients per container: 250
  3. Bandwidth per client: 3 Mbps
  4. [NEW] Global bandwidth limit: 1000 Mbps  <-- New option
```

## Alternatives Considered

What other approaches have you considered? Why is your proposed solution better?

## Use Cases

Provide specific scenarios where this feature would be useful.

**Use Case 1:** Running 16 containers on 1Gbps connection
- Current: Each container can use unlimited bandwidth (oversubscription)
- With feature: Total bandwidth capped at 1000 Mbps (predictable performance)

**Use Case 2:** [Add more if applicable]

## Implementation Suggestions (Optional)

If you have ideas about how this could be implemented technically, share them here.

<details>
<summary>Technical Implementation Ideas</summary>

```bash
# Example: Use tc (traffic control) for global limits
tc qdisc add dev eth0 root tbf rate 1000mbit burst 32kbit latency 400ms
```

Or:

```nginx
# Example: Nginx bandwidth limiting
limit_rate 125k;  # 1000 Mbps / 8 containers = 125 Mbps = 125k/s per backend
```

</details>

## Impact Assessment

How would this affect existing functionality?

- [ ] **Breaking change** (requires migration)
- [ ] **Non-breaking** (backward compatible)
- [ ] **Optional** (disabled by default)
- [ ] **Performance impact** (describe)
- [ ] **Security impact** (describe)

## Priority

How important is this feature to you?

- [ ] **Critical** - Blocking my use of Conduit Manager
- [ ] **High** - Would significantly improve my workflow
- [ ] **Medium** - Nice to have, but not urgent
- [ ] **Low** - Minor enhancement

## Additional Context

Screenshots, mockups, links to similar features in other projects, etc.

## Checklist

- [ ] I have searched for similar feature requests
- [ ] I have clearly described the problem this solves
- [ ] I have provided specific use cases
- [ ] I have considered backward compatibility
- [ ] I have assessed the priority realistically
