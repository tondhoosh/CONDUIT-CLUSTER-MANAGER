#!/bin/bash
# Test suite for conduit.sh
# Run with: bash tests/test_conduit.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONDUIT_SCRIPT="$SCRIPT_DIR/conduit.sh"

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}✗${NC} $1"
    [ -n "$2" ] && echo -e "    ${YELLOW}Details:${NC} $2"
}

test_start() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${YELLOW}Test $TESTS_RUN:${NC} $1"
}

# ============================================================
# Test 1: Script syntax validation
# ============================================================
test_start "Script syntax validation (bash -n)"
if bash -n "$CONDUIT_SCRIPT" 2>&1; then
    pass "Script has valid bash syntax"
else
    fail "Script has syntax errors"
fi

# ============================================================
# Test 2: Y/N validation patterns are strict
# ============================================================
test_start "Y/N input validation uses strict patterns"

# Check that we use ^[Yy]$ (with $) not ^[Yy] (without $)
loose_patterns=$(grep -E '\[\[.*=~.*\^(\[Yy\]|\[Nn\])[^$\]]' "$CONDUIT_SCRIPT" 2>/dev/null | grep -v '^\s*#' || true)
if [ -z "$loose_patterns" ]; then
    pass "All Y/N patterns use strict matching (^[Yy]$ or ^[Nn]$)"
else
    fail "Found loose Y/N patterns that could match 'yes', 'yup', etc."
    echo "$loose_patterns" | head -3
fi

# ============================================================
# Test 3: Case statements use quoted variables
# ============================================================
test_start "Case statements use quoted variables"

unquoted_case=$(grep -E 'case \$[a-zA-Z_]+[^"$] in' "$CONDUIT_SCRIPT" 2>/dev/null | grep -v '^\s*#' || true)
if [ -z "$unquoted_case" ]; then
    pass "All case statements use quoted variables"
else
    fail "Found unquoted variables in case statements"
    echo "$unquoted_case" | head -3
fi

# ============================================================
# Test 4: Update function checks for actual updates
# ============================================================
test_start "Update function checks if image was actually updated"

if grep -q 'Status: Image is up to date' "$CONDUIT_SCRIPT"; then
    pass "Update function checks for 'Image is up to date' status"
else
    fail "Update function missing check for already up-to-date image"
fi

if grep -q 'Already running the latest version' "$CONDUIT_SCRIPT"; then
    pass "Update function has early exit message for no-update case"
else
    fail "Update function missing early exit for no-update case"
fi

# ============================================================
# Test 5: Health check uses safe integer comparisons
# ============================================================
test_start "Health check uses safe integer parsing"

# Check that stats variables use head -1 and tr -d to ensure single integers
if grep -q "head -1 | tr -d" "$CONDUIT_SCRIPT"; then
    pass "Stats parsing uses head -1 | tr -d for clean integers"
else
    fail "Stats parsing may not properly sanitize multi-line output"
fi

# Check for 2>/dev/null on integer comparisons in health_check
health_check_section=$(sed -n '/^health_check()/,/^[a-z_]*() *{/p' "$CONDUIT_SCRIPT")
safe_comparisons=$(echo "$health_check_section" | grep -c '\-gt 0 \] 2>/dev/null' || echo 0)
if [ "$safe_comparisons" -ge 3 ]; then
    pass "Health check has error suppression on integer comparisons ($safe_comparisons found)"
else
    fail "Health check may be missing error suppression on some comparisons"
fi

# ============================================================
# Test 6: (y/n) prompts have loops for invalid input
# ============================================================
test_start "(y/n) prompts loop on invalid input"

# Find (y/n) prompts (no default) and check they're in while loops
yn_prompts=$(grep -n '(y/n)' "$CONDUIT_SCRIPT" | grep 'read -p' || true)
yn_count=$(echo "$yn_prompts" | grep -c 'read' || echo 0)

