-- AMPHETAMINE CALLS enableDisablePowerProtect, installPowerProtectSudoOverride AND powerProtectSudoFileExists BY NAME
-- DO NOT RENAME THEM OR CHANGE THEIR PARAMETERS

-- PATHS ARE PROPERTIES SO THAT TESTS CAN REPLACE THEM WITH STUBS
property helperSocket : "/var/run/com.if.Amphetamine.PowerProtectHelper.sock"
property helperProgram : "/Library/PrivilegedHelperTools/com.if.Amphetamine.PowerProtectHelper"
property sudoersFile : "/etc/sudoers.d/amphetamine_PowerProtect"
property pmsetPath : "/usr/bin/pmset"
property sudoPath : "/usr/bin/sudo"
property idPath : "/usr/bin/id"
property loggerPath : "/usr/bin/logger"

-- ENABLE/DISABLE POWER PROTECT
-- ENABLING POWER PROTECT MEANS DISABLING SLEEP WHEN THE MAC'S BUILT-IN DISPLAY IS CLOSED
on enableDisablePowerProtect(inputString)

	if inputString is "enable" then
		set targetState to "1"
	else if inputString is "disable" then
		set targetState to "0"
	else
		return "fail"
	end if

	-- NOTHING TO DO IF SLEEPDISABLED ALREADY HAS THE TARGET VALUE
	if sleepDisabledState() is targetState then return "success"

	-- METHOD 1: THE POWER PROTECT HELPER (A LAUNCHDAEMON). IT DOES NOT USE SUDO
	if helperSocketExists() then
		if helperRequest(inputString) is targetState then return "success"
		logMessage(inputString & ": helper did not set SleepDisabled to " & targetState)
	end if

	-- METHOD 2: SUDO WITH THE NOPASSWD RULE. -n MAKES SUDO FAIL IMMEDIATELY IF THE RULE DOES NOT APPLY
	-- WITHOUT -n, SUDO TRIES TO READ A PASSWORD WITH NO TERMINAL AND FAILS
	-- ONLY TRY IF THE RULE CAN EXIST: SUDO REPORTS EVERY ATTEMPT BY A USER WHO IS NOT IN SUDOERS
	if sudoersFileInstalled() or userIsAdmin() then
		try
			do shell script quoted form of sudoPath & " -n " & quoted form of pmsetPath & " -a disablesleep " & targetState
		end try
		if sleepDisabledState() is targetState then return "success"
	end if

	-- RETURN SUCCESS IF NO METHOD IS INSTALLED, OTHERWISE AMPHETAMINE WILL NOTIFY THE USER OF THE FAILURE
	if not powerProtectSudoFileExists() then
		logMessage(inputString & ": no helper and no sudoers file, nothing changed")
		return "success"
	end if

	logMessage(inputString & ": failed, SleepDisabled is not " & targetState)
	return "fail"

end enableDisablePowerProtect

-- INSTALL THE CONFIGURATION FILE TO MAKE POWER PROTECT AUTHENTICATION-LESS
on installPowerProtectSudoOverride(inputString)

	try
		set userName to short user name of (system info)
		do shell script sudoersInstallCommand(sudoersRuleText(userName), userName) with administrator privileges
		return "success"
	on error errorMessage
		logMessage("install sudoers file failed: " & errorMessage)
		return "fail"
	end try

end installPowerProtectSudoOverride

-- CHECK TO SEE IF POWER PROTECT CAN CHANGE SLEEP WITHOUT A PASSWORD
-- TRUE IF THE HELPER OR THE SUDOERS FILE IS INSTALLED
on powerProtectSudoFileExists()

	return helperSocketExists() or helperProgramExists() or sudoersFileInstalled()

end powerProtectSudoFileExists


-- SHELL COMMAND THAT INSTALLS THE SUDOERS FILE. IT RUNS AS ROOT
-- 1. WRITE THE RULE TO A TEMPORARY FILE AND CHECK ITS SYNTAX WITH VISUDO
-- 2. INSTALL IT AS root:wheel 0440, AND KEEP A COPY OF THE FILE IT REPLACES
-- 3. CHECK THAT THE WHOLE SUDOERS CONFIGURATION STILL PARSES AND THAT SUDO READS THE NEW FILE
--    (SOME MANAGED MACS DO NOT INCLUDE /etc/sudoers.d). visudo -f SKIPS THE OWNER AND MODE CHECKS THAT
--    PLAIN "visudo -c" DOES ON EVERY FILE: SUDO ACCEPTS ROOT-OWNED 0644 FILES THAT OTHER TOOLS INSTALL
-- 4. RUN THE REAL COMMAND AS THE USER WITH THE CURRENT VALUE, SO NOTHING CHANGES. A LATER SUDOERS
--    ENTRY CAN STILL ASK FOR A PASSWORD, BECAUSE THE LAST MATCHING ENTRY WINS
--    USE su, NOT "sudo -u": THE SUDOERS POLICY CAN DENY ROOT, BUT su FROM ROOT NEEDS NO POLICY
-- AWK MATCHES THE FIRST FIELD ONLY: OTHER pmset LINES LIST PROCESS NAMES, WHICH ANY USER CAN CHOOSE
-- IF A CHECK FAILS, PUT BACK THE OLD FILE. A SUDOERS FILE WITH BAD SYNTAX CAN STOP SUDO FROM WORKING
on sudoersInstallCommand(ruleText, userName)

	return "set -e
