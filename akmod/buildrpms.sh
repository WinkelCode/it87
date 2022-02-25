#!/bin/bash

addoverride() { # This function is used to set overrides for the spec file(s).
    newdef="%global $1 $2"
    wrapperoverrides+=("\n${newdef}")
    declare -gr "$1"="$2"
}

### Configuration Start
addoverride timestamp $(date -u "+%Y%m%d")

addoverride project_name it87
addoverride adddepmod true
addoverride addmodload true

dependencies=(spectool rpmbuild akmods)
specfiles=(akmod/it87.spec akmod/it87-kmod.spec)
projectsources=(compat.h it87.c LICENSE Makefile README ISSUES)
#rpmpattern=(akmod-${project_name} ${project_name} kmod-${project_name}) # Leftover from scrapped RPM auto-installer, telling the user to install via (rpm command) (install) (directory)* seems to work and is much less of a pain.

### Configuration End

checkdependencies() { # Here we check if the required programs are installed.
    printf '%s' "Checking Required Dependencies: ${txtitalic}${dependencies[*]}${txtreset}... "
    for item in "${dependencies[@]}"; do
        if ! command -v "$item" &>/dev/null; then missingdeps+=("$item"); fi
    done
    if [ $missingdeps ]; then
        printf '\n%s\n' "$(txterror): Missing Dependen$(plural missingdeps ies y): ${missingdeps[*]}"
        return 1
    else printf "$(txtok)\n"
    fi
}

checkspecfiles() { # Here we check if we have the required spec files.
    printf '%s' "Checking Required Spec Files: ${txtitalic}${specfiles[*]}${txtreset}... "
    for item in "${specfiles[@]}"; do
        if [ ! -f "$item" ] && [ ! -d "$item" ]; then missingspecfiles+=("$item"); fi
    done
    if [ $missingspecfiles ]; then
        printf '\n%s\n' "$(txterror): Missing Spec File$(plural missingspecfiles s): ${missingspecfiles[*]}"
        pwdinfo
        return 1
    else printf "$(txtok)\n"
    fi
}

checkprojectsources() { # Here we check if we have the required source files.
    printf '%s' "Checking Required Module Sources: ${txtitalic}${projectsources[*]}${txtreset}... "
    for item in "${projectsources[@]}"; do
        if [ ! -f "$item" ] && [ ! -d "$item" ]; then missingsources+=("$item"); fi
    done
    if [ $missingsources ]; then
        printf '\n%s\n' "$(txterror): Missing Source$(plural missingsources s): ${missingsources[*]}"
        pwdinfo
        return 1
    else printf "$(txtok)\n"
    fi
}

