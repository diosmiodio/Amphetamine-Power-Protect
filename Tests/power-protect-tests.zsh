#!/bin/zsh -f
#
# Tests for the Power Protect script and helper. They do not need root and do not
# change the real sleep settings: pmset, sudo and logger are replaced with stubs.
#
# Usage:  zsh Tests/power-protect-tests.zsh

emulate -L zsh
setopt no_unset pipe_fail

REPO=${0:A:h:h}
HELPER_SRC=$REPO/Source/Helper/power-protect-helper.zsh
SCRIPT_SRC=$REPO/Source/powerProtect.applescript
PLIST_SRC=$REPO/Source/Helper/com.if.Amphetamine.PowerProtectHelper.plist

# UNIX socket paths must be short, so use /tmp.
T=$(/usr/bin/mktemp -d /tmp/pptest.XXXXXX)
EMULATOR_PID=""
cleanup() {
	[[ -n $EMULATOR_PID ]] && kill $EMULATOR_PID 2>/dev/null
	/bin/rm -rf $T
}
trap cleanup EXIT

pass=0
fail=0
check() {
	local name=$1 expected=$2 actual=$3
	if [[ $actual == $expected ]]; then
		(( pass++ ))
		print -r -- "ok    $name"
	else
		(( fail++ ))
		print -r -- "FAIL  $name: expected '$expected', got '$actual'"
	fi
}

# --- Stubs -------------------------------------------------------------------

# pmset stub. State is in $T/state. Files in $T change its behavior:
#   fail-read   pmset -g fails
#   fail-write  pmset -a fails
#   stuck       pmset -a succeeds but does not change the state
cat > $T/pmset <<EOF
#!/bin/sh
case "\$1" in
	-g)
		[ -f $T/fail-read ] && exit 1
		printf 'System-wide power settings:\n sleep                1\n'
		[ "\$(cat $T/state)" = 1 ] && printf ' SleepDisabled\t\t1\n'
		exit 0 ;;
	-a)
		[ "\$2" = disablesleep ] || exit 2
		case "\$3" in 0|1) ;; *) exit 2 ;; esac
		[ -f $T/fail-write ] && exit 1
		[ -f $T/stuck ] || printf '%s' "\$3" > $T/state
		echo "\$3" >> $T/pmset-writes
		exit 0 ;;
esac
exit 2
EOF

# sudo stub. Logs its arguments. If $T/sudo-allowed exists, runs the command, otherwise
# fails like "sudo -n" does when a password is required.
cat > $T/sudo <<EOF
#!/bin/sh
echo "\$*" >> $T/sudo-calls
[ "\$1" = -n ] || { echo "sudo called without -n" >> $T/sudo-calls; exit 1; }
shift
[ -f $T/sudo-allowed ] || { echo "sudo: a password is required" >&2; exit 1; }
exec "\$@"
EOF

cat > $T/logger <<EOF
#!/bin/sh
echo "\$*" >> $T/log
EOF
chmod 755 $T/pmset $T/sudo $T/logger

# Helper with the stubs in place of /usr/bin/pmset and /usr/bin/logger.
sed -e "s|^PMSET=/usr/bin/pmset\$|PMSET=$T/pmset|" -e "s|/usr/bin/logger|$T/logger|" $HELPER_SRC > $T/helper
chmod 755 $T/helper
check "helper test copy uses the pmset stub" 1 "$(grep -c "^PMSET=$T/pmset\$" $T/helper)"

reset_state() {
	/bin/rm -f $T/fail-read $T/fail-write $T/stuck $T/sudo-allowed $T/sudo-calls $T/pmset-writes $T/sudoers
	printf '%s' "${1:-0}" > $T/state
}

# --- Static checks -----------------------------------------------------------

for f in $HELPER_SRC $REPO/Source/Helper/install.zsh $REPO/Source/Helper/uninstall.zsh; do
	/bin/zsh -n $f && r=ok || r=error
	check "zsh -n ${f:t}" ok $r
