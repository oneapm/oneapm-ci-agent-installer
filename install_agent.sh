#!/bin/bash
# OneAPM CI Agent install script.
set -e
logfile="oneapm-ci-agent-install.log"
gist_request=/tmp/agent-gist-request.tmp
gist_response=/tmp/agent-gist-response.tmp

if [ $(command -v curl) ]; then
    cl_cmd="curl -f"
else
    cl_cmd="wget --quiet"
fi

# Set up a named pipe for logging
npipe=/tmp/$$.tmp
mknod $npipe p

# Log all output to a log for error checking
tee <$npipe $logfile &
exec 1>&-
exec 1>$npipe 2>&1
trap "rm -f $npipe" EXIT


function on_error() {
    printf "\033[31m$ERROR_MESSAGE
It looks like you hit an issue when trying to install the Agent.

Troubleshooting and basic usage information for the Agent are available at:

    http://support.oneapm.com

If you're still having problems, please contact to support@oneapm.com
and we'll do our very best to help you
solve your problem.\n\033[0m\n"
}
trap on_error ERR

if [ -n "$CI_LICENSE_KEY" ]; then
    license_key=$CI_LICENSE_KEY
fi

if [ -n "$CI_INSTALL_ONLY" ]; then
    no_start=true
else
    no_start=false
fi

if [ ! $license_key ]; then
    printf "\033[31mLicense key not available in CI_LICENSE_KEY environment variable.\033[0m\n"
    exit 1;
fi

# OS/Distro Detection
# Try lsb_release, fallback with /etc/issue then uname command
KNOWN_DISTRIBUTION="(Debian|Ubuntu|RedHat|CentOS)"
DISTRIBUTION=$(lsb_release -d 2>/dev/null | grep -Eo $KNOWN_DISTRIBUTION  || grep -Eo $KNOWN_DISTRIBUTION /etc/issue 2>/dev/null || uname -s)

if [ $DISTRIBUTION = "Darwin" ]; then
    printf "\033[31mThis script does not support installing on the Mac..\033[0m\n"
    exit 1;

elif [ -f /etc/debian_version -o "$DISTRIBUTION" == "Debian" -o "$DISTRIBUTION" == "Ubuntu" ]; then
    OS="Debian"
elif [ -f /etc/redhat-release -o "$DISTRIBUTION" == "RedHat" -o "$DISTRIBUTION" == "CentOS" ]; then
    OS="RedHat"
fi

# Root user detection
if [ $(echo "$UID") = "0" ]; then
    sudo_cmd=''
else
    sudo_cmd='sudo'
fi

# Install the necessary package sources
if [ $OS = "RedHat" ]; then
    echo -e "\033[34m\n* Installing YUM sources for OneAPM\n\033[0m"

    UNAME_M=$(uname -m)
    if [ "$UNAME_M"  == "i686" -o "$UNAME_M"  == "i386" -o "$UNAME_M"  == "x86" ]; then
        ARCHI="i386"
    else
        ARCHI="x86_64"
    fi

    $sudo_cmd sh -c "echo -e '[oneapm-ci-agent]\nname = OneAPM, Inc.\nbaseurl = http://yum.oneapm.com/$ARCHI/\nenabled=1\ngpgcheck=0\npriority=1' > /etc/yum.repos.d/oneapm-ci-agent.repo"

    printf "\033[34m* Installing the OneAPM CI Agent package\n\033[0m\n"

    $sudo_cmd yum -y --disablerepo='*' --enablerepo='oneapm-ci-agent' install oneapm-ci-agent
elif [ $OS = "Debian" ]; then
    printf "\033[34m\n* Installing APT package sources for OneAPM\n\033[0m\n"
    $sudo_cmd sh -c "echo 'deb http://apt.oneapm.com/ stable main' > /etc/apt/sources.list.d/oneapm-ci-agent.list"
    $sudo_cmd apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 54B043BC

    printf "\033[34m\n* Installing the OneAPM CI Agent package\n\033[0m\n"
    ERROR_MESSAGE="ERROR
Failed to update the sources after adding the OneAPM repository.
This may be due to any of the configured APT sources failing -
see the logs above to determine the cause.
If the failing repository is OneAPM, please contact OneAPM support.
*****
"

    $sudo_cmd apt-get update -o Dir::Etc::sourcelist="sources.list.d/oneapm-ci-agent.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
    ERROR_MESSAGE="ERROR
Failed to install the OneAPM package, sometimes it may be
due to another APT source failing. See the logs above to
determine the cause.
If the cause is unclear, please contact OneAPM support.
*****
"
    $sudo_cmd apt-get install -y --force-yes oneapm-ci-agent
    ERROR_MESSAGE=""
else
    printf "\033[31mYour OS or distribution are not supported by this install script.
Please follow the instructions on the Agent setup page.\033[0m\n"
    exit;
fi

# Set the configuration
if [ -e /etc/oneapm-ci-agent/oneapm-ci-agent.conf ]; then
    printf "\033[34m\n* Keeping old oneapm-ci-agent.conf configuration file\n\033[0m\n"
else
    printf "\033[34m\n* Adding your license key to the Agent configuration: /etc/oneapm-ci-agent/oneapm-ci-agent.conf\n\033[0m\n"
    $sudo_cmd sh -c "sed 's/license_key:.*/license_key: $license_key/' /etc/oneapm-ci-agent/oneapm-ci-agent.conf.example > /etc/oneapm-ci-agent/oneapm-ci-agent.conf"
fi

restart_cmd="$sudo_cmd /etc/init.d/oneapm-ci-agent restart"
if command -v invoke-rc.d >/dev/null 2>&1; then
    restart_cmd="$sudo_cmd invoke-rc.d oneapm-ci-agent restart"
fi

if $no_start; then
    printf "\033[34m
* CI_INSTALL_ONLY environment variable set: the newly installed version of the agent
will not start by itself. You will have to do it manually using the following
command:

    $restart_cmd

\033[0m\n"
    exit
fi

printf "\033[34m* Starting the Agent...\n\033[0m\n"
eval $restart_cmd

# Wait for metrics to be submitted by the forwarder
printf "\033[32m
Your Agent has started up for the first time. We're currently verifying that
data is being submitted.\033[0m

Waiting for metrics..."

c=0
while [ "$c" -lt "30" ]; do
    sleep 1
    echo -n "."
    c=$(($c+1))
done

# Reuse the same counter
c=0

# The command to check the status of the forwarder might fail at first, this is expected
# so we remove the trap and we set +e
set +e
trap - ERR

$cl_cmd http://127.0.0.1:10010/status?threshold=0 > /dev/null 2>&1
success=$?
while [ "$success" -gt "0" ]; do
    sleep 1
    echo -n "."
    $cl_cmd http://127.0.0.1:10010/status?threshold=0 > /dev/null 2>&1
    success=$?
    c=$(($c+1))

    if [ "$c" -gt "15" -o "$success" -eq "0" ]; then
        # After 15 tries, we give up, we restore the trap and set -e
        # Also restore the trap on success
        set -e
        trap on_error ERR
    fi
done

# Metrics are submitted, echo some instructions and exit
printf "\033[32m

Your Agent is running and functioning properly. It will continue to run in the
background and submit metrics to OneAPM.

If you ever want to stop the Agent, run:

    sudo /etc/init.d/oneapm-ci-agent stop

And to run it again run:

    sudo /etc/init.d/oneapm-ci-agent start

\033[0m"