getrepoinfo() { # Here we extract some information about the repository (if our PWD is one and we have git installed) using git and some bash parameter expansion magic.
    printf '%s\n' "$(txtstart): Getting repository information..."
    if ! git --version &>/dev/null; then
        printf '%s\n' "$(txtwarn): git is not installed, repository owner and commit detection unavailable."
        return 1
    elif ! git status &>/dev/null; then
        printf '%s\n' "$(txtwarn): Current working directory is not a git repository, repository owner and commit detection unavailable."
        return 1
    fi
    if ! git config --get remote.origin.url &>/dev/null || ! git rev-parse HEAD &>/dev/null; then
        printf '%s\n' "$(txtwarn): Unexpected error during repository owner or commit detection, automatic repository information unavilable."
        return 1
    fi

    repo_info=$(git config --get remote.origin.url)
    repo_info=${repo_info#*://*/}
    printf '%s\n' "Detected Repository Owner: ${repo_info%/*}"
    addoverride repo_owner ${repo_info%/*}

    repo_commit=$(git rev-parse HEAD)
    printf '%s\n' "Detected Repository Commit: ${repo_commit}"
    addoverride repo_commit $repo_commit

    printf '%s\n' "$(txtdone): Getting repository information."
}

tmpdircontrol() { # This function handles all things related to our tempdir (with random suffix).
    case $1 in
        create)
            printf '%s' "Creating Temporary Build Directory: "
            #randomtmpdir="/tmp/${project_name}-buildtree.${timestamp}_$(cat /dev/urandom | tr -cd a-zA-Z0-9 | head -c 7)"
            randomtmpdir=$(mktemp -p /tmp -d ${project_name}-buildtree.${timestamp}_XXXXXXX) || return 1 # The akmods build script also uses mktemp, so we should have it available.
            printf '%s' "${txtitalic}${randomtmpdir}${txtreset}... "
            printf "$(txtdone)\n"
            ;;
        delete)
            if [ $keeptmpdir ]; then
                printf '\n%s\n' "$(txtwarn): Not deleting \"${txtitalic}${randomtmpdir}${txtreset}\" as per \"keeptmpdir\"."
                printf '%s\n\n' "$(txtnote): You can run \"${txtitalic}buildrpms.sh clean${txtreset}\" to delete build artifacts and preserved temporary build directories."
            else
                printf '%s' "Deleting Temporary Build Directory: ${txtitalic}${randomtmpdir}${txtreset}... "
                rm -rf "$randomtmpdir" || return 1
                printf "$(txtdone)\n"
            fi
            ;;
    esac
}

fakesetuptree() { # The original rpmdev-setuptree can't be manipulated using --define or similar, so we just replicate the folder creation here.
    printf '%s' "Creating RPMBuild Folder Structure... "
    mkdir -p ${randomtmpdir}/{BUILD,RPMS,SOURCES,SPECS,SRPMS} || return 1
    printf "$(txtdone)\n"
}

createsourcetarball() { # Here we create the tarball which will serve as our source for the RPM build process.
    printf '%s\n' "$(txtstart): Creating Source Tarball..."
    mkdir -p ${randomtmpdir}/SOURCES/${project_name}
    (shopt -s dotglob # So we can also see dotfiles if we need them.
        for file in *; do
            if [[ " ${projectsources[*]} " =~ " $file " ]]; then
                cp -a "$file" ${randomtmpdir}/SOURCES/${project_name}/ || exit 1
            fi
        done
    ) || return 1
    (cd ${randomtmpdir}/SOURCES # The tar command can be really annoying in regards to the relation of the PWD to the folder to be archived, so we cd a subshell to it.
        tar -czvf ${project_name}.tar.gz ./${project_name}/ || exit 1 # Using "./" in case project_name was not defined for some reason, else we would archive the entire root!
    ) || return 1
    rm -rf ${randomtmpdir}/SOURCES/${project_name}/
    printf '%s\n' "$(txtdone): Creating Source Tarball."
}

setupspecfiles() {
    printf '%s' "Configuring Spec Files: ${txtitalic}${specfiles[*]}${txtreset}... "
    for specfile in "${specfiles[@]}"; do
        cat "$specfile" | sed s/"#__WRAPPEROVERRIDEMARKER__"/"${wrapperoverrides[*]//\//\\/}"/ >"${randomtmpdir}/SPECS/${specfile##*/}" || return 1
    done
    printf "$(txtdone)\n"
}

buildrpms() { # We build the rpms and redirect the output to a file so it doesn't spam the command line, a non-fatal error would likely just dissapear in the wall of text anyway.
    printf '%s\n' "$(txtstart): Building RPMs..."
    for specfile in "${specfiles[@]}"; do
        printf '%s' "Building ${txtitalic}$specfile${txtreset}... "
        if rpmbuild -bb --nodebuginfo --define="_topdir ${randomtmpdir}" ${randomtmpdir}/SPECS/${specfile##*/} &>rpmbuild.${specfile##*/}.log; then
            printf '%s - %s\n' "$(txtdone)" "$(buildloginfo)"
        else
            printf '%s - %s\n' "$(txterror)" "$(buildloginfo)"
            if [ ! $keeptmpdir ]; then
                printf '%s\n' "$(txtnote): Run the script with \"${txtitalic}keeptmpdir${txtreset}\" to preserve the temporary build directory for inspection."
            fi
            return 1
        fi
    done
    printf '%s\n' "$(txtdone): Building RPMs."
}

getbuiltrpms() { # We grab the RPMS and put them in a (single) folder.
    printf '%s' "Getting Built RPMs... "
    rm -rf ./RPMS.${project_name}/ || return 1
    mkdir -p ./RPMS.${project_name} || return 1
    for rpm in ${randomtmpdir}/RPMS/*/*; do
        cp -a $rpm ./RPMS.${project_name}/ || return 1
    done
    printf "$(txtdone)\n"
}

doaction() {
    case $1 in
        clean)
            printf '%s' "Cleaning ${txtitalic}${project_name}${txtreset}'s artifacts and temporary build directories... "
            rm -rf ./RPMS.${project_name}/ || { printf '%s\n' "$(txterror): Error Removing Built RPMS"; exit 1; }
            rm -rf ./rpmbuild.*.log || { printf '%s\n' "$(txterror): Error Removing Build Log"; exit 1; }
            rm -rf /tmp/${project_name}-buildtree.* || { printf '%s\n' "$(txterror): Error Removing Old Temporary Build Directory"; exit 1; }
            printf "$(txtdone)\n"
        ;;
        build)
            printf '%s\n' "${txtbold}$(txtstart): ${txtbold}Building ${txtitalic}${project_name}${txtreset}..."
            checkdependencies || exit 1 # Error messaging handled by function
            checkspecfiles || exit 1 # Error messaging handled by function
            checkprojectsources || exit 1 # Error messaging handled by function
            printf '\n'
            getrepoinfo || { addoverride repo_owner custom; addoverride repo_commit unknown; addoverride version_override 0^${timestamp}.unknown; printf '%s\n' "$(txtskipped): Getting repository information."; } # Messaging partially handled by function.
            printf '\n'
            tmpdircontrol create || { printf '%s\n' "$(txterror): Error Creating Temporary Directory"; exit 1; }
            fakesetuptree || { printf '%s\n' "$(txterror): Error Creating Build Tree"; exit 1; }
            printf '\n'
            createsourcetarball || { printf '%s\n' "$(txterror): Error Creating Source Tarball"; tmpdircontrol delete; exit 1; }
            printf '\n'
            setupspecfiles || { printf '%s\n' "$(txterror): Error During Setup of Spec Files"; tmpdircontrol delete; exit 1; }
            printf '\n'
            buildrpms || { tmpdircontrol delete; exit 1; } # Error messaging handled by function
            printf '\n'
            getbuiltrpms || { printf '%s\n' "$(txterror): Error Getting Built RPMS"; tmpdircontrol delete; exit 1; }
            tmpdircontrol delete || { printf '%s\n' "$(txterror): Error Deleting Temporary Directory"; exit 1; }
            echo "DEBUG: ${wrapperoverrides[*]}" # A sanity check to see if the overrides look good.
            printf '%s\n' "${txtbold}$(txtdone)${txtbold}: Building ${txtitalic}${project_name}${txtreset}."
            ${acpiworkaround:+printf '%s\n' "${txtbold}$(txtwarn)${txtbold}: RPM built with instructions to add modprobe.d \"ignore_resource_conflict\" entry."} # WORKAROUND FOR ACPI RESOURCE CONFLICT
            printf '%s\n' "$(txtnote): To install the built RPMS, run \"${txtitalic}rpm -i ./RPMS.${project_name}/*${txtreset}\" (Normal RPM) or \"${txtitalic}rpm-ostree install ./RPMS.${project_name}/*${txtreset}\" (Fedora Silverblue and Co.)"
        ;;
    esac
}

loadcolors() { # The color descriptions may not be accurate depending on the user's setup.
    txtred=$(tput setaf 1); txtyellow=$(tput setaf 3); txtgreen=$(tput setaf 2); txtbold=$(tput bold); txtul=$(tput smul); txtitalic=$(tput sitm); txtreset=$(tput sgr0) # Bold, underline, and italics might not work, should still be fine though.
    colora=$(tput setaf 5); colorb=$(tput setaf 6) # It seems these are particularly likely to vary.
    txtok() { printf "${txtgreen}OK${txtreset}"; }
    txtwarn() { printf "${txtyellow}WARNING${txtreset}"; }    
    txterror() { printf "${txtred}ERROR${txtreset}"; }
    txtstart() { printf "${colora}START${txtreset}"; }
    txtdone() { printf "${txtgreen}DONE${txtreset}"; }
    txtskipped() { printf "${txtyellow}SKIPPED${txtreset}"; }
    txtnote() { printf "${colorb}NOTE${txtreset}"; }
}

pwdinfo() {
    printf '%s\n      %s\n' "$(txtnote): Ensure your current working directory is where the project sources are located." "You may have to run \"./akmod/buildrpms.sh\", not \"./buildrpms.sh\"."
}

buildloginfo() {
    printf '%s' "You can find the build log in \"${txtitalic}rpmbuild.${specfile##*/}.log${txtreset}\"."
}

plural() { # Usage: plural (array) (plural) (singular), to be used with command substitution.
        eval test "\${${1}[1]}" && printf '%s' "$2" || printf '%s' "$3"
}

# MAIN

loadcolors

until [ ! $1 ]; do
    case $1 in
        clean)
            todo+=("clean")
            shift
        ;;
        build)
            todo+=("build")
            shift
        ;;
        *keeptmpdir)
            keeptmpdir=true
            shift
        ;;
        *acpiworkaround) # WORKAROUND FOR ACPI RESOURCE CONFLICT
            addoverride acpiworkaround true
            shift
        ;;
        *help|*usage)
            forcehelp=true
            break
        ;;
        *)
            printf '%s\n' "$(txterror): Unknown Argument \"${1}\""
            exit 1
        ;;
    esac
done

if [ ! $todo ] || [ $forcehelp ]; then
    printf '%s\n' "USAGE: buildrpms.sh (build, clean) [keeptmpdir, acpiworkaround]"
    printf '%s\n' "EXAMPLE: ./akmod/buildrpms.sh clean"
    printf '%s\n' "EXAMPLE: ./akmod/buildrpms.sh build keeptmpdir"
    pwdinfo
    if [ ! $forcehelp ]; then
        printf '%s\n' "$(txterror): No Instructions Supplied"; exit 1
    else
        exit 0
    fi
fi

for action in ${todo[@]}; do
    doaction $action
done
exit
