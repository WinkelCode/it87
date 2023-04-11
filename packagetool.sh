#!/usr/bin/env bash
set -e
software_name='it87' # Hardcoded default

# -----------------
# Utility functions
# -----------------
print_usage() {
	usage="$(cat <<EOF
Usage: $0 [options]
Options:
	(Required) --container_runtime=CONTAINER_RUNTIME
		Container runtime to use. Valid values are 'podman' and 'docker'.
	(Required) --package_system=PACKAGE_SYSTEM
		Package system to target. Valid values are 'apk', 'deb', and 'rpm'.
	(Optional) --software_name=SOFTWARE_NAME
		Name of the software to package. Defaults to the name of the current directory ('${PWD##*/}').
	(Optional) --no_pkg_tests
		Do not test installation and dynamic build of the package.
	(Optional) --inspect_container
		Inspect the container with a shell after building (and testing) the package.
		Note: 'exit'-ing the container with a non-zero exit code will stop the script as well.
	(Optional) --print_repo_info
		Print information about the current repository and exit.
	(Optional) --keep_temp_dir
		Do not delete the temporary directory after the script exits.
	(Optional) --print_temp_dir=PRINT_TEMP_DIR
		Print the path to the temporary directory and exit. Valid values are 'none', 'normal', and 'verbose'.
		'none' is the default and prints nothing.
		'normal' uses 'tree' or 'ls -R' to print the contents of the temporary directory.
		'verbose' uses 'ls -laR' to print the contents of the temporary directory.
		--print_temp_dir is equivalent to --print_temp_dir=normal.
	(Optional) --help, -h
		Print this help message and exit.
EOF
)"
	printf '%s\n' "$usage"
}

parse_arguments() {
	while [ "$1" ]; do
		case "$1" in
			--container_runtime=*)
				container_runtime="${1#*=}"
				valid_container_runtimes='(podman|docker)'
				if [[ ! "$container_runtime" =~ ^${valid_container_runtimes}$ ]]; then
					printf '%s\n' "Error: Invalid runtime '$container_runtime', must be one of '$valid_container_runtimes'"
					exit 1
				fi
				shift
				;;
			--package_system=*)
				package_system="${1#*=}"
				valid_package_systems='(apk|deb|rpm)'
				if [[ ! "$package_system" =~ ^${valid_package_systems}$ ]]; then
					printf '%s\n' "Error: Invalid package system '$package_system', must be one of '$valid_package_systems'"
					exit 1
				fi
				shift
				;;
			--software_name=*)
				software_name="${1#*=}"
				shift
				;;
			--no_pkg_tests)
				no_pkg_tests='true'
				shift
				;;
			--inspect_container)
				inspect_container='true'
				shift
				;;
			--print_repo_info)
				print_repo_info
				exit 0
				;;
			--keep_temp_dir)
				keep_temp_dir='true'
				shift
				;;
			--print_temp_dir=*)
				print_temp_dir="${1#*=}"
				valid_print_temp_dir='(none|normal|verbose)'
				if [[ ! "$print_temp_dir" =~ ^${valid_print_temp_dir}$ ]]; then
					printf '%s\n' "Error: Invalid print_temp_dir '$print_temp_dir', must be one of '$valid_print_temp_dir'"
					exit 1
				fi
				shift
				;;
			--print_temp_dir)
				print_temp_dir='normal'
				shift
				;;
			--help|-h)
				print_usage
				exit 0
				;;
			*) # Unknown option
				print_usage
				printf '%s\n' "Error: Unknown argument '$1'"
				exit 1
				;;
		esac
	done

	required_options=(
	"container_runtime"
	"package_system"
	)	

	for option in "${required_options[@]}"; do
		if [ -z "${!option}" ]; then
			print_usage
			printf '%s\n' "Error: Required option '${option^^}' is unset"
			exit 1
		fi
	done
}

gather_repo_info() {
	[ ! "$software_name" ] && software_name="${PWD##*/}" # Use directory name as software name if not specified
	working_tree_changed="$(git diff-index --quiet HEAD -- &>/dev/null; printf '%s' "$?")" # Whether the working tree has been modified

	if [ "$working_tree_changed" = '0' ]; then # If the working tree is clean, use the commit date. $working_tree_changed is also >0 if we're not a git repository.
		current_commit="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')" # Commit hash of the current commit
		working_tree_timestamp="$(git show -s --format=%cd --date=iso-strict "${current_commit}" 2>/dev/null || printf 'unknown')"
	else # Otherwise, use the current date
		current_commit='unknown'
		working_tree_timestamp="$(date --iso-8601=seconds)"
	fi

	origin_url="$(git remote get-url origin 2>/dev/null || printf 'unknown')" # URL of the origin remote
	[ "$origin_url" != 'unknown' ] && origin_name="${origin_url##*/}" # Name of the origin remote
	[ "$origin_url" != 'unknown' ] && origin_owner="${origin_url%/*}"; origin_owner="${origin_owner##*/}" # Owner of the origin remote
}

