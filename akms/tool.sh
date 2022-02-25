#!/bin/ash
set -e # We have OR (||) operators where we might fail "expectedly", which seem to take precedence over set -e.

project_name=it87
adddepmod=true
addmodload=true
#acpiworkaround=true
idfile="${project_name}.c"
srcdir="/usr/src/${project_name}"
offlinebuildinfo="RECOMMENDED: Install \"alpine-sdk\" and \"linux-lts-dev\" to be able to build the module offline."

add() {
    echo "Installing \"$project_name\" module..."

    if [ -d "${srcdir}" ]; then
        echo "Error: Already installed, run \"tool.sh del\" or remove \"${srcdir}\"."
        exit 1
    fi
    if [ ! -f "${idfile}" ]; then
        echo "Error: PWD must be the project sources. (You probably have to run ./akms/tool.sh)"
        exit 1
    fi

    mkdir -p "${srcdir}"
    cp -r "./" "${srcdir}/"
    cp "akms/AKMBUILD" "${srcdir}/"
    if [ $adddepmod ]; then
        printf '%s' "override ${project_name} * kernel/extra/akms" >"${srcdir}/depmod_${project_name}.conf"
        install -D -m 0644 "${srcdir}/depmod_${project_name}.conf" "/etc/depmod.d/akms_${project_name}.conf"
    fi
    if [ $addmodload ]; then
        printf '%s' "${project_name}" >"${srcdir}/modload_${project_name}.conf"
        install -D -m 0644 "${srcdir}/modload_${project_name}.conf" "/etc/modules-load.d/akms_${project_name}.conf"
    fi       
    if [ $acpiworkaround ]; then
        printf '%s' "options ${project_name} ignore_resource_conflict" >"${srcdir}/modprobe_${project_name}.conf"
        install -D -m 0644 "${srcdir}/modprobe_${project_name}.conf" "/etc/modprobe.d/akms_${project_name}.conf"
    fi

    ${adddepmod:+echo "Added depmod.d entry."}
    ${addmodload:+echo "Added modules-load.d entry."}
    ${acpiworkaround:+echo "Added modprobe.d \"ignore_resource_conflict\" entry."}

    ${recommendapk:+echo "$offlinebuildinfo"}
    akms install ${project_name} && echo "$project_name Installation complete." || { printf '\n%s\n\n' "ERROR: $project_name Installation Failed, Cleaning Up..."; del; exit 1; }
    ${recommendapk:+echo "$offlinebuildinfo"}
}

del() {
    echo "Removing \"$project_name\" module..."

    if [ -f "${srcdir}/depmod_${project_name}.conf" ]; then
        rm -rf "/etc/depmod.d/akms_${project_name}.conf"
        depmodinfo=1
    fi
    if [ -f "${srcdir}/modload_${project_name}.conf" ]; then
        rm -rf "/etc/modules-load.d/akms_${project_name}.conf"
        modloadinfo=1
    fi
    if [ -f "${srcdir}/modprobe_${project_name}.conf" ]; then
        rm -rf "/etc/modprobe.d/akms_${project_name}.conf"
        acpiworkaroundinfo=1
    fi
    rm -rf "${srcdir}"

    ${depmodinfo:+echo "Deleted depmod.d entry."}
    ${modloadinfo:+echo "Deleted modules-load.d entry."}
    ${acpiworkaroundinfo:+echo "Deleted modprobe.d \"ignore_resource_conflict\" entry."}

    akms uninstall ${project_name} && echo "$project_name Uninstallation complete." || echo "$project_name Leftover Files Deleted."
}

########
# Main #
########
echo "$project_name akms (Alpine Kernel Module System) installation tool."

if ! command -v akms &>/dev/null; then
    echo "ERROR: akms not found, try \"apk add akms\""
fi

if ! apk info -e alpine-sdk &>/dev/null || ! apk info -e linux-lts-dev &>/dev/null; then
    recommendapk=true
fi

case $2 in
    *acpiworkaround)
        acpiworkaround=true
    ;;
esac

case $1 in
    add|install)
        add
    ;;
    del|delete|remove|uninstall)
        del
    ;;
    *)
        echo "USAGE: tool.sh (add/del) [acpiworkaround]"
        echo "EXAMPLE: ./akms/tool.sh del"
        echo "EXAMPLE: ./akms/tool.sh add acpiworkaround"
        echo "$offlinebuildinfo"
    ;;
esac