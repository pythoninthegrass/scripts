#!/bin/bash

###
#
#            Name:  add-securetoken-to-logged-in-user.sh
#     Description:  Adds SecureToken to currently logged-in user, allowing that
#                   user to unlock FileVault in macOS High Sierra. Uses
#                   credentials from a GUI-created admin account $guiAdmin
#                   (retrieves from a manually-created System keychain entry),
#                   and prompts for current user's password.
#                   https://github.com/mpanighetti/add-securetoken-to-logged-in-user
#          Author:  Mario Panighetti
#         Created:  2017-10-04
#   Last Modified:  2017-10-04
#         Version:  1.0
#
###

###
#
#       Changed by: jjourney 10/6/2017
#          changes: Changed password prompt / check to match the code in 
#                   Elliot Jordan <elliot@elliotjordan.com> FileVault key upload script
#                   https://github.com/homebysix/jss-filevault-reissue
#                   Set the guiAdmin
#
###

###
#
#       Changed by: jjourney 2/2018
#          changes: Code re-arranged for better logic due to changes
#                   Updated secureToken code because it now(?) requires auth or interactive
#                   Adds user to filevault
#                   Run "sudo diskutil apfs updatePreboot /" at the end 
#
###

###
#
#       Changed by: jjourney 08/2018
#          changes: guiAdmin now gives you the current users that already have secureToken
#                   via diskutil apfs listUsers /
#                   Removed jamfhelper and applescript confusion
#                   Added all osascript functions, should be easier to read
#
###

###
#
#            Setup: Fill in relevant IT + FORGOT_PW_MESSAGE
#
###

# applescript
#
# template:
########### Title - "$2" ############
#                                   #
#     Text to display - "$1"        #
#                                   #
#      [Default response - "$5"]    #
#                                   #
#               (B1 "$3") (B2 "$4") # <- Button 2 default
#####################################

function simpleInput() {
osascript <<EOT
tell app "System Events" 
with timeout of 86400 seconds
text returned of (display dialog "$1" default answer "$5" buttons {"$3", "$4"} default button 2 with title "$2")
end timeout
end tell
EOT
}

function hiddenInput() {
osascript <<EOT
tell app "System Events" 
with timeout of 86400 seconds
text returned of (display dialog "$1" with hidden answer default answer "" buttons {"$3", "$4"} default button 2 with title "$2")
end timeout
end tell
EOT
}

function hiddenInputNoCancel() {
osascript <<EOT
tell app "System Events" 
with timeout of 86400 seconds
text returned of (display dialog "$1" with hidden answer default answer "" buttons {"$3"} default button 1 with title "$2")
end timeout
end tell
EOT
}

function OneButtonInfoBox() {
osascript <<EOT
tell app "System Events"
with timeout of 86400 seconds
button returned of (display dialog "$1" buttons {"$3"} default button 1 with title "$2")
end timeout
end tell
EOT
}

function TwoButtonInfoBox() {
osascript <<EOT
tell app "System Events"
with timeout of 86400 seconds
button returned of (display dialog "$1" buttons {"$3", "$4"} default button 2 with title "$2")
end timeout
end tell
EOT
}

function listChoice() {
osascript <<EOT
tell app "System Events"
with timeout of 86400 seconds
choose from list every paragraph of "$5" with title "$2" with prompt "$1" OK button name "$4" cancel button name "$3"
end timeout
end tell
EOT
}

########## variable-ing ##########

# replace with username of a GUI-created admin account
# (or any admin user with SecureToken access)
PROMPT_TITLE="Password Needed For FileVault"
FORGOT_PW_MESSAGE=""
IT=""