print_repo_info() {
	printf '%s\n' "Determined the following information about the current repository:"
	printf '\t%s:%s\n' \
		"software_name" "$software_name" \
		"current_commit" "$current_commit" \
		"working_tree_changed" "$working_tree_changed" \
		"working_tree_timestamp" "$working_tree_timestamp" \
		"origin_url" "$origin_url" \
		"origin_name" "$origin_name" \
		"origin_owner" "$origin_owner"
}

startup() {
	printf '%s' "Deleting old .release/ folder and creating temporary directory..."
	rm -rf "./.release/" || { printf '\n%s\n' "Error: Failed to delete previous release directory."; exit 1; }
	temp_dir="$(mktemp -t --directory ${software_name}_tmp.XXXXXXXXXX)" || { printf '\n%s\n' "Error: Failed to create temporary directory."; exit 1; }
	printf '%s\n' " OK."
}

cleanup() {
	if [ "$print_temp_dir" == 'normal' ]; then
		printf '%s\n' "Contents of temporary directory at '${temp_dir}' ('normal' verbosity):"
		tree "${temp_dir}" 2>/dev/null || ls -R "${temp_dir}"
	elif [ "$print_temp_dir" == 'verbose' ]; then
		printf '%s\n' "Contents of temporary directory at '${temp_dir}' ('verbose' verbosity):"
		ls -laR "${temp_dir}"
	fi
	if [ "$keep_temp_dir" == 'true' ]; then
		printf '%s\n' "Not removing '${temp_dir}' as per '--keep_temp_dir'."
	else 
		printf '%s' "Deleting temporary directory at '${temp_dir}'..."
		rm -rf "${temp_dir}" || { printf '\n%s\n' "Error: Failed to delete temporary directory."; exit 1; }
		printf '%s\n' " OK."
	fi
}


