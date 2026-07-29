#!/bin/bash
# Runs the test suite. Expects test-setup.sh to have been run in this environment.
#
#   script/test-run.sh                       # unit + functional (what CI runs)
#   script/test-run.sh test/unit/ldap_setting_test.rb
#   script/test-run.sh test/unit/foo_test.rb:42
#
# test/ui/* is NOT included: those need capybara + a real Chrome. test/performance
# needs the large LDIF fixture. Both are opt-in, run them by path if you want them.
set -euo pipefail

REDMINE_DIR="${REDMINE_DIR:-/usr/src/redmine}"
export RAILS_ENV=test
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-testonly}"

cd "$REDMINE_DIR"

# SEED=n reproduces a specific run order (minitest randomises per run).
if [ $# -eq 0 ]; then
  if [ -n "${SEED:-}" ]; then
    exec bundle exec bin/rails test --seed "$SEED" \
      plugins/redmine_ldap_sync/test/unit plugins/redmine_ldap_sync/test/functional
  fi
  exec bundle exec rake redmine:plugins:test NAME=redmine_ldap_sync
fi

# Paths are given relative to the plugin; make them relative to Redmine's root.
args=()
for a in "$@"; do
  case "$a" in
    plugins/*|/*) args+=("$a");;
    *) args+=("plugins/redmine_ldap_sync/$a");;
  esac
done
exec bundle exec bin/rails test "${args[@]}"
