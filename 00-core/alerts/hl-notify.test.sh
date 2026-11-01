#!/bin/bash
# Tests for hl-notify: bash 00-core/alerts/hl-notify.test.sh (stubs curl, sends nothing to Telegram).
set -u
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# Stub curl: records argv (one per line) and the -K config read from stdin, answers like the Bot API.
cat > "$t/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$t/argv"; cat >> "$t/cfg"; echo "---" >> "$t/argv"
[ -f "$t/down" ] && { echo '{"ok":false,"error_code":502}'; exit 0; }
echo '{"ok":true,"result":{}}'
EOF
chmod +x "$t/curl"
printf 'TG_BOT_TOKEN=123:SECRETTOKEN\nTG_CHAT_ID=-1001\n' > "$t/env"
export TG_ENV="$t/env" TG_CURL="$t/curl" HL_NOTIFY_SPOOL="$t/spool" HL_NOTIFY_RETRY_SLEEP=0
fail=0
ok() { echo "ok   $1"; }; ko() { echo "FAIL $1"; fail=1; }
reset() { rm -f "$t/argv" "$t/cfg"; }
# field <name> : value of the last --data-urlencode name=...
field() { grep "^$1=" "$t/argv" | tail -n 1 | cut -d= -f2-; }

check() { local want_text=$1 want_silent=$2; shift 2; reset; "$here/hl-notify" "$@"
  local got; got="$(field text)|$(field disable_notification)"
  [ "$got" = "$want_text|$want_silent" ] && ok "$*" || ko "$* -> '$got' want '$want_text|$want_silent'"; }
check "🔴 homelab: disk full" false hl-critical "disk full"
check "🔴 homelab: hot" false hl-warn "hot"
check "ℹ️ homelab: digest line" true hl-digest "digest line"
check "ℹ️ homelab: x" true whatever "x"
check "🟢 homelab: core: all clear" true hl-critical "core: all clear"
check "ℹ️ homelab: a b c" true hl-digest $'a\nb\tc'

reset; "$here/hl-notify" hl-digest "x"
[ "$(field chat_id)" = "-1001" ] && ok "chat id sent" || ko "chat id"
grep -q SECRETTOKEN "$t/argv" && ko "token leaked into argv" || ok "token not in argv"
grep -q 'url = "https://api.telegram.org/bot123:SECRETTOKEN/sendMessage"' "$t/cfg" && ok "token sent on stdin config" || ko "stdin config"
grep -q '^message_thread_id=' "$t/argv" && ko "thread id without TG_THREAD_ID" || ok "no thread id by default"
echo 'TG_THREAD_ID=7' >> "$t/env"; reset; "$here/hl-notify" hl-digest "x"
[ "$(field message_thread_id)" = "7" ] && ok "thread id when set" || ko "thread id"

"$here/hl-notify" hl-digest 2>/dev/null; [ $? -eq 2 ] && ok "empty message -> exit 2" || ko "empty message"

# Telegram down: exit 1, 3 tries, message spooled; next good call sends the spool first, in order.
reset; touch "$t/down"; "$here/hl-notify" hl-critical "first" 2>/dev/null; rc=$?
[ $rc -eq 1 ] && ok "send failure -> exit 1" || ko "send failure rc=$rc"
[ "$(grep -c '^---$' "$t/argv")" = 3 ] && ok "3 attempts" || ko "attempts"
"$here/hl-notify" hl-digest "second" 2>/dev/null
[ "$(wc -l < "$t/spool/queue")" = 2 ] && ok "both spooled" || ko "spool count"
rm -f "$t/down"; reset; "$here/hl-notify" hl-digest "third"; rc=$?
texts=$(grep '^text=' "$t/argv" | cut -d= -f2-)
[ $rc -eq 0 ] && [ "$(sed -n 1p <<<"$texts" | grep -c 'delayed.*first')" = 1 ] && [ "$(sed -n 2p <<<"$texts" | grep -c 'delayed.*second')" = 1 ] \
  && [ "$(sed -n 3p <<<"$texts")" = "ℹ️ homelab: third" ] && ok "spool flushed in order, then new message" || ko "flush: $texts"
sed -n 1p <<<"$texts" | grep -q "^🔴" && ok "spooled red stays red" || ko "spooled state"
[ ! -s "$t/spool/queue" ] && ok "spool empty after flush" || ko "spool not empty"

# Missing config: exit 3 and spooled, so nothing is lost before the token exists.
TG_ENV="$t/nope" "$here/hl-notify" hl-warn "no config" 2>/dev/null; [ $? -eq 3 ] && ok "missing config -> exit 3" || ko "missing config"
grep -q "no config" "$t/spool/queue" && ok "missing config spooled" || ko "missing config spool"
exit $fail
