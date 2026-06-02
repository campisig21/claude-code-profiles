#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
total=0; failed=0
tests=(
  ccp_test.sh
  dispatch_backend_test.sh
  dispatch_codexlog_test.sh
  dispatch_doctor_test.sh
  dispatch_exec_test.sh
  dispatch_guardrails_test.sh
  dispatch_land_test.sh
  dispatch_lib_test.sh
  dispatch_local_preflight_test.sh
  dispatch_quick_test.sh
  dispatch_resume_test.sh
  dispatch_show_list_test.sh
  dispatch_verify_test.sh
  e2e_test.sh
  install_test.sh
  jsonutil_test.sh
  learn_capture_test.sh
  local_lifecycle_test.sh
  paths_test.sh
  profile_mgmt_create_test.sh
  profile_mgmt_lifecycle_test.sh
  profile_mgmt_query_test.sh
  smoke_test.sh
  wakeup_test.sh
)
for name in "${tests[@]}"; do
  t="$HERE/$name"
  [ -e "$t" ] || continue
  echo "RUN $(basename "$t")"
  bash "$t"; rc=$?
  total=$((total + 1))
  if [ "$rc" -ne 0 ]; then failed=$((failed + 1)); echo "  -> FAILED (rc=$rc)"; fi
done
echo "=== $((total - failed))/$total test files passed ==="
[ "$failed" -eq 0 ]
