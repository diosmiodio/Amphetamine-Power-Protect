#!/bin/zsh -f
#
# Power Protect helper for Amphetamine.
#
# launchd starts one copy of this script for each connection to the helper socket
# (inetdCompatibility). The connection is on stdin and stdout. The script reads one
# request line, changes SleepDisabled with pmset, and writes one reply line.
#
# Requests:  enable | disable | status
# Replies:   ok <0|1>            <0|1> is the SleepDisabled value after the request
#            error <reason>
#
# This script runs as root. It does not use sudo, so it does not depend on the
# sudoers configuration.

emulate -L zsh
setopt no_unset pipe_fail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PMSET=/usr/bin/pmset
LOG_TAG=AmphetaminePowerProtect

log_msg() {
	/usr/bin/logger -t $LOG_TAG -- "$LOG_TAG: helper: $1" 2>/dev/null
}

reply() {
	print -r -- "$1"
}

# Print the current SleepDisabled value (0 or 1). pmset does not show the key when it is 0.
# Match the first field only: other lines list process names, which any user can choose.
sleep_disabled() {
	local settings value
	settings=$($PMSET -g 2>/dev/null) || return 1
	value=$(print -r -- "$settings" | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }')
	if [[ $value == 1 ]]; then
		print 1
	else
		print 0
	fi
}

# One read(2) of at most 64 bytes, with a 5 second limit. "read -t" only limits the wait for
# the first byte, so a client could keep this root process alive by sending a partial line.
zmodload zsh/system
request=""
sysread -t 5 -s 64 -i 0 request
request=${request%%$'\n'*}
request=${request%$'\r'}

case $request in
	enable)  target=1 ;;
	disable) target=0 ;;
	status)  target="" ;;
	*)
		log_msg "rejected request (${#request} characters)"
		reply "error bad-request"
		exit 2
		;;
esac

if [[ -n $target ]]; then
	if ! $PMSET -a disablesleep $target >/dev/null 2>&1; then
		log_msg "$request: pmset -a disablesleep $target failed"
		reply "error pmset-write-failed"
		exit 1
	fi
fi

if ! state=$(sleep_disabled); then
	log_msg "$request: pmset -g failed"
	reply "error pmset-read-failed"
	exit 1
fi

if [[ -n $target && $state != $target ]]; then
	log_msg "$request: SleepDisabled is $state after write"
	reply "error state-$state"
	exit 1
fi

[[ -n $target ]] && log_msg "$request: SleepDisabled=$state"
reply "ok $state"
