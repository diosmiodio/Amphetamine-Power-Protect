# Power Protect helper (no sudo)

The helper lets Power Protect change `SleepDisabled` without `sudo`. Use it when the
sudoers rule does not work on your Mac. Typical symptoms:

- Amphetamine shows "Power Protect Failure" again and again (issue #6).
- You use a standard (not admin) account (issue #3).
- A management tool removes `/etc/sudoers.d` or replaces `/etc/sudoers`. Some company
  Macs delete `/etc/sudoers.d` each time their configuration tool runs.

## How it works

The helper is a LaunchDaemon. launchd owns a UNIX socket at
`/var/run/com.if.Amphetamine.PowerProtectHelper.sock`. For each connection, launchd starts
`/Library/PrivilegedHelperTools/com.if.Amphetamine.PowerProtectHelper` as root, with the
connection on stdin and stdout. macOS uses the same method for `sshd`.

The helper reads one line and accepts only these requests:

| Request   | Action                          | Reply                 |
|-----------|---------------------------------|-----------------------|
| `enable`  | `pmset -a disablesleep 1`       | `ok 1` or `error ...` |
| `disable` | `pmset -a disablesleep 0`       | `ok 0` or `error ...` |
| `status`  | none                            | `ok 0` or `ok 1`      |

After each change, the helper reads `pmset -g` and replies with the real value. It rejects
all other input and runs no other command.

`powerProtect.scpt` tries the helper first. If the helper is not installed or fails, the
script tries `sudo -n /usr/bin/pmset ...`. The `-n` flag stops `sudo` from asking for a
password that it cannot read.

## Install

Install the normal Power Protect package first, or make sure that Amphetamine is
installed. Then, from the repository folder:

```sh
sudo zsh Source/Helper/install.zsh
```

The script installs `powerProtect.scpt` for the user who is logged in at the screen. A
standard account cannot use `sudo`. To install for a standard account, log in as that
user, open Terminal, and run the command with `su`:

```sh
su ADMIN_NAME -c "sudo zsh $PWD/Source/Helper/install.zsh --user $USER"
```

The script:

1. Compiles `Source/powerProtect.applescript`. If compilation fails, the script stops
   before it changes anything.
2. Installs the helper and the LaunchDaemon, then loads it.
3. Sends `status` to the helper as your user and checks the reply.
4. Saves the current `powerProtect.scpt` as `powerProtect.scpt.orig` (first install
   only), then installs the new script. It does these steps as the target user, not as
   root.

Quit and open Amphetamine again. Then start a new Closed-Display Mode session.

macOS can show a "Background Items Added" notification. If you turn the item off in
System Settings > General > Login Items & Extensions, the helper does not start.

## Check

```sh
printf 'status\n' | nc -U -w 5 /var/run/com.if.Amphetamine.PowerProtectHelper.sock
log show --last 1h --predicate 'eventMessage CONTAINS "AmphetaminePowerProtect"'
```

## Uninstall

```sh
sudo zsh Source/Helper/uninstall.zsh                    # keep the new script
sudo zsh Source/Helper/uninstall.zsh --restore-script   # also restore the old script
                                                        # (add --user NAME for another account)
```

Uninstall unloads the helper, removes its files, and runs `pmset -a disablesleep 0`, so
normal sleep is on again.

## Security

- Any local user can connect to the socket and turn sleep on or off. This is the same
  access as a sudoers rule for all users. The helper cannot do anything else.
- The helper reads at most 64 bytes, waits at most 5 seconds, and exits. It does not read
  files or environment values that a user controls. launchd starts it with a fixed
  environment.
- If you only need sleep control for administrators and the sudoers rule works on your
  Mac, you do not need the helper.

## Tests

```sh
zsh Tests/power-protect-tests.zsh
```

The tests replace `pmset`, `sudo`, and `logger` with stubs. They do not need root and do
not change your sleep settings.