# leave these values as-is
loggedInUser=$(/usr/bin/python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
loggedInUserFull=$(id -F $loggedInUser)

########## function-ing ##########
cryptousers=$(diskutil apfs listusers / |awk -F+ '{print $2}' |cut -c 4-)
allusers=()
for GUID in $cryptousers
do
    usercheck=$(sudo dscl . -search /Users GeneratedUID $GUID \
    | awk 'NR == 1' \
    | cut -c -9)
    if [[ ! -z $usercheck ]]; then
        allusers+=$usercheck
    fi
done

for item in $allusers
do
    arrayChoice+=$"${item}\n"
done
arrayChoice=$(echo $arrayChoice |sed 's/..$//')

# Let's-a go!
guiAdmin="$(listChoice \
    "Please select a user with secure token that you know the password to:" \
    "Select SecureToken User" \
    "Cancel" \
    "OK" \
    $arrayChoice)"
if [[ "$guiAdmin" =~ "false" ]]; then
    echo "Cancelled by user"
    exit 0
fi
# Get the $guiAdmin password via a prompt.
echo "Prompting $guiAdminPass for their Mac password..."
guiAdminPass="$(hiddenInputNoCancel \
    "Please enter the password for $guiAdmin:" \
    "$PROMPT_TITLE" \
    "OK")"
    
# Thanks to James Barclay (@futureimperfect) for this password validation loop.
TRY=1
until /usr/bin/dscl /Search -authonly "$guiAdmin" "$guiAdminPass" &>/dev/null; do
    (( TRY++ ))
    echo "Prompting $guiAdmin for their Mac password (attempt $TRY)..."
    guiAdminPass="$(hiddenInput \
        "Sorry, that password was incorrect. Please try again:" \
        "$PROMPT_TITLE" \
        "Cancel" \
        "OK" )"
        echo "This is the password: $guiAdminPass"
        if [[ "$guiAdminPass" =~ "false" ]] || [[ -z "$guiAdminPass" ]]; then
            exit 0
        fi
    if (( TRY >= 5 )); then
        echo "[ERROR] Password prompt unsuccessful after 5 attempts. Displaying \"forgot password\" message..."
        OneButtonInfoBox \
            "$FORGOT_PW_MESSAGE" \
            "$PROMPT_TITLE" \
            "OK" &
        exit 1
    fi
done
echo "Successfully prompted for $guiAdmin password."


# add SecureToken to $loggedInUser account to allow FileVault access
securetoken_add () {
# This sample script assumes that the $guiAdmin account credentials have
# already been saved in the System keychain in an entry named "$guiAdmin".
# If you want to prompt for this information instead of pulling from the
# keychain, you can copy the below osascript to generate a new prompt, and
# pass the result to $guiAdminPass.

# Get the logged in user's password via a prompt.
echo "Prompting $loggedInUser for their Mac password..."
loggedInUserPass="$(hiddenInputNoCancel \
    "Please enter the password for $loggedInUserFull, the one used to log in to this Mac:" \
    "Password needed for Filevault" \
    "OK")"
# Thanks to James Barclay (@futureimperfect) for this password validation loop.
TRY=1
until /usr/bin/dscl /Search -authonly "$loggedInUser" "$loggedInUserPass" &>/dev/null; do
    (( TRY++ ))
    echo "Prompting $loggedInUser for their Mac password (attempt $TRY)..."
    loggedInUserPass="$(hiddenInput \
        "Sorry, that password was incorrect. Please try again:" \
        "$PROMPT_TITLE" \
        "Cancel" \
        "OK")"
        if [[ "$loggedInUserPass" =~ "false" ]] || [[ -z "$loggedInUserPass" ]]; then
            exit 0
        fi
    if (( TRY >= 5 )); then
        echo "[ERROR] Password prompt unsuccessful after 5 attempts. Displaying \"forgot password\" message..."
        OneButtonInfoBox \
            "$FORGOT_PW_MESSAGE" \
            "$PROMPT_TITLE" \
            "OK" &
        exit 1
    fi
done
echo "Successfully prompted for $loggedInUser password."

sudo sysadminctl \
    -adminUser "$guiAdmin" \
    -adminPassword "$guiAdminPass" \
    -secureTokenOn "$loggedInUser" \
    -password "$loggedInUserPass"
}


securetoken_double_check () {
    secureTokenCheck=$(sudo sysadminctl -adminUser $guiAdmin -adminPassword $guiAdminPass -secureTokenStatus "$loggedInUser" 2>&1)
    if [[ "$secureTokenCheck" =~ "DISABLED" ]]; then
        echo "❌ ERROR: Failed to add SecureToken to $loggedInUser for FileVault access."
        echo "Displaying \"failure\" message..."
        OneButtonInfoBox \
            "Failed to set SecureToken for $loggedInUser. Status is $secureTokenCheck. Please contact $IT." \
            "Failure" \
            "OK" &
        exit 1
    elif [[ "$secureTokenCheck" =~ "ENABLED" ]]; then
        securetoken_success
    else
        echo "???unknown error???"
        exit 3
    fi
}

securetoken_success () {
    echo "✅ Verified SecureToken is enabled for $loggedInUser."
    echo "Displaying \"success\" message..."
    OneButtonInfoBox \
        "SecureToken is now set to 'Enabled' for $loggedInUser." \
        "Success!" \
        "OK"
}

adduser_filevault () {
    echo "Checking Filevault status for $loggedInUser"
    filevault_list=$(sudo fdesetup list 2>&1)
    if [[ ! "$filevault_list" =~ "$loggedInUser" ]]; then
        echo "User not found, adding"
        # create the plist file:
        echo '<?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>Username</key>
            <string>'$guiAdmin'</string>
            <key>Password</key>
            <string>'$guiAdminPass'</string>
            <key>AdditionalUsers</key>
            <array>
                <dict>
                    <key>Username</key>
                    <string>'$loggedInUser'</string>
                    <key>Password</key>
                    <string>'$loggedInUserPass'</string>
                </dict>
            </array>
            </dict>
            </plist>' > /tmp/fvenable.plist 

        # now enable FileVault
        fdesetup enable -inputplist < /tmp/fvenable.plist
        rm -rf /tmp/fvenable.plist

        filevault_list=$(sudo fdesetup list 2>&1)
        if [[ ! "$filevault_list" =~ "$loggedInUser" ]]; then
            echo "Error adding user!"
            OneButtonInfoBox \
                "Failed to add $loggedInUserFull to filevault. Please try to add manually." \
                "Failed to add" \
                "OK" &
        elif [[ "$filevault_list" =~ "$loggedInUser" ]]; then
            echo "Success adding user!"
            OneButtonInfoBox \
                "Succeeded in adding $loggedInUserFull to filevault." \
                "Success!" \
                "OK" &
        fi
    elif [[ "$filevault_list" =~ "$loggedInUser" ]]; then
        echo "Success adding user!"
        OneButtonInfoBox \
            "$loggedInUserFull is a filevault enabled user." \
            "Success!" \
            "OK" &
    fi

    # run updatePreboot to show user
    sudo diskutil apfs updatePreboot /
}


########## main process ##########
# Have to have user/pass before you can check for secureToken :thinking:
secureTokenCheck=$(sudo sysadminctl -adminUser $guiAdmin -adminPassword $guiAdminPass -secureTokenStatus "$loggedInUser" 2>&1)

# add SecureToken to $loggedInUser if missing
if [[ "$secureTokenCheck" =~ "DISABLED" ]]; then
    securetoken_add
    securetoken_double_check
    adduser_filevault
elif [[ "$secureTokenCheck" =~ "ENABLED" ]]; then
    securetoken_success
    adduser_filevault
else
    echo "Error with sysadminctl"
    OneButtonInfoBox \
        "Failure to run. Please contact $IT" \
        "Failure" \
        "OK" &
fi

# Clear password variable.
unset loggedInUserPass
unset guiAdminPass

exit 0
