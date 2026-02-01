# 🧪 Institutional Test Plan: Conduit Cluster V2
**Version:** 2.0.0  
**Compliance Standard:** Iran-Optimized High-Availability Cluster  
**Scope:** Functional Verification, Security Auditing, Performance Integrity, Resilience.

---

## 1. Testing Strategy
This test plan validates the deployment against the "V2 Architecture Specification" using a rigid automated framework. Each test case (TC) corresponds to a critical architectural requirement.

| ID | Test Category | Requirement | Validation Method |
|----|--------------|-------------|-------------------|
| **TC-001** | Kernel / OS | System must use BBR+FQ for congestion control. | `sysctl` kernel parameter verification |
| **TC-002** | Security | Containers must NOT be reachable via public IP. | `netstat` binding analysis (127.0.0.1 check) |
| **TC-003** | Architecture | Nginx must act as the sole L4 ingress point. | Connectivity check on Port 443 + Backend isolation check |
| **TC-004** | Resilience | System must have defined resource caps to prevent OOM. | Docker inspection of `Memory` and `NanoCPUs` limits |
| **TC-005** | Functionality | All nodes must successfully handshake with upstream. | Log pattern matching for "Connected to Psiphon" |

---

## 2. Test Cases Detail

### TC-001: Network Stack Optimization Integrity
*   **Objective**: Ensure low-latency/high-loss optimization is active.
*   **Success Criteria**:
    *   `net.ipv4.tcp_congestion_control` returns `bbr`
    *   `net.core.default_qdisc` returns `fq`
*   **Failure Impact**: Critical. Without BBR, throughput drops by ~60% on high-latency links.

### TC-002: Network Isolation & Binding Security
*   **Objective**: Verify "Defense in Depth" (Cluster containers hidden behind Load Balancer).
*   **Success Criteria**:
    *   All backend containers (10001-10008) must bind to `127.0.0.1`.
    *   No docker-proxy process shall bind to `0.0.0.0` or `::`.
*   **Failure Impact**: High. Public exposure of backends bypasses the Load Balancer and exposes raw container ports to scanning.

### TC-003: Load Balancer Role Assertion
*   **Objective**: Confirm Nginx is the primary ingress controller.
*   **Success Criteria**:
    *   Port 443 is OPEN and OWNED by `nginx` process.
    *   Traffic received on 443 routes to backends (validated via `stream` module logs or connection count).
*   **Failure Impact**: Critical. Service outage (users cannot connect).

### TC-004: Resource Governance
*   **Objective**: Prevent "Noisy Neighbor" effect and OOM crashes.
*   **Success Criteria**:
    *   `Memory` limit <= 256MB.
    *   `CpuQuota` / `NanoCPUs` set to 0.1 equivalent.
*   **Failure Impact**: Medium. Single container crash could destabilize the entire VPS.

### TC-005: Upstream Handshake Validation
*   **Objective**: Functional confirmation of service.
*   **Success Criteria**:
    *   Application logs must contain `[OK] Connected to Psiphon network` within the last session.
*   **Failure Impact**: Critical. The node is essentially "dead" even if running.

---

## 3. Automation Tooling
All test cases are automated via the `self-test.sh` suite located in the repository root.

**Execution Command:**
```bash
./self-test.sh --audit
```

**Audit Output Format:**
The script generates a cryptographically signed-like summary suitable for copy-pasting into compliance reports.

**Frequency:**
*   Post-Deployment (Installation Sign-off)
*   Daily (Cron Health Check)
*   Post-Incident (Recovery Verification)
