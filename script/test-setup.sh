#!/bin/bash
# Prepares a *pristine* Redmine checkout to run this plugin's test suite.
#
# Runs INSIDE the Redmine environment (official redmine docker image, or a CI
# runner with Redmine at $REDMINE_DIR). Idempotent: safe to re-run.
#
# Deliberately kept separate from any TauRes-specific image — the suite must
# prove the plugin works on stock Redmine, not on our customised build.
set -euo pipefail

REDMINE_DIR="${REDMINE_DIR:-/usr/src/redmine}"
PLUGIN_DIR="${PLUGIN_DIR:-$REDMINE_DIR/plugins/redmine_ldap_sync}"
DB_HOST="${DB_HOST:-ldapsync-test-mysql}"
DB_NAME="${DB_NAME:-redmine_test}"
DB_USER="${DB_USER:-redmine}"
DB_PASS="${DB_PASS:-redmine}"
LDAP_PORT="${LDAP_PORT:-3389}"
LDAP_BASE="${LDAP_BASE:-/tmp/ldapsync-ldap}"

export RAILS_ENV=test
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-testonly}"

step() { printf '\n=== %s\n' "$1"; }

step 'Installing OS packages (slapd, ldap-utils, build tools)'
# build-essential: the official image has no compiler, and the test group pulls
# gems with native extensions (json via oauth2/faraday).
if ! command -v slapd >/dev/null || ! command -v make >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq slapd ldap-utils build-essential
fi

if [ -n "${WITH_BROWSER:-}" ]; then
  step 'Installing chromium for the browser tests'
  # Debian's chromium, not google-chrome: it is packaged, and chromium-driver
  # gives Selenium a matching driver without reaching the internet. test/ui/base.rb
  # points Selenium at both via CHROME_BIN / CHROMEDRIVER_BIN.
  if ! command -v chromium >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chromium chromium-driver
  fi
  chromium --version; chromedriver --version
fi

step 'Installing test-group gems'
# The image excludes development:test. The shipped Gemfile.lock already resolves
# mocha/simplecov/capybara, so dropping only 'test' from the exclusion list needs
# no lock change and keeps BUNDLE_FROZEN=true satisfied. 'development' stays out
# (its debug gem needs a native build we don't want).
#
# Bundler refuses to replace gems under a world-writable directory without the
# sticky bit — which is exactly how the official image ships /usr/local/bundle.
find /usr/local/bundle -maxdepth 3 -type d -perm -0002 ! -perm -1000 -exec chmod +t {} + 2>/dev/null || true
cd "$REDMINE_DIR"

# Point BUNDLE_APP_CONFIG at a config we own instead of editing the image's.
# `bundle config set --local` writes to /usr/local/bundle/config (the image sets
# BUNDLE_APP_CONFIG there), which fails on GitHub Actions runners even as root.
# BUNDLE_WITHOUT alone does not help: bundler ranks the app config file ABOVE the
# environment, so the image's "development:test" would keep winning and the test
# group would never install. The image's config holds nothing but that one
# setting, so replacing the location loses nothing. Gems still land in GEM_HOME.
# test-run.sh must export the same path or bundler reverts to the image's config.
export BUNDLE_APP_CONFIG="${BUNDLE_APP_CONFIG_DIR:-/tmp/ldapsync-bundle}"
mkdir -p "$BUNDLE_APP_CONFIG"
printf 'BUNDLE_WITHOUT: "development"\n' > "$BUNDLE_APP_CONFIG/config"
echo "running as $(id -un); bundle config at $BUNDLE_APP_CONFIG; gems in ${GEM_HOME:-?}"
bundle install --quiet

step 'Writing config/database.yml (test only)'
cat > "$REDMINE_DIR/config/database.yml" <<YAML
test:
  adapter: mysql2
  host: $DB_HOST
  database: $DB_NAME
  username: $DB_USER
  password: $DB_PASS
  encoding: utf8mb4
  variables:
    transaction_isolation: "READ-COMMITTED"
YAML

step 'Migrating core + plugin schema'
bundle exec rake db:migrate
bundle exec rake redmine:plugins:migrate

step "Starting slapd on localhost:$LDAP_PORT"
# The fixtures hardcode 127.0.0.1:3389 (and use 127.0.0.2 as a host that must NOT
# answer), so slapd has to be local to this container — not a sidecar.
pkill -f "slapd .*$LDAP_PORT" 2>/dev/null || true
rm -rf "$LDAP_BASE"
mkdir -p "$LDAP_BASE/db"
LDAPCONF="$PLUGIN_DIR/test/fixtures/ldap"
cp "$LDAPCONF/slapd.conf" "$LDAP_BASE/"
sed -i "s|/var/run/slapd/slapd.pid|$LDAP_BASE/slapd.pid|; \
        s|/var/run/slapd/slapd.args|$LDAP_BASE/slapd.args|; \
        s|/var/lib/ldap|$LDAP_BASE/db|" "$LDAP_BASE/slapd.conf"

export LDAPNOINIT=yes
nohup slapd -d3 -f "$LDAP_BASE/slapd.conf" -h "ldap://localhost:$LDAP_PORT/" \
  > "$LDAP_BASE/slapd.log" 2>&1 &

for _ in $(seq 1 15); do
  if ldapsearch -x -H "ldap://localhost:$LDAP_PORT" -b "" -s base >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! ldapsearch -x -H "ldap://localhost:$LDAP_PORT" -b "" -s base >/dev/null 2>&1; then
  echo '!!! slapd failed to start:' >&2
  tail -30 "$LDAP_BASE/slapd.log" >&2
  exit 1
fi

step 'Seeding test directory'
# -c (continue on error) is required: one fixture group has a 292-character cn,
# whose 322-byte DN the mdb backend rejects (MDB_BAD_VALSIZE on dn2id_add) where
# the old hdb backend accepted it. 29 of 30 entries load; three group-count
# assertions in auth_source_ldap_test.rb are off by one because of it.
expected=$(grep -cE '^dn:' "$LDAPCONF/test-ldap.ldif")
ldapadd -x -D 'cn=admin,dc=redmine,dc=org' -w password \
  -H "ldap://localhost:$LDAP_PORT/" -f "$LDAPCONF/test-ldap.ldif" -c > /dev/null 2>&1 || true
entries=$(ldapsearch -x -o ldif-wrap=no -H "ldap://localhost:$LDAP_PORT" \
  -D 'cn=admin,dc=redmine,dc=org' -w password -b 'dc=redmine,dc=org' -LLL dn 2>/dev/null \
  | grep -cE '^dn:')
echo "$entries of $expected entries loaded"
if [ "$entries" -lt $((expected - 1)) ]; then
  echo "!!! more entries rejected than the one known-oversized DN — check $LDAP_BASE/slapd.log" >&2
  exit 1
fi

printf '\nReady. Run the suite with:\n  script/test-run.sh\n'