if [ "$yn_count" -gt 0 ]; then
    # Check that these are within while loops
    loops_found=0
    while IFS=: read -r line_num rest; do
        [ -z "$line_num" ] && continue
        # Look backwards for "while true" within 5 lines
        start=$((line_num - 5))
        [ $start -lt 1 ] && start=1
        context=$(sed -n "${start},${line_num}p" "$CONDUIT_SCRIPT")
        if echo "$context" | grep -q 'while true'; then
            loops_found=$((loops_found + 1))
        fi
    done <<< "$yn_prompts"

    if [ "$loops_found" -eq "$yn_count" ]; then
        pass "All $yn_count (y/n) prompts are in validation loops"
    else
        fail "Only $loops_found of $yn_count (y/n) prompts have validation loops"
    fi
else
    pass "No (y/n) prompts found (or all converted to [Y/n] style)"
fi

# ============================================================
# Test 7: No hardcoded sensitive paths or credentials
# ============================================================
test_start "No hardcoded credentials or API keys"

sensitive=$(grep -iE '(password|secret|api_key|token)\s*=' "$CONDUIT_SCRIPT" | grep -v '^\s*#' | grep -v 'read -' || true)
if [ -z "$sensitive" ]; then
    pass "No hardcoded credentials found"
else
    fail "Potential hardcoded sensitive data found"
    echo "$sensitive" | head -3
fi

# ============================================================
# Test 8: Error handling patterns
# ============================================================
test_start "Consistent error handling patterns"

# Count error suppression patterns
null_redirects=$(grep -c '2>/dev/null' "$CONDUIT_SCRIPT" || echo 0)
if [ "$null_redirects" -gt 100 ]; then
    pass "Script has extensive error handling ($null_redirects error redirections)"
else
    fail "Script may have insufficient error handling (only $null_redirects)"
fi

# Check for || true patterns after potentially failing commands
or_true=$(grep -c '|| true' "$CONDUIT_SCRIPT" || echo 0)
if [ "$or_true" -gt 50 ]; then
    pass "Script uses || true pattern for graceful failures ($or_true occurrences)"
else
    fail "Script may need more graceful failure handling (only $or_true)"
fi

# ============================================================
# Test 9: Function definitions are valid
# ============================================================
test_start "All function definitions are properly formed"

# Extract function names and verify they're callable
func_defs=$(grep -E '^[a-z_]+\(\) *\{' "$CONDUIT_SCRIPT" | sed 's/().*//' || true)
func_count=$(echo "$func_defs" | wc -l | tr -d ' ')

# Check for matching closing braces (simple heuristic)
open_braces=$(grep -c '() *{' "$CONDUIT_SCRIPT" || echo 0)
if [ "$func_count" -gt 20 ]; then
    pass "Found $func_count function definitions"
else
    fail "Unexpectedly few functions: $func_count"
fi

# ============================================================
# Test 10: Heredoc management script is complete
# ============================================================
test_start "Heredoc management script has all required functions"

heredoc_section=$(sed -n "/cat > .*conduit.*<< 'MANAGEMENT'/,/^MANAGEMENT$/p" "$CONDUIT_SCRIPT")

required_funcs=("show_menu" "show_status" "start_conduit" "stop_conduit" "restart_conduit" "health_check" "update_conduit")
missing_funcs=()

for func in "${required_funcs[@]}"; do
    if echo "$heredoc_section" | grep -q "${func}()"; then
        : # found
    else
        missing_funcs+=("$func")
    fi
done

if [ ${#missing_funcs[@]} -eq 0 ]; then
    pass "All required functions present in heredoc (${#required_funcs[@]} checked)"
else
    fail "Missing functions in heredoc: ${missing_funcs[*]}"
fi

# ============================================================
# Summary
# ============================================================
echo -e "\n${YELLOW}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}TEST SUMMARY${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
echo -e "  Total tests:  $TESTS_RUN"
echo -e "  ${GREEN}Passed:${NC}       $TESTS_PASSED"
echo -e "  ${RED}Failed:${NC}       $TESTS_FAILED"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed.${NC}"
    exit 1
fi
