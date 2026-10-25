#!/bin/zsh -f
#
# Remove the Power Protect helper and restore normal sleep.
#
# Usage:  sudo zsh Source/Helper/uninstall.zsh [--restore-script] [--user NAME]
#
# --restore-script  Also put back the powerProtect.scpt that install.zsh replaced.
#                   Without it, the updated script stays. It still works with the sudoers rule.
# --user NAME       The account for --restore-script. Default: the user who is logged in
#                   at the screen.

emulate -L zsh
setopt no_unset pipe_fail

LABEL=com.if.Amphetamine.PowerProtectHelper
HELPER_DEST=/Library/PrivilegedHelperTools/$LABEL
PLIST_DEST=/Library/LaunchDaemons/$LABEL.plist
SOCKET=/var/run/$LABEL.sock

die() {
	print -u2 -- "error: $1"
	exit 1
}

restore_script=0
target_user=""
while (( $# )); do
	case $1 in
		--restore-script) restore_script=1 ;;
		--user) target_user=${2:-}; [[ -n $target_user ]] || die "--user needs a name"; shift ;;
		*) die "unknown option: $1" ;;
	esac
	shift
done

(( EUID == 0 )) || die "run with sudo: sudo zsh ${0:A}"

/bin/launchctl bootout system/$LABEL 2>/dev/null
/bin/rm -f $PLIST_DEST $HELPER_DEST $SOCKET

failed=0
# bootout can return before the job is fully removed, so wait a short time.
for attempt in {1..10}; do
	/bin/launchctl print system/$LABEL >/dev/null 2>&1 || break
	if (( attempt == 10 )); then
		print -u2 -- "error: the helper job is still loaded"
		failed=1
	fi
	sleep 0.5
done

# Restore normal sleep, so the Mac does not stay awake with the display closed.
if ! /usr/bin/pmset -a disablesleep 0; then
	print -u2 -- "error: pmset -a disablesleep 0 failed. Run it again with sudo."
	failed=1
fi

if (( restore_script )); then
	if [[ -z $target_user ]]; then
		target_user=$(/usr/bin/stat -f %Su /dev/console)
		[[ $target_user != root ]] || target_user=${SUDO_USER:-}
	fi
	[[ -n $target_user && $target_user != root ]] || die "cannot find the user. Use --user NAME"
	user_home=$(/usr/bin/dscl -plist . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null |
		/usr/bin/plutil -extract dsAttrTypeStandard:NFSHomeDirectory.0 raw -o - - 2>/dev/null) || user_home=""
	[[ -d $user_home ]] || die "cannot find the home folder of $target_user"
	script_dest="$user_home/Library/Application Scripts/com.if.Amphetamine/powerProtect.scpt"
	if [[ -L $script_dest || -L $script_dest.orig ]]; then
		print -u2 -- "error: $script_dest or its backup is a symbolic link. Not restored."
		failed=1
	elif [[ -f $script_dest.orig ]]; then
		# Run as the user, so that root never follows a link that the user controls.
		/usr/bin/sudo -u $target_user -- /bin/mv -f "$script_dest.orig" "$script_dest"
		print "Restored the backup of powerProtect.scpt."
	else
		print -u2 -- "error: no backup at $script_dest.orig"
		failed=1
	fi
fi

(( failed )) && exit 1
print "Helper removed. Normal sleep is on."
