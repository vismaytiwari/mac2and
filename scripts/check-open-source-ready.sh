#!/usr/bin/env bash
set -euo pipefail

fail=0

tracked_env="$(git ls-files .env '.env.*' | grep -v '^.env.example$' || true)"
if [[ -n "$tracked_env" ]]; then
  echo "FAIL tracked private env files:"
  echo "$tracked_env"
  fail=1
fi

if find . -path './.git' -prune -o -path './_electron_backup_*' -prune -o -path './.build' -prune -o -path './dist' -prune -o -name '.env' -print | grep -q .; then
  echo "OK private .env exists locally and is ignored"
fi

if git check-ignore -q .env && git check-ignore -q _electron_backup_20260610_223553; then
  echo "OK .env and Electron backup folders are ignored"
else
  echo "FAIL .env or Electron backup folder is not ignored"
  fail=1
fi

if [[ -d dist ]] && find dist -name '.env' -print | grep -q .; then
  echo "FAIL packaged app contains .env"
  fail=1
fi

exit "$fail"
