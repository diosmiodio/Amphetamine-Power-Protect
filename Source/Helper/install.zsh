#!/bin/zsh -f
#
# Install the Power Protect helper and the updated powerProtect.scpt.
#
# Usage:  sudo zsh Source/Helper/install.zsh
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

(( EUID == 0 )) || die "run with sudo: sudo zsh ${0:A}"
[[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] || die "run with sudo from your own account, so the script can find your Amphetamine scripts folder"

user_home=$(/usr/bin/dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory)
user_home=${user_home#NFSHomeDirectory: }
[[ -d $user_home ]] || die "cannot find the home folder of $SUDO_USER"
SCRIPTS_DIR="$user_home/Library/Application Scripts/com.if.Amphetamine"
SCRIPT_DEST="$SCRIPTS_DIR/powerProtect.scpt"

for f in $SRC_DIR/power-protect-helper.zsh $SRC_DIR/$LABEL.plist $SCRIPT_SOURCE; do
	[[ -f $f ]] || die "missing file: $f"
done
/usr/bin/plutil -lint -s $SRC_DIR/$LABEL.plist || die "invalid plist: $SRC_DIR/$LABEL.plist"
/bin/zsh -n $SRC_DIR/power-protect-helper.zsh || die "syntax error in power-protect-helper.zsh"

# Compile the script first, so a compile error stops the install before anything changes.
work_dir=$(/usr/bin/mktemp -d /tmp/amphetamine-power-protect.XXXXXX)
trap '/bin/rm -rf "$work_dir"' EXIT
/usr/bin/osacompile -o "$work_dir/powerProtect.scpt" $SCRIPT_SOURCE || die "cannot compile $SCRIPT_SOURCE"

print "Installing the helper..."
/usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
/usr/bin/install -S -o root -g wheel -m 0755 $SRC_DIR/power-protect-helper.zsh $HELPER_DEST
/usr/bin/install -S -o root -g wheel -m 0644 $SRC_DIR/$LABEL.plist $PLIST_DEST

/bin/launchctl bootout system/$LABEL 2>/dev/null || true
# bootout can return before the job is fully removed, so try bootstrap more than once.
for attempt in 1 2 3 4 5; do
	/bin/launchctl bootstrap system $PLIST_DEST 2>/dev/null && break
	(( attempt < 5 )) || die "launchctl bootstrap failed. Check System Settings > General > Login Items & Extensions."
	sleep 1
done
/bin/launchctl enable system/$LABEL

# Check the helper as the normal user, because that is how Amphetamine connects to it.
reply=$(/usr/bin/sudo -u $SUDO_USER /bin/sh -c "/usr/bin/printf 'status\n' | /usr/bin/nc -U -w 5 '$SOCKET'") || reply=""
[[ $reply == "ok "[01] ]] || die "the helper did not reply correctly (reply: '${reply}')"
print "Helper OK. SleepDisabled is ${reply#ok }."

print "Installing powerProtect.scpt..."
if [[ ! -d $SCRIPTS_DIR ]]; then
	/usr/bin/install -d -o $SUDO_USER -g staff -m 0700 "$SCRIPTS_DIR"
fi
# Keep the first original script, so uninstall.zsh --restore-script can put it back.
if [[ -f $SCRIPT_DEST && ! -f $SCRIPT_DEST.orig ]]; then
	/bin/cp -p "$SCRIPT_DEST" "$SCRIPT_DEST.orig"
fi
/usr/bin/install -S -o root -g wheel -m 0644 "$work_dir/powerProtect.scpt" "$SCRIPT_DEST"

print "Done. Quit and open Amphetamine again, then start a session with Power Protect."
