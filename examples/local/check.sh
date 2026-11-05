#!/bin/sh
# Runs on the host: sh check.sh, or podman exec -i circuit-kestra sh < check.sh.
# The test hosts may have no curl, so the requests run with the curl in the
# Kestra container, against its own web server.
#
# Signs in as the admin the example sets, checks a wrong password and no
# password are refused, saves a flow the first time, and runs it. The flow
# fails unless secret("CI_GREETING") is the value the example passes in.
# After a restart, the flow and its earlier runs are still there.
set -eu
# stdin is this script when it's piped in, so only the request that sends a
# body gets -i.
k() { podman exec kestra curl -s "$@"; }
ki() { podman exec -i kestra curl -s "$@"; }
api=http://127.0.0.1:8080/api/v1/main
auth="owner@example.com:Correct-horse-battery-9"
fail() { echo "FAIL: $*" >&2; exit 1; }

# The web server answers before the admin account is set up.
i=0
until [ "$(k -o /dev/null -w '%{http_code}' -u "$auth" "$api/flows/search")" = 200 ]; do
  i=$((i + 1)); [ "$i" -lt 600 ] || fail "Kestra didn't let the admin in within 10 minutes"
  sleep 1
done
[ "$(k -o /dev/null -w '%{http_code}' -u owner@example.com:Wrong-password-1 "$api/flows/search")" = 401 ] || fail "a wrong password was let in"
[ "$(k -o /dev/null -w '%{http_code}' "$api/flows/search")" = 401 ] || fail "no password was let in"
echo "admin: ok"

if [ "$(k -o /dev/null -w '%{http_code}' -u "$auth" "$api/flows/ci/check")" = 200 ]; then
  runs=$(k -u "$auth" "$api/executions/search?namespace=ci&flowId=check" | grep -o '"total":[0-9]*' | cut -d: -f2)
  [ "${runs:-0}" -ge 1 ] || fail "the flow is back, but its earlier runs aren't"
  echo "flow: still there, with $runs run(s)"
else
  ki -u "$auth" -X POST -H 'content-type: application/x-yaml' --data-binary @- "$api/flows" >/dev/null <<'YAML'
id: check
namespace: ci
tasks:
  - id: greeting
    type: io.kestra.plugin.core.execution.Assert
    conditions:
      - "{{ secret('CI_GREETING') == 'hello-from-a-secret-7' }}"
YAML
  [ "$(k -o /dev/null -w '%{http_code}' -u "$auth" "$api/flows/ci/check")" = 200 ] || fail "the flow wasn't saved"
  echo "flow: saved"
fi

id=$(k -u "$auth" -X POST "$api/executions/ci/check" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
[ -n "$id" ] || fail "the flow didn't start"
i=0
while :; do
  out=$(k -u "$auth" "$api/executions/$id")
  case $out in
    *'"current":"SUCCESS"'*) break ;;
    *'"current":"FAILED"'* | *'"current":"KILLED"'*) fail "the run failed: $out" ;;
  esac
  i=$((i + 1)); [ "$i" -lt 300 ] || fail "the run didn't finish in 5 minutes: $out"
  sleep 1
done
echo "run $id: SUCCESS, the secret matched"

# The port is published on 127.0.0.1 only, so the host's address on
# Podman's bridge, which the container can reach, gets no answer.
if k -o /dev/null --max-time 5 http://host.containers.internal:8080/ping; then fail "port 8080 answers on the host's bridge address"; fi
echo "web server: not on the host's bridge address"
echo "All checks passed."
