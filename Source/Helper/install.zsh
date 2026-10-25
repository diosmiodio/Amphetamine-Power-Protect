#!/bin/zsh -f
#
# Install the Power Protect helper and the updated powerProtect.scpt.
#
# Usage:  sudo zsh Source/Helper/install.zsh [--user NAME]
#
# --user NAME  Install powerProtect.scpt for this account. Default: the user who is logged
#              in at the screen. Use it when an administrator installs for a standard account.
#
# The helper is a LaunchDaemon. It lets Power Protect change SleepDisabled without sudo,
# so it works when /etc/sudoers.d is missing, not included, or managed by another tool.

emulate -L zsh
setopt err_exit no_unset pipe_fail

LABEL=com.if.Amphetamine.PowerProtectHelper
HELPER_DEST=/Library/PrivilegedHelperTools/$LABEL
PLIST_DEST=/Library/LaunchDaemons/$LABEL.plist
SOCKET=/var/run/$LABEL.sock
SRC_DIR=${0:A:h}
SCRIPT_SOURCE=${SRC_DIR:h}/powerProtect.applescript

die() {
	print -u2 -- "error: $1"
	exit 1
}

target_user=""
case ${1:-} in
	"") ;;
	--user) target_user=${2:-} ; [[ -n $target_user ]] || die "--user needs a name" ;;
	*) die "unknown option: $1" ;;
esac

(( EUID == 0 )) || die "run with sudo: sudo zsh ${0:A}"

if [[ -z $target_user ]]; then
	target_user=$(/usr/bin/stat -f %Su /dev/console)
	[[ $target_user != root ]] || target_user=${SUDO_USER:-}
fi
[[ -n $target_user && $target_user != root ]] || die "cannot find the user. Use --user NAME"
/usr/bin/id -u $target_user >/dev/null 2>&1 || die "no such user: $target_user"
user_home=$(/usr/bin/dscl -plist . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null |
		/usr/bin/plutil -extract dsAttrTypeStandard:NFSHomeDirectory.0 raw -o - - 2>/dev/null) || user_home=""
[[ -d $user_home ]] || die "cannot find the home folder of $target_user"
SCRIPTS_DIR="$user_home/Library/Application Scripts/com.if.Amphetamine"
SCRIPT_DEST="$SCRIPTS_DIR/powerProtect.scpt"

# Run as the target user, so that root never follows a link that the user controls.
as_user() {
	/usr/bin/sudo -u $target_user -- "$@"
}

for f in $SRC_DIR/power-protect-helper.zsh $SRC_DIR/$LABEL.plist $SCRIPT_SOURCE; do
	[[ -f $f ]] || die "missing file: $f"
done
/usr/bin/plutil -lint -s $SRC_DIR/$LABEL.plist || die "invalid plist: $SRC_DIR/$LABEL.plist"
/bin/zsh -n $SRC_DIR/power-protect-helper.zsh || die "syntax error in power-protect-helper.zsh"

# Compile the script first, so a compile error stops the install before anything changes.
work_dir=$(/usr/bin/mktemp -d /tmp/amphetamine-power-protect.XXXXXX)
trap '/bin/rm -rf "$work_dir"' EXIT
/usr/bin/osacompile -o "$work_dir/powerProtect.scpt" $SCRIPT_SOURCE || die "cannot compile $SCRIPT_SOURCE"
/bin/chmod 0755 "$work_dir"
/bin/chmod 0644 "$work_dir/powerProtect.scpt"

print "Installing the helper..."
[[ -d /Library/PrivilegedHelperTools ]] || /usr/bin/install -d -o root -g wheel -m 1755 /Library/PrivilegedHelperTools
/usr/bin/install -S -o root -g wheel -m 0755 $SRC_DIR/power-protect-helper.zsh $HELPER_DEST
/usr/bin/install -S -o root -g wheel -m 0644 $SRC_DIR/$LABEL.plist $PLIST_DEST

/bin/launchctl bootout system/$LABEL 2>/dev/null || true
# A service that was disabled before does not load, so enable it before bootstrap.
/bin/launchctl enable system/$LABEL
# bootout can return before the job is fully removed, so try bootstrap more than once.
for attempt in 1 2 3 4 5; do
	bootstrap_error=$(/bin/launchctl bootstrap system $PLIST_DEST 2>&1) && break
	(( attempt < 5 )) || die "launchctl bootstrap failed: $bootstrap_error
Check System Settings > General > Login Items & Extensions."
	sleep 1
done

# Check the helper as the target user, because that is how Amphetamine connects to it.
reply=$(as_user /bin/sh -c '/usr/bin/printf "status\n" | /usr/bin/nc -U -w 5 "$1"' sh $SOCKET) || reply=""
[[ $reply == "ok "[01] ]] || die "the helper did not reply correctly (reply: '${reply}')"
print "Helper OK. SleepDisabled is ${reply#ok }."

print "Installing powerProtect.scpt for $target_user..."
for p in "$SCRIPTS_DIR" "$SCRIPT_DEST" "$SCRIPT_DEST.orig"; do
	[[ ! -L $p ]] || die "$p is a symbolic link. Remove it and try again."
done
as_user /bin/mkdir -p "$SCRIPTS_DIR"
# Keep the first original script, so uninstall.zsh --restore-script can put it back.
if [[ -e $SCRIPT_DEST && ! -e $SCRIPT_DEST.orig ]]; then
	as_user /bin/cp "$SCRIPT_DEST" "$SCRIPT_DEST.orig"
fi
as_user /usr/bin/install -S -m 0644 "$work_dir/powerProtect.scpt" "$SCRIPT_DEST"

print "Done. Quit and open Amphetamine again, then start a session with Power Protect."