dest=" & quoted form of sudoersFile & "
user=" & quoted form of userName & "
work=$(/usr/bin/mktemp -d /tmp/amphetamine_PowerProtect.XXXXXX)
trap '/bin/rm -rf \"$work\"' EXIT
/usr/bin/printf '%s' " & quoted form of ruleText & " > \"$work/rule\"
/usr/sbin/visudo -c -q -f \"$work/rule\"
/bin/mkdir -p /private/etc/sudoers.d
if [ -f \"$dest\" ]; then /bin/cp -p \"$dest\" \"$work/previous\"; fi
/usr/bin/install -S -o root -g wheel -m 0440 \"$work/rule\" \"$dest\"
reason=\"sudo does not read $dest. /etc/sudoers may not include /etc/sudoers.d.\"
if parsed=$(/usr/sbin/visudo -c -f /private/etc/sudoers 2>&1); then
	if /usr/bin/printf '%s\\n' \"$parsed\" | /usr/bin/grep -qF \"${dest##*/}: parsed OK\"; then
		current=$(/usr/bin/pmset -g | /usr/bin/awk '$1 == \"SleepDisabled\" { print $2; exit }')
		[ \"$current\" = 1 ] || current=0
		if checked=$(/usr/bin/su \"$user\" -c \"/usr/bin/sudo -n /usr/bin/pmset -a disablesleep $current\" 2>&1 </dev/null); then exit 0; fi
		reason=\"the rule does not apply to $user ($checked). Another sudoers entry may ask for a password.\"
	fi
else
	reason=\"the sudoers configuration does not parse: $parsed\"
fi
if [ -f \"$work/previous\" ]; then /bin/mv -f \"$work/previous\" \"$dest\"; else /bin/rm -f \"$dest\"; fi
echo \"$reason Use the Power Protect helper.\" >&2
exit 1"

end sudoersInstallCommand

-- RETURN "1" IF SLEEP IS DISABLED, "0" IF SLEEP IS ENABLED, "unknown" IF PMSET FAILS
-- PMSET DOES NOT SHOW SLEEPDISABLED WHEN IT IS 0
on sleepDisabledState()

	try
		set pmsetResult to do shell script "settings=$(" & quoted form of pmsetPath & " -g) || exit 1; /usr/bin/printf '%s\\n' \"$settings\" | /usr/bin/awk '$1 == \"SleepDisabled\" { print $2; exit }'"
	on error
		return "unknown"
	end try

	if pmsetResult is "1" then return "1"
	return "0"

end sleepDisabledState

on helperSocketExists()

	try
		do shell script "/bin/test -S " & quoted form of helperSocket
		return true
	on error
		return false
	end try

end helperSocketExists

on helperProgramExists()

	try
		do shell script "/bin/test -e " & quoted form of helperProgram
		return true
	on error
		return false
	end try

end helperProgramExists

on userIsAdmin()

	try
		do shell script quoted form of idPath & " -Gn | /usr/bin/tr ' ' '\\n' | /usr/bin/grep -qx admin"
		return true
	on error
		return false
	end try

end userIsAdmin

-- SEND A REQUEST TO THE HELPER. RETURN THE SLEEPDISABLED VALUE THAT THE HELPER REPORTS, OR "" IF IT FAILS
on helperRequest(requestString)

	try
		set helperReply to do shell script "/usr/bin/printf '%s\\n' " & quoted form of requestString & " | /usr/bin/nc -U -w 5 " & quoted form of helperSocket
	on error errorMessage
		logMessage(requestString & ": helper connection failed: " & errorMessage)
		return ""
	end try

	if helperReply is "ok 1" then return "1"
	if helperReply is "ok 0" then return "0"
	logMessage(requestString & ": helper replied: " & helperReply)
	return ""

end helperRequest

on sudoersFileInstalled()

	try
		do shell script "/bin/test -f " & quoted form of sudoersFile
		return true
	on error
		return false
	end try

end sudoersFileInstalled

on sudoersRuleText(userName)

	set ruleText to "Cmnd_Alias PMSET_AMPHETAMINE = /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0" & linefeed & "%admin ALL=(root) NOPASSWD: PMSET_AMPHETAMINE" & linefeed

	-- ALSO ALLOW THE CURRENT USER, SO THAT STANDARD (NOT ADMIN) USERS CAN USE POWER PROTECT
	if isSafeUserName(userName) then set ruleText to ruleText & userName & " ALL=(root) NOPASSWD: PMSET_AMPHETAMINE" & linefeed

	return ruleText

end sudoersRuleText

-- MACOS SHORT NAMES ARE USUALLY SAFE IN SUDOERS, BUT ONLY USE NAMES THAT NEED NO ESCAPING
on isSafeUserName(userName)

	try
		do shell script "/usr/bin/printf '%s' " & quoted form of userName & " | /usr/bin/grep -Eqx '[A-Za-z_][A-Za-z0-9_.-]*'"
		return true
	on error
		return false
	end try

end isSafeUserName

-- WRITE TO THE UNIFIED LOG. TO READ IT: log show --last 1h --predicate 'eventMessage CONTAINS "AmphetaminePowerProtect"'
on logMessage(messageText)

	try
		do shell script quoted form of loggerPath & " -t AmphetaminePowerProtect -- " & quoted form of ("AmphetaminePowerProtect: script: " & messageText)
	end try

end logMessage
