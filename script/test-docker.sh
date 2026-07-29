#!/bin/bash
# Local test rig: runs the suite against a PRISTINE Redmine in Docker.
#
#   script/test-docker.sh up                # create containers + prepare (first run)
#   script/test-docker.sh run [test path…]  # run the suite
#   script/test-docker.sh shell             # shell inside the Redmine container
#   script/test-docker.sh down              # remove containers + network
#
# The plugin working tree is bind-mounted, so edits are picked up with no rebuild.
# Nothing here touches the TauRes image or the rm613-* clone stack.
set -euo pipefail

REDMINE_VERSION="${REDMINE_VERSION:-6.1.3}"
MYSQL_VERSION="${MYSQL_VERSION:-8.0}"
NET=ldapsync-test
DB=ldapsync-test-mysql
APP=ldapsync-test-app
PLUGIN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

up() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  docker rm -f "$DB" "$APP" >/dev/null 2>&1 || true

  echo "Starting mysql:$MYSQL_VERSION"
  docker run -d --name "$DB" --network "$NET" \
    -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=redmine_test \
    -e MYSQL_USER=redmine -e MYSQL_PASSWORD=redmine \
    "mysql:$MYSQL_VERSION" >/dev/null

  # Container DNS can answer with IPv6-only addresses for rubygems.org while the
  # container has no IPv6 egress; `bundle install` then hangs on connect for as
  # long as you let it (0:02 of CPU in 22 minutes). Seen after a Docker daemon
  # restart and on VPN. Pin whatever IPv4 the host can resolve.
  addhost=()
  for h in rubygems.org index.rubygems.org; do
    ip=$(dig +short A "$h" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    [ -n "$ip" ] && addhost+=(--add-host "$h:$ip")
  done
  [ ${#addhost[@]} -gt 0 ] && echo "Pinning IPv4: ${addhost[*]}"

  echo "Starting redmine:$REDMINE_VERSION (pristine)"
  docker run -d --name "$APP" --network "$NET" \
    ${addhost[@]+"${addhost[@]}"} \
    -v "$PLUGIN_SRC:/usr/src/redmine/plugins/redmine_ldap_sync" \
    --entrypoint sh "redmine:$REDMINE_VERSION" -c 'tail -f /dev/null' >/dev/null

  echo -n "Waiting for mysql"
  for _ in $(seq 1 60); do
    if docker exec "$DB" mysqladmin ping -uredmine -predmine --silent >/dev/null 2>&1; then
      echo " ok"; break
    fi
    echo -n .; sleep 2
  done

  # WITH_BROWSER=1 script/test-docker.sh up  prepares a container that can also run
  # the browser tests (script/test-run.sh test/ui)
  docker exec ${WITH_BROWSER:+-e WITH_BROWSER="$WITH_BROWSER"} "$APP" \
    bash /usr/src/redmine/plugins/redmine_ldap_sync/script/test-setup.sh
}

case "${1:-}" in
  up) up;;
  run) shift; docker exec "$APP" bash /usr/src/redmine/plugins/redmine_ldap_sync/script/test-run.sh "$@";;
  shell) docker exec -it -e RAILS_ENV=test -e SECRET_KEY_BASE=testonly -w /usr/src/redmine "$APP" bash;;
  down) docker rm -f "$DB" "$APP" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; echo "removed";;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 1;;
esac