# -------------------
# Packaging functions
# -------------------
build_apk() {
	containerfile=$(cat <<'EOF'
FROM docker.io/library/alpine:latest

# Install the build dependencies
RUN apk add \
	abuild \
	build-base \
	linux-lts-dev \
	akms

# Save kernel dev name
RUN printf '%s\n' "$(ls /lib/modules/ | head -n 1)" >/kernel_dev_name.txt
EOF
)
	printf '%s\n' "${containerfile}" | ${container_runtime} build -t ${software_name}-apk-builder -f - # Build the container

	mkdir -p "${temp_dir}/"{APKBUILD/src,packages} # Create the shared directories
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/APKBUILD,target=/APKBUILD"
		"--mount type=bind,source=${temp_dir}/packages,target=/root/packages"
		"--mount type=bind,source=${temp_dir}/run_command.sh,target=/run_command.sh"
	)

	build_overrides=(
		"_source_modname=\"${software_name}\""
		"_repo_name=\"${origin_name}\""
		"_repo_owner=\"${origin_owner}\""
		"_repo_commit=\"${current_commit}\""
		"_package_timestamp=\"$(date --date="${working_tree_timestamp}" +%Y%m%d)\""
		"source=\"${origin_name}.tar.gz\""
	)
	printf '%s\n' "${build_overrides[@]}" >"${temp_dir}/APKBUILD/APKBUILD" # Write overrides
	cat "./alpine/APKBUILD" >>"${temp_dir}/APKBUILD/APKBUILD" # Append the APKBUILD

	tar --exclude="../${PWD##*/}/.git" -czvf "${temp_dir}/APKBUILD/${origin_name}.tar.gz" "../${PWD##*/}" # Create the source tarball, for compatibility with GitHub tarballs we put the repo in a subdirectory of the tarball

	run_command=(
		"("
		"cd /APKBUILD"
		"&& abuild-keygen -a -n" # We can't not sign the package, so we generate a one time use key, the user has to install it with `--allow-untrusted`
		"&& abuild -F checksum"
		"&& abuild -F srcpkg"
		"&& abuild -F"
		")"
		"&& printf '%s\n' '-> Package building complete.'"
	)
	if [ "$no_pkg_tests" != 'true' ]; then # Testing installing the package and akmod dynamic builds
		run_command+=(
			"&& apk add --allow-untrusted /root/packages/*/*.apk"
			"&& akms --kernel \$(cat /kernel_dev_name.txt) build ${software_name}-oot"
			"&& akms --kernel \$(cat /kernel_dev_name.txt) install ${software_name}-oot"
			"&& modinfo /lib/modules/\$(cat /kernel_dev_name.txt)/kernel/extra/akms/${software_name}.ko*" # * in case compression is used
			"&& printf '%s\n' '-> Checking if module is removed on package uninstall.'"
			"&& apk del ${software_name}-oot*"
			"&& { ! modinfo --filename /lib/modules/\$(cat /kernel_dev_name.txt)/kernel/extra/akms/${software_name}.ko* &>/dev/null || { printf '%s\n' '-> Error: Module was not removed on package uninstall.'; return 1; }; }"
			"&& printf '%s\n' '-> Package installation and akms dynamic build tests successful.'"
		)
	fi
	if [ "$inspect_container" == 'true' ]; then
		run_command+=(
			"; printf '%s\n' '-> Dropping into container shell.'"
			"; ash"
		)
	fi
	install -D -m 0755 <(printf '%s\n\n%s\n' '#!/bin/sh' "${run_command[*]}") "${temp_dir}/run_command.sh"

	${container_runtime} run --rm -it ${container_mounts[@]} ${software_name}-apk-builder ash -c "/run_command.sh" || { printf '%s\n' "Error: Container exited with non-zero status '$?'"; exit 1; }

	mkdir -p "./.release/" # Copy out the built packages
	cp "${temp_dir}/packages/"*/*.apk "./.release/"

	# Copy akms files for manual install
	akms_manual_root_folder='./.release/'
	mkdir -p "${akms_manual_root_folder}" # In case we decide to change the location of the simulated root folder

	mainpkg=$(ls "./.release/"*.apk | head -n 1)
	mainpkgfiles=(
		"etc/depmod.d/${software_name}-oot.conf"
		"etc/modules-load.d/${software_name}-oot.conf"
	)
	tar -xf "${mainpkg}" -C "${akms_manual_root_folder}" "${mainpkgfiles[@]}" --warning=no-unknown-keyword
	akmspkg=$(ls "./.release/"*akms*.apk | head -n 1)
	akmspkgfiles=(
		"usr/src/${software_name}-oot/"
	)
	tar -xf "${akmspkg}" -C "${akms_manual_root_folder}" "${akmspkgfiles[@]}" --warning=no-unknown-keyword
	ircpkg=$(ls "./.release/"*ignore_resource_conflict*.apk | head -n 1)
	ircpkgfiles=(
		"etc/modprobe.d/${software_name}-oot.conf"
	)
	tar -xf "${ircpkg}" -C "${akms_manual_root_folder}" "${ircpkgfiles[@]}" --warning=no-unknown-keyword
}

build_rpm() {
	containerfile=$(cat <<'EOF'
FROM registry.fedoraproject.org/fedora-minimal:latest

# Install the build dependencies
# Note: Unlike with Alpine, we can't get away with only the -dev(el) package, we need the full kernel package.
# TODO: Unfortunately we need the full 'kernel' package for build testing, maybe there is a way to reliably install it without dependencies?
# DNF is needed by akmods to install the resulting package.
RUN microdnf install -y \
	rpmdevtools \
	kmodtool \
	kernel \
	kernel-devel \
	akmods \
	dnf

# Save kernel dev name
RUN printf '%s\n' "$(ls /lib/modules/ | head -n 1)" >/kernel_dev_name.txt

# Create the rpmbuild directory structure
RUN rpmdev-setuptree
EOF
)
	printf '%s\n' "${containerfile}" | ${container_runtime} build -t ${software_name}-rpm-builder -f - # Build the container

	mkdir -p "${temp_dir}/"{SOURCES,SPECS,RPMS,SRPMS} # Create shared build directories in temp dir
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/SOURCES,target=/root/rpmbuild/SOURCES"
		"--mount type=bind,source=${temp_dir}/SPECS,target=/root/rpmbuild/SPECS"
		"--mount type=bind,source=${temp_dir}/RPMS,target=/root/rpmbuild/RPMS"
		"--mount type=bind,source=${temp_dir}/SRPMS,target=/root/rpmbuild/SRPMS"
		"--mount type=bind,source=${temp_dir}/run_command.sh,target=/run_command.sh"
	)

	spec_overrides=(
		"%global source_modname ${software_name}"
		"%global repo_name ${origin_name}"
		"%global repo_owner ${origin_owner}"
		"%global repo_commit ${current_commit}"
		"%global package_timestamp $(date --date="${working_tree_timestamp}" +%Y%m%d)"
	)
	for spec_file in "./redhat/"*.spec; do # Write overrides, then insert the original spec file
		spec_file_target="${temp_dir}/SPECS/${spec_file##*/}"
		printf '%s\n' "${spec_overrides[@]}" >"${spec_file_target}"
		cat "${spec_file}" >>"${spec_file_target}"
	done

	tar --exclude="../${PWD##*/}/.git" -czvf "${temp_dir}/SOURCES/${origin_name}.tar.gz" "../${PWD##*/}" # The spec files expect the sources in a subdirectory of the archive (as with GitHub tarballs)

	run_command=(
		"rpmbuild -ba /root/rpmbuild/SPECS/*.spec"
		"&& printf '%s\n' '-> Package building complete.'"
	)
	if [ "$no_pkg_tests" != 'true' ]; then # Testing installing the package and akms dynamic builds
		run_command+=(
			"&& rpm --install /root/rpmbuild/RPMS/*/*.rpm"
			"&& akmods --kernels \$(cat /kernel_dev_name.txt) --akmod ${software_name}-oot"
			"&& modinfo /lib/modules/\$(cat /kernel_dev_name.txt)/extra/${software_name}-oot/${software_name}.ko*"
			"&& printf '%s\n' '-> Checking if module is removed on package uninstall.'"
			"&& rpm --query --all '*${software_name}-oot*' | xargs rpm --erase"
			"&& { ! modinfo --filename /lib/modules/\$(cat /kernel_dev_name.txt)/extra/${software_name}-oot/${software_name}.ko* &>/dev/null || { printf '%s\n' '-> Error: Module was not removed on package uninstall.'; return 1; }; }"
			"&& printf '%s\n' '-> Package installation and akms dynamic build tests successful.'"
		)
	fi
	if [ "$inspect_container" == 'true' ]; then
		run_command+=(
			"; printf '%s\n' '-> Dropping into container shell.'"
			"; bash"
		)
	fi
	install -D -m 0755 <(printf '%s\n\n%s\n' '#!/bin/sh' "${run_command[*]}") "${temp_dir}/run_command.sh"

	${container_runtime} run --rm -it ${container_mounts[@]} ${software_name}-rpm-builder bash -c "/run_command.sh" || { printf '%s\n' "Error: Container exited with non-zero status '$?'"; exit 1; }

	mkdir -p "./.release/"{SRPMS,RPMS}
	cp "${temp_dir}/SRPMS/"*.src.rpm "./.release/SRPMS/"
	cp "${temp_dir}/RPMS/"*/*.rpm "./.release/RPMS/"
}

build_deb() { # TODO: Support this packaging method like apk and rpm
	containerfile=$(cat <<'EOF'
FROM docker.io/library/debian:stable-slim

RUN apt-get update && apt-get install -y \
	debhelper \
	dkms

# Save kernel dev name
RUN printf '%s\n' "$(ls /lib/modules/ | head -n 1)" >/kernel_dev_name.txt
EOF
)
	printf '%s\n' "${containerfile}" | ${container_runtime} build -t ${software_name}-deb-builder -f -
	
	cp -r "../${PWD##*/}" "${temp_dir}/${software_name}"
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/,target=/root"
		"--mount type=bind,source=${temp_dir}/run_command.sh,target=/run_command.sh"
	)

	run_command=(
		"("
		"cd /root/${software_name}"
		"&& dpkg-buildpackage --no-sign"
		")"
		"&& printf '%s\n' '-> Package building complete.'"
	)
	if [ "$no_pkg_tests" != 'true' ]; then # Testing installing the package and dkms dynamic builds
		run_command+=(
			"&& dpkg --install /root/*.deb"
			"&& modinfo /lib/modules/\$(cat /kernel_dev_name.txt)/updates/dkms/${software_name}.ko*"
			"&& printf '%s\n' '-> Checking if module is removed on package uninstall.'"
			"&& dpkg-query --show --showformat='\${Package}' '*${software_name}*' | xargs dpkg --remove"
			"&& { ! modinfo --filename /lib/modules/\$(cat /kernel_dev_name.txt)/updates/dkms/${software_name}.ko* &>/dev/null || { printf '%s\n' '-> Error: Module was not removed on package uninstall.'; return 1; }; }"
			"&& printf '%s\n' '-> Package installation and akms dynamic build tests successful.'"
		)
	fi
	if [ "$inspect_container" == 'true' ]; then
		run_command+=(
			"; printf '%s\n' '-> Dropping into container shell.'"
			"; bash"
		)
	fi
	install -D -m 0755 <(printf '%s\n\n%s\n' '#!/bin/sh' "${run_command[*]}") "${temp_dir}/run_command.sh"
	
	${container_runtime} run --rm -it ${container_mounts[@]} ${software_name}-deb-builder bash -c "${run_command[*]}" || { printf '%s\n' "Error: Container exited with non-zero status '$?'"; exit 1; }

	mkdir -p "./.release/"
	cp "${temp_dir}/"*.deb "./.release/"
}


# ----
# Main
# ----
gather_repo_info
parse_arguments "$@"
trap cleanup EXIT

startup
print_repo_info

case "$package_system" in
	apk)
		build_apk
		;;
	rpm)
		build_rpm
		;;
	deb)
		build_deb
		;;
	*)
		printf '%s\n' "Error: Unknown package system '$package_system'" # This should never happen since the argument parser validates the input
		exit 1
		;;
esac

echo "Program completed successfully"; exit 0
