-- AMPHETAMINE CALLS enableDisablePowerProtect, installPowerProtectSudoOverride AND powerProtectSudoFileExists BY NAME
-- DO NOT RENAME THEM OR CHANGE THEIR PARAMETERS

-- PATHS ARE PROPERTIES SO THAT TESTS CAN REPLACE THEM WITH STUBS
property helperSocket : "/var/run/com.if.Amphetamine.PowerProtectHelper.sock"
property sudoersFile : "/etc/sudoers.d/amphetamine_PowerProtect"
property pmsetPath : "/usr/bin/pmset"
property sudoPath : "/usr/bin/sudo"

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
	set helperIsInstalled to helperInstalled()
	if helperIsInstalled then
		if helperRequest(inputString) is targetState then return "success"
		logMessage(inputString & ": helper did not set SleepDisabled to " & targetState)
	end if

	-- METHOD 2: SUDO WITH THE NOPASSWD RULE. -n MAKES SUDO FAIL IMMEDIATELY IF THE RULE DOES NOT APPLY
	-- WITHOUT -n, SUDO TRIES TO READ A PASSWORD WITH NO TERMINAL AND FAILS
	try
		do shell script quoted form of sudoPath & " -n " & quoted form of pmsetPath & " -a disablesleep " & targetState
	end try
	if sleepDisabledState() is targetState then return "success"

	-- RETURN SUCCESS IF NO METHOD IS INSTALLED, OTHERWISE AMPHETAMINE WILL NOTIFY THE USER OF THE FAILURE
	if not helperIsInstalled and not sudoersFileInstalled() then
		logMessage(inputString & ": no helper and no sudoers file, nothing changed")
		return "success"
	end if

	logMessage(inputString & ": failed, SleepDisabled is not " & targetState)
	return "fail"

end enableDisablePowerProtect

-- INSTALL THE CONFIGURATION FILE TO MAKE POWER PROTECT AUTHENTICATION-LESS
on installPowerProtectSudoOverride(inputString)

	set ruleText to sudoersRuleText(short user name of (system info))

	-- WRITE TO A TEMPORARY FILE, CHECK THE SYNTAX WITH VISUDO, THEN INSTALL IT AS root:wheel 0440
	-- A SUDOERS FILE WITH BAD SYNTAX CAN STOP SUDO FROM WORKING, SO NEVER INSTALL A FILE THAT VISUDO REJECTS
	-- THE LAST STEP CHECKS THAT /etc/sudoers INCLUDES THE NEW FILE. SOME MANAGED MACS DO NOT INCLUDE /etc/sudoers.d
	set installCommand to "set -e
tmp=$(/usr/bin/mktemp /tmp/amphetamine_PowerProtect.XXXXXX)
trap '/bin/rm -f \"$tmp\"' EXIT
/usr/bin/printf '%s' " & quoted form of ruleText & " > \"$tmp\"
/usr/sbin/visudo -c -q -f \"$tmp\"
/bin/mkdir -p /private/etc/sudoers.d
/usr/bin/install -S -o root -g wheel -m 0440 \"$tmp\" " & quoted form of sudoersFile & "
/usr/sbin/visudo -c 2>&1 | /usr/bin/grep -q amphetamine_PowerProtect"

	try
		do shell script installCommand with administrator privileges
		return "success"
	on error errorMessage
		logMessage("install sudoers file failed: " & errorMessage)
		return "fail"
	end try

end installPowerProtectSudoOverride

-- CHECK TO SEE IF POWER PROTECT CAN CHANGE SLEEP WITHOUT A PASSWORD
-- TRUE IF THE HELPER OR THE SUDOERS FILE IS INSTALLED
on powerProtectSudoFileExists()

	return helperInstalled() or sudoersFileInstalled()

end powerProtectSudoFileExists


-- RETURN "1" IF SLEEP IS DISABLED, "0" IF SLEEP IS ENABLED, "unknown" IF PMSET FAILS
-- PMSET DOES NOT SHOW SLEEPDISABLED WHEN IT IS 0
on sleepDisabledState()

	try
		set pmsetResult to do shell script quoted form of pmsetPath & " -g | /usr/bin/awk '/SleepDisabled/ { print $2; exit }'"
	on error
		return "unknown"
	end try

	if pmsetResult is "1" then return "1"
	return "0"

end sleepDisabledState

on helperInstalled()

	try
		do shell script "/bin/test -S " & quoted form of helperSocket
		return true
	on error
		return false
	end try

end helperInstalled

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
		do shell script "/usr/bin/logger -t AmphetaminePowerProtect -- " & quoted form of ("AmphetaminePowerProtect: script: " & messageText)
	end try

end logMessage
