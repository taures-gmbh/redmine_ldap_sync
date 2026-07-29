#!/bin/bash
# Runs the suite against several Redmine versions in turn, one pristine container
# each, and prints a summary table.
#
#   script/test-matrix.sh                 # the supported versions
#   script/test-matrix.sh 6.1.3 7.0.0     # specific ones
#
# Serial by design: test-docker.sh uses fixed container names.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
VERSIONS=("$@")
[ ${#VERSIONS[@]} -eq 0 ] && VERSIONS=(5.1 6.0 6.1 7.0)

results=()
for v in "${VERSIONS[@]}"; do
  echo "################ redmine:$v"
  if ! REDMINE_VERSION="$v" script/test-docker.sh up > "/tmp/ldapsync-matrix-$v-setup.log" 2>&1; then
    echo "SETUP FAILED — tail of /tmp/ldapsync-matrix-$v-setup.log:"
    tail -15 "/tmp/ldapsync-matrix-$v-setup.log"
    results+=("$v|SETUP FAILED|see /tmp/ldapsync-matrix-$v-setup.log")
    continue
  fi

  out=$(REDMINE_VERSION="$v" script/test-docker.sh run 2>&1)
  echo "$out" | tail -3
  line=$(echo "$out" | grep -E '^[0-9]+ runs,' | tail -1)
  rails=$(docker exec ldapsync-test-app sh -c 'ls -d /usr/local/bundle/gems/rails-[0-9]* 2>/dev/null | head -1 | sed "s|.*/rails-||"')
  ruby=$(docker exec ldapsync-test-app ruby -e 'print RUBY_VERSION')
  if [ -z "$line" ]; then
    results+=("$v|NO RESULT|ruby $ruby / rails $rails")
  else
    results+=("$v|$line|ruby $ruby / rails $rails")
  fi
done

script/test-docker.sh down > /dev/null 2>&1

printf '\n%-10s %-52s %s\n' REDMINE RESULT STACK
printf '%-10s %-52s %s\n' '-------' '------' '-----'
for r in "${results[@]}"; do
  IFS='|' read -r v line stack <<< "$r"
  printf '%-10s %-52s %s\n' "$v" "$line" "$stack"
done