done
/usr/bin/plutil -lint -s $PLIST_SRC && r=ok || r=error
check "plutil -lint ${PLIST_SRC:t}" ok $r
/usr/bin/osacompile -o $T/powerProtect.scpt $SCRIPT_SRC && r=ok || r=error
check "osacompile powerProtect.applescript" ok $r

# --- Helper: stdin/stdout protocol ---------------------------------------------

helper() {
	printf "$1" | $T/helper
}

reset_state 0
check "helper enable" "ok 1" "$(helper 'enable\n')"
check "helper enable sets state" 1 "$(cat $T/state)"
check "helper status" "ok 1" "$(helper 'status\n')"
check "helper disable" "ok 0" "$(helper 'disable\n')"
check "helper disable sets state" 0 "$(cat $T/state)"
check "helper accepts CRLF" "ok 1" "$(helper 'enable\r\n')"
check "helper accepts a request without newline" "ok 0" "$(helper 'disable')"
check "helper rejects unknown request" "error bad-request" "$(helper 'sleep\n')"
check "helper rejects shell text" "error bad-request" "$(helper 'enable; touch /tmp/pwned\n')"
check "helper rejects request with argument" "error bad-request" "$(helper 'enable 1\n')"
check "helper rejects empty input" "error bad-request" "$(helper '')"
helper 'bogus\n' >/dev/null; check "helper exit code for bad request" 2 $?
check "helper did not write for rejected requests" 0 "$(cat $T/state)"

reset_state 0; touch $T/fail-write
check "helper reports pmset write failure" "error pmset-write-failed" "$(helper 'enable\n')"
reset_state 0; touch $T/stuck
check "helper verifies the state after write" "error state-0" "$(helper 'enable\n')"
reset_state 0; touch $T/fail-read
check "helper reports pmset read failure" "error pmset-read-failed" "$(helper 'status\n')"

# --- Helper: through a UNIX socket, as launchd runs it -------------------------

SOCK=$T/helper.sock
/usr/bin/python3 -I $REPO/Tests/inetd-emulator.py $SOCK $T/helper &
EMULATOR_PID=$!
for i in {1..50}; do [[ -S $SOCK ]] && break; sleep 0.1; done
check "socket emulator is listening" yes "$([[ -S $SOCK ]] && print yes || print no)"

nc_request() {
	/usr/bin/printf '%s\n' "$1" | /usr/bin/nc -U -w 5 $SOCK
}
reset_state 0
check "socket enable" "ok 1" "$(nc_request enable)"
check "socket status" "ok 1" "$(nc_request status)"
check "socket disable" "ok 0" "$(nc_request disable)"
check "socket bad request" "error bad-request" "$(nc_request reboot)"

# --- AppleScript ---------------------------------------------------------------

# Run a handler of the compiled script with stub paths.
#   $1  AppleScript call, for example: enableDisablePowerProtect("enable")
#   $2  helper socket path (default: no helper)
as_call() {
	/usr/bin/osascript \
		-e "set s to load script POSIX file \"$T/powerProtect.scpt\"" \
		-e "set helperSocket of s to \"${2:-$T/no-helper.sock}\"" \
		-e "set pmsetPath of s to \"$T/pmset\"" \
		-e "set sudoPath of s to \"$T/sudo\"" \
		-e "set sudoersFile of s to \"$T/sudoers\"" \
		-e "tell s to $1" 2>>$T/osascript-stderr
}
enable_call='enableDisablePowerProtect("enable")'
disable_call='enableDisablePowerProtect("disable")'

reset_state 0
check "script enable with helper" success "$(as_call $enable_call $SOCK)"
check "script enable with helper sets state" 1 "$(cat $T/state)"
check "script enable with helper does not call sudo" no "$([[ -f $T/sudo-calls ]] && print yes || print no)"
check "script disable with helper" success "$(as_call $disable_call $SOCK)"
check "script disable with helper sets state" 0 "$(cat $T/state)"

