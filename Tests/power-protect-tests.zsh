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
trap 'exit 1' INT TERM

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

# id stub. The user is an administrator only if $T/is-admin exists.
cat > $T/id <<EOF
#!/bin/sh
[ "\$1" = -Gn ] || exit 1
if [ -f $T/is-admin ]; then echo "staff everyone admin"; else echo "staff everyone it-admin"; fi
EOF
chmod 755 $T/pmset $T/sudo $T/logger $T/id

# Helper with the stubs in place of /usr/bin/pmset and /usr/bin/logger.
sed -e "s|^PMSET=/usr/bin/pmset\$|PMSET=$T/pmset|" -e "s|/usr/bin/logger|$T/logger|" $HELPER_SRC > $T/helper
chmod 755 $T/helper
check "helper test copy uses the pmset stub" 1 "$(grep -c "^PMSET=$T/pmset\$" $T/helper)"

reset_state() {
	/bin/rm -f $T/fail-read $T/fail-write $T/stuck $T/sudo-allowed $T/sudo-calls $T/pmset-writes $T/sudoers \
		$T/is-admin $T/helper-program
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

# A client that sends part of a line and keeps the connection open must not keep the root
# helper alive. The helper must answer and exit within its 5 second limit.
# The last command of a zsh pipeline runs in this shell, so it can record the helper's time.
zmodload zsh/datetime
reset_state 0
start=$EPOCHREALTIME
(printf 'enab'; sleep 8) | { $T/helper > $T/held-reply; held_time=$(( EPOCHREALTIME - start )) }
check "helper answers a partial line held open" "error bad-request" "$(cat $T/held-reply)"
check "helper does not wait for the client to close" yes "$( (( held_time < 2 )) && print yes || print no)"
start=$EPOCHREALTIME
(sleep 8) | { $T/helper > $T/held-reply; held_time=$(( EPOCHREALTIME - start )) }
check "helper times out with no input" "error bad-request" "$(cat $T/held-reply)"
check "helper no-input timeout is about 5 seconds" yes "$( (( held_time >= 4.5 && held_time < 6.5 )) && print yes || print no)"
check "helper rejects a long request" "error bad-request" "$(printf 'enable%.0s' {1..100} | $T/helper)"

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
		-e "set sudoersFile of s to \"${3:-$T/sudoers}\"" \
		-e "set helperProgram of s to \"$T/helper-program\"" \
		-e "set idPath of s to \"$T/id\"" \
		-e "set loggerPath of s to \"$T/logger\"" \
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
reset_state 0; touch $T/sudo-allowed $T/is-admin
check "script enable with sudo rule outside sudoers.d (admin)" success "$(as_call $enable_call)"

# A standard user with no sudoers file is not in sudoers. Do not run sudo: each attempt is
# reported as a security incident.
reset_state 0; touch $T/sudo-allowed
check "script enable, standard user, no sudoers file" success "$(as_call $enable_call)"
check "script does not run sudo for a standard user with no sudoers file" no "$([[ -f $T/sudo-calls ]] && print yes || print no)"
check "a group named it-admin does not make the user an admin" false "$(as_call 'userIsAdmin()')"
touch $T/is-admin
check "the admin group makes the user an admin" true "$(as_call 'userIsAdmin()')"

# Helper installed but broken: a stale socket file with no listener. Fall back to sudo.
/usr/bin/python3 -I -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" $T/stale.sock
reset_state 0; touch $T/sudo-allowed $T/is-admin
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
reset_state 0; touch $T/helper-program
check "installed check with helper program only" true "$(as_call 'powerProtectSudoFileExists()')"

# The helper is installed but its socket is gone (for example, the background item is off).
# "disable" must not report success while sleep stays disabled.
reset_state 1; touch $T/helper-program
check "script disable fails when helper program exists but socket is gone" fail "$(as_call $disable_call)"
check "sleep is still disabled in that case" 1 "$(cat $T/state)"

# pmset -g fails: the state is unknown. Do not report "disable" as done without a write.
reset_state 1; touch $T/fail-read $T/sudoers $T/sudo-allowed
check "script disable with unreadable state does not report success" fail "$(as_call $disable_call)"
check "script disable with unreadable state still tries the write" 0 "$(cat $T/state)"

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

# --- Sudoers install command ------------------------------------------------------

# Run the install command against a sudoers tree in $T, without root.
#   $1  "include" if the main file includes the sudoers.d folder
run_sudoers_install() {
	local tree=$T/sudoers-tree
	/bin/rm -f $tree/main
	print -r -- "root ALL=(ALL) ALL" > $tree/main
	[[ $1 == include ]] && print -r -- "#includedir $tree/sd" >> $tree/main
	chmod 0440 $tree/main
	as_call 'sudoersInstallCommand(sudoersRuleText("first.last"), "first.last")' "" $tree/sd/amphetamine_PowerProtect | sed \
		-e "s|/usr/sbin/visudo -c -f /private/etc/sudoers|/usr/sbin/visudo -c -f $tree/main|" \
		-e "s|/usr/bin/pmset -g|$T/pmset -g|" \
		-e "s|/usr/bin/sudo -u \"\$user\" /usr/bin/sudo -n /usr/bin/pmset|$T/rule-check|" \
		-e "s|-o root -g wheel ||" \
		-e "s|/bin/mkdir -p /private/etc/sudoers.d|/bin/mkdir -p $tree/sd|" > $T/install-command.sh
	if grep -nE '/private/etc|/usr/bin/sudo |/usr/bin/pmset -g' $T/install-command.sh; then
		print -u2 "sudoers install test command still has a system path"
		exit 1
	fi
	/bin/sh $T/install-command.sh >/dev/null 2>$T/install-command-err
}
# Stands in for "sudo -u USER sudo -n pmset ...": the rule applies unless $T/rule-denied exists.
cat > $T/rule-check <<EOF
#!/bin/sh
echo "\$*" >> $T/rule-check-calls
[ ! -f $T/rule-denied ]
EOF
chmod 755 $T/rule-check
SD=$T/sudoers-tree/sd
mkdir -p $SD

reset_state 1
run_sudoers_install include; check "sudoers install succeeds when sudoers.d is included" 0 $?
check "sudoers install leaves mode 0440" 440 "$(stat -f %Lp $SD/amphetamine_PowerProtect 2>/dev/null)"
check "sudoers install tests the rule with the current value" "-a disablesleep 1" "$(tail -1 $T/rule-check-calls)"

# Another file at 0644 works with sudo. Plain "visudo -c" rejects it, the install must not.
rm -f $SD/*(N)
print -r -- "# other tool" > $SD/othertool; chmod 0644 $SD/othertool
run_sudoers_install include; check "sudoers install ignores the mode of other files" 0 $?
rm -f $SD/othertool

# A later sudoers entry asks for a password: the file is read, but the rule does not apply.
rm -f $SD/*(N); touch $T/rule-denied
run_sudoers_install include; check "sudoers install fails when the rule does not apply" 1 $?
check "sudoers install removes a rule that does not apply" no "$([[ -e $SD/amphetamine_PowerProtect ]] && print yes || print no)"
check "sudoers install says why" 1 "$(grep -c 'does not apply to first.last' $T/install-command-err)"
rm -f $T/rule-denied

rm -f $SD/*(N)
run_sudoers_install no-include; check "sudoers install fails when sudoers.d is not included" 1 $?
check "sudoers install removes the unused file" no "$([[ -e $SD/amphetamine_PowerProtect ]] && print yes || print no)"

rm -f $SD/*(N); print -r -- "# previous" > $SD/amphetamine_PowerProtect
run_sudoers_install no-include; check "sudoers install fails (with a previous file)" 1 $?
check "sudoers install restores the previous file" "# previous" "$(cat $SD/amphetamine_PowerProtect 2>/dev/null)"

# A copy of the rule in another file (a common manual workaround) makes the whole
# configuration invalid. The install must notice and roll back.
rm -f $SD/*(N)
print -r -- "Cmnd_Alias PMSET_AMPHETAMINE = /usr/bin/pmset -a disablesleep 1" > $SD/amphetamine
chmod 0440 $SD/amphetamine
run_sudoers_install include; check "sudoers install fails when the result does not parse" 1 $?
check "sudoers install rolls back a file that breaks the configuration" no "$([[ -e $SD/amphetamine_PowerProtect ]] && print yes || print no)"

# --- install.zsh and uninstall.zsh (dry run) ---------------------------------------

# Copies of the scripts with every system path moved into $T/root and $T/home, root-only
# commands replaced with stubs, and the root check removed. The helper socket is the
# emulator from above.
ME=$(/usr/bin/id -un)
R=$T/root
HOME_SCRIPTS="$T/home/Library/Application Scripts/com.if.Amphetamine"
export TEST_SOCKET=$SOCK
cat > $T/launchctl <<EOF
#!/bin/sh
echo "\$1" >> $T/launchctl-calls
[ "\$1" = print ] && exit 1
exit 0
EOF
chmod 755 $T/launchctl

dry_run_copy() {
	sed -e 's|^(( EUID == 0 )) \|\| die.*$|true|' \
		-e "s|^SRC_DIR=.*\$|SRC_DIR=$REPO/Source/Helper|" \
		-e "s|/Library/PrivilegedHelperTools|$R/PrivilegedHelperTools|g" \
		-e "s|/Library/LaunchDaemons|$R/LaunchDaemons|g" \
		-e "s|^SOCKET=.*\$|SOCKET=\${TEST_SOCKET}|" \
		-e "s|/bin/launchctl|$T/launchctl|g" \
		-e "s|/usr/bin/pmset|$T/pmset|g" \
		-e "s|-o root -g wheel ||g" \
		-e "s|/usr/bin/sudo -u \$target_user --|/usr/bin/env|g" \
		-e "s|\"\$user_home/Library/Application Scripts|\"$T/home/Library/Application Scripts|" \
		$1 > $2
	# Stop if any real system path is left, so a test can never change this Mac.
	if grep -nE '(^|[^A-Za-z/])/(Library|var/run)/|/bin/launchctl|/usr/bin/sudo|EUID' $2; then
		print -u2 "dry run copy of ${1:t} still has a system path"
		exit 1
	fi
}
dry_run_copy $REPO/Source/Helper/install.zsh $T/install-dry.zsh
dry_run_copy $REPO/Source/Helper/uninstall.zsh $T/uninstall-dry.zsh
mkdir -p $R/LaunchDaemons "$HOME_SCRIPTS"
print -r -- upstream > "$HOME_SCRIPTS/powerProtect.scpt"

reset_state 0
TEST_SOCKET=$SOCK zsh $T/install-dry.zsh --user $ME >/dev/null 2>$T/install-err; check "install succeeds" 0 $?
check "install puts the helper in place" yes "$([[ -x $R/PrivilegedHelperTools/com.if.Amphetamine.PowerProtectHelper ]] && print yes || print no)"
check "install puts the plist in place" yes "$([[ -f $R/LaunchDaemons/com.if.Amphetamine.PowerProtectHelper.plist ]] && print yes || print no)"
check "install calls launchctl bootout, enable, bootstrap in order" "bootout enable bootstrap" "$(tr '\n' ' ' < $T/launchctl-calls | sed 's/ $//')"
check "install keeps the original script" upstream "$(cat "$HOME_SCRIPTS/powerProtect.scpt.orig")"
check "install puts a compiled script in place" yes "$(/usr/bin/osadecompile "$HOME_SCRIPTS/powerProtect.scpt" 2>/dev/null | grep -q helperSocket && print yes || print no)"

TEST_SOCKET=$SOCK zsh $T/install-dry.zsh --user $ME >/dev/null 2>&1; check "install runs again" 0 $?
check "a second install does not replace the backup" upstream "$(cat "$HOME_SCRIPTS/powerProtect.scpt.orig")"

TEST_SOCKET=$T/no-helper.sock zsh $T/install-dry.zsh --user $ME >/dev/null 2>$T/install-err; check "install fails when the helper does not reply" 1 $?
check "install says why" 1 "$(grep -c 'did not reply' $T/install-err)"

mv "$HOME_SCRIPTS/powerProtect.scpt.orig" $T/orig-saved
ln -s /tmp/pp-should-not-exist "$HOME_SCRIPTS/powerProtect.scpt.orig"
TEST_SOCKET=$SOCK zsh $T/install-dry.zsh --user $ME >/dev/null 2>&1; check "install refuses a symbolic link" 1 $?
check "install did not write through the link" no "$([[ -e /tmp/pp-should-not-exist ]] && print yes || print no)"
rm -f "$HOME_SCRIPTS/powerProtect.scpt.orig"; mv $T/orig-saved "$HOME_SCRIPTS/powerProtect.scpt.orig"

zsh $T/install-dry.zsh --user no_such_user_pp >/dev/null 2>$T/install-err; check "install rejects an unknown user" 1 $?
check "install says the user is unknown" 1 "$(grep -c 'no such user' $T/install-err)"

reset_state 1
TEST_SOCKET=$SOCK zsh $T/uninstall-dry.zsh --restore-script --user $ME >/dev/null 2>&1; check "uninstall succeeds" 0 $?
check "uninstall removes the helper" no "$([[ -e $R/PrivilegedHelperTools/com.if.Amphetamine.PowerProtectHelper ]] && print yes || print no)"
check "uninstall removes the plist" no "$([[ -e $R/LaunchDaemons/com.if.Amphetamine.PowerProtectHelper.plist ]] && print yes || print no)"
check "uninstall turns normal sleep back on" 0 "$(cat $T/state)"
check "uninstall restores the original script" upstream "$(cat "$HOME_SCRIPTS/powerProtect.scpt")"
zsh $T/uninstall-dry.zsh --restore-script --user $ME >/dev/null 2>$T/uninstall-err; check "uninstall --restore-script fails with no backup" 1 $?
check "uninstall says there is no backup" 1 "$(grep -c 'no backup at' $T/uninstall-err)"

print
print "$pass passed, $fail failed"
(( fail == 0 ))
