#!/bin/zsh -f
#
# Remove the Power Protect helper and restore normal sleep.
#
# Usage:  sudo zsh Source/Helper/uninstall.zsh [--restore-script]
#
# --restore-script  Also put back the powerProtect.scpt that install.zsh replaced.
#                   Without it, the updated script stays. It still works with the sudoers rule.

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
case ${1:-} in
	"") ;;
	--restore-script) restore_script=1 ;;
	*) die "unknown option: $1" ;;
esac

(( EUID == 0 )) || die "run with sudo: sudo zsh ${0:A}"

/bin/launchctl bootout system/$LABEL 2>/dev/null
/bin/rm -f $PLIST_DEST $HELPER_DEST $SOCKET

failed=0
if /bin/launchctl print system/$LABEL >/dev/null 2>&1; then
	print -u2 -- "error: the helper job is still loaded"
	failed=1
fi

# Restore normal sleep, so the Mac does not stay awake with the display closed.
if ! /usr/bin/pmset -a disablesleep 0; then
	print -u2 -- "error: pmset -a disablesleep 0 failed. Run it again with sudo."
	failed=1
fi

if (( restore_script )); then
	[[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] || die "run with sudo from your own account to use --restore-script"
	user_home=$(/usr/bin/dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory)
	user_home=${user_home#NFSHomeDirectory: }
	script_dest="$user_home/Library/Application Scripts/com.if.Amphetamine/powerProtect.scpt"
	if [[ -f $script_dest.orig ]]; then
		/bin/mv -f "$script_dest.orig" "$script_dest"
		print "Restored the original powerProtect.scpt."
	else
		print -u2 -- "error: no backup at $script_dest.orig"
		failed=1
	fi
fi

(( failed )) && exit 1
print "Helper removed. Normal sleep is on."