reset_state 1
check "script enable when already enabled" success "$(as_call $enable_call $SOCK)"
check "script enable when already enabled does not write" no "$([[ -f $T/pmset-writes ]] && print yes || print no)"
reset_state 0
check "script disable when sleep is already on (upstream returned pmset output)" success "$(as_call $disable_call)"

# Nothing installed: keep the original behavior (no change, no alert).
reset_state 0
check "script enable with nothing installed" success "$(as_call $enable_call)"
check "script enable with nothing installed does not change state" 0 "$(cat $T/state)"

# Issue #6: sudoers file present, rule does not apply. sudo must be non-interactive and the
# script must report the failure instead of hanging or prompting.
reset_state 0; touch $T/sudoers
check "script enable, sudoers file but rule does not apply" fail "$(as_call $enable_call)"
check "script calls sudo with -n" "-n $T/pmset -a disablesleep 1" "$(head -1 $T/sudo-calls)"

reset_state 0; touch $T/sudoers $T/sudo-allowed
check "script enable with working sudo rule" success "$(as_call $enable_call)"
check "script enable with working sudo rule sets state" 1 "$(cat $T/state)"
check "script disable with working sudo rule" success "$(as_call $disable_call)"
check "script disable with working sudo rule sets state" 0 "$(cat $T/state)"

# sudo -n works even if the rule is not in /etc/sudoers.d (for example in /etc/sudoers).
reset_state 0; touch $T/sudo-allowed
check "script enable with sudo rule outside sudoers.d" success "$(as_call $enable_call)"

# Helper installed but broken: a stale socket file with no listener. Fall back to sudo.
/usr/bin/python3 -I -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" $T/stale.sock
reset_state 0; touch $T/sudo-allowed
check "script falls back to sudo when the helper is broken" success "$(as_call $enable_call $T/stale.sock)"
reset_state 0
check "script reports failure when helper is broken and sudo fails" fail "$(as_call $enable_call $T/stale.sock)"

reset_state 0; touch $T/stuck $T/sudo-allowed $T/sudoers
check "script reports failure when pmset does not change the state" fail "$(as_call $enable_call $SOCK)"

reset_state 0
check "script rejects unknown input" fail "$(as_call 'enableDisablePowerProtect("toggle")' $SOCK)"

reset_state 0
check "installed check with helper" true "$(as_call 'powerProtectSudoFileExists()' $SOCK)"
check "installed check with nothing" false "$(as_call 'powerProtectSudoFileExists()')"
touch $T/sudoers
check "installed check with sudoers file" true "$(as_call 'powerProtectSudoFileExists()')"

# The sudoers text must pass visudo, with and without the user line.
# First make sure visudo rejects bad syntax here, so the checks below mean something.
printf 'not = valid sudoers ((\n' > $T/bad-rule
chmod 0440 $T/bad-rule
/usr/sbin/visudo -c -q -f $T/bad-rule >/dev/null 2>&1 && r=accepted || r=rejected
check "visudo rejects bad syntax (control)" rejected $r
for user in diosmiodio first.last 'bad user' 'x ALL=(ALL) ALL'; do
	/bin/rm -f $T/rule
	as_call "sudoersRuleText(\"$user\")" > $T/rule
	chmod 0440 $T/rule
	/usr/sbin/visudo -c -q -f $T/rule >/dev/null 2>&1 && r=ok || r=error
	check "visudo accepts rule text for '$user'" ok $r
done
check "rule text has the user line for a safe name" 1 "$(as_call 'sudoersRuleText("first.last")' | grep -c '^first.last ALL=(root) NOPASSWD: PMSET_AMPHETAMINE$')"
check "rule text has no user line for an unsafe name" 0 "$(as_call 'sudoersRuleText("x ALL=(ALL) ALL")' | grep -c 'ALL=(ALL)')"

print
print "$pass passed, $fail failed"
(( fail == 0 ))
