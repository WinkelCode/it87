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
	(Optional) --print_repo_info
		Print detected information about the current repository and exit.
	(Required) --container_runtime=CONTAINER_RUNTIME
		Container runtime to use. Valid values are 'podman' and 'docker'.
	(Required) --package_system=PACKAGE_SYSTEM
		Package system to target. Valid values are 'apk', 'deb', and 'rpm'.
	(Optional) --no_pkg_tests
		Do not test installation and dynamic build of the package.
	(Optional) --inspect_container
		Inspect the container with a shell after building (and testing) the package.
		Note: 'exit'-ing the container with a non-zero exit code will stop the script as well.
	(Optional) --container_security_privileged
		Run the container with the '--privileged' flag. Primarily needed by Docker for package tests.
		TODO: More granular privileges
	(Optional) --local_cache_dir=LOCAL_CACHE_DIR
		Directory to use as a local cache for the build process.
		Will be only used for saving if 'index.json' is not present in the directory.
		Only works with 'docker' as the container runtime.
	(Optional) --local_cache_ci_mode
		* Only save cache if no cache exists ('index.json' not in directory).
		Note: Very basic implementation, requires separate caches for different package systems.
	(Optional) --keep_temp_dir
		Do not delete the temporary directory after the script exits.
	(Optional) --print_temp_dir=PRINT_TEMP_DIR
		Print contents of the temporary directory when the script exits. Valid values are 'none', 'normal', and 'verbose'.
		'none' is the default and prints nothing.
		'normal' uses 'tree' or 'ls -R' to print the contents of the temporary directory.
		'verbose' uses 'ls -laR' to print the contents of the temporary directory.
		--print_temp_dir is equivalent to --print_temp_dir=normal.
	(Optional) --software_name=SOFTWARE_NAME
		Name of the software to package. Check --print_repo_info for the default value.
		CAUTION: Likely to break things if changed, intended for correcting incorrect default value.
	(Optional) --help, -h
		Print this help message and exit.
EOF
)"
	printf '%s\n' "$usage"
}

parse_arguments() {
	while [ "$1" ]; do
		case "$1" in
			--print_repo_info)
				print_repo_info
				exit 0
				;;
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
			--no_pkg_tests)
				container_run_pkg_tests='false'
				shift
				;;
			--inspect_container)
				inspect_container='true'
				shift
				;;
			--container_security_privileged)
				container_security_privileged='true'
				shift
				;;
			--local_cache_dir=*)
				local_cache_dir="${1#*=}"
				[ "$local_cache_dir" ] || { printf '%s\n' "Error: No value specified for LOCAL_CACHE_DIR"; exit 1; }
				[ -d "$local_cache_dir" ] || { printf '%s\n' "Error: LOCAL_CACHE_DIR '$local_cache_dir' doesn't exist or isn't a directory"; exit 1; }
				[ -w "$local_cache_dir" ] || { printf '%s\n' "Error: LOCAL_CACHE_DIR '$local_cache_dir' isn't writable"; exit 1; }
				shift
				;;
			--local_cache_ci_mode)
				local_cache_ci_mode='true'
				shift
				;;
			--keep_temp_dir)
				keep_temp_dir='true'
				shift
				;;
			--print_temp_dir=*)
				print_temp_dir="${1#*=}"
				[ "$print_temp_dir" ] || { printf '%s\n' "Error: No value specified for PRINT_TEMP_DIR"; exit 1; }
				valid_print_temp_dir='(none|normal|verbose)'
				if [[ ! "$print_temp_dir" =~ ^${valid_print_temp_dir}$ ]]; then
					printf '%s\n' "Error: Invalid PRINT_TEMP_DIR '$print_temp_dir', must be one of '$valid_print_temp_dir'"
					exit 1
				fi
				shift
				;;
			--print_temp_dir)
				print_temp_dir='normal'
				shift
				;;
			--software_name=*)
				software_name="${1#*=}"
				[ -z "$software_name" ] && { printf '%s\n' "Error: No value specified for SOFTWARE_NAME"; exit 1; }
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

	# Verify required options and combinations
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

	if [ "$local_cache_dir" ] && [ "$container_runtime" != 'docker' ]; then
		print_usage
		printf '%s\n' "Error: LOCAL_CACHE_DIR requires 'docker' container runtime"
		exit 1
	fi

	if [ "$local_cache_ci_mode" ] && [ ! "$local_cache_dir" ]; then
		print_usage
		printf '%s\n' "Error: LOCAL_CACHE_CI_MODE requires LOCAL_CACHE_DIR"
		exit 1
	fi

	if [ ! "$container_run_pkg_tests" ]; then
		container_run_pkg_tests='true'
	fi
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
	printf '%s\n' "-> Determined the following information about the current repository:"
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
	printf '%s' "-> Deleting old .release/ folder and creating temporary directory..."
	rm -rf "./.release/" || { printf '\n%s\n' "Error: Failed to delete previous release directory."; exit 1; }
	temp_dir="$(mktemp -t --directory ${software_name}_tmp.XXXXXXXXXX)" || { printf '\n%s\n' "Error: Failed to create temporary directory."; exit 1; }
	[ "$local_cache_dir" ] && { [ -d "$local_cache_dir" ] || mkdir -p "$local_cache_dir" || { printf '\n%s\n' "Error: Error creating local cache directory: '$local_cache_dir'"; exit 1; } }
	printf '%s\n' " OK."
}

cleanup() {
	if [ "$print_temp_dir" == 'normal' ]; then
		printf '%s\n' "-> Contents of temporary directory at '${temp_dir}' ('normal' verbosity):"
		tree "${temp_dir}" 2>/dev/null || ls -R "${temp_dir}"
	elif [ "$print_temp_dir" == 'verbose' ]; then
		printf '%s\n' "-> Contents of temporary directory at '${temp_dir}' ('verbose' verbosity):"
		ls -laR "${temp_dir}"
	fi
	if [ "$keep_temp_dir" == 'true' ]; then
		printf '%s\n' "-> Not removing '${temp_dir}' as per '--keep_temp_dir'."
	else 
		printf '%s' "-> Deleting temporary directory at '${temp_dir}'..."
		rm -rf "${temp_dir}" || { printf '\n%s\n' "Error: Failed to delete temporary directory."; exit 1; }
		printf '%s\n' " OK."
	fi
	echo "-> Program completed successfully"; exit 0
}

container_build_and_run() {
	container_name="${1}"
	container_run_command="${2}"
	
	build_opts=()
	if [ "$local_cache_dir" ] && [ "$container_runtime" == 'docker' ]; then
		if [ -f "${local_cache_dir}/index.json" ]; then # Only trying to load if the cache is not empty.
			printf '%s\n' "-> Will try to load from local container build cache at '${local_cache_dir}'."
			build_opts+=("--cache-from" "type=local,src=${local_cache_dir},compression=uncompressed") # GitHub actions cache always uses zstd compression, so we skip it here.
		fi
		if [ "$local_cache_ci_mode" != 'true' ] || [ ! -f "${local_cache_dir}/index.json" ]; then # If CI mode is NOT enabled, we always save to the cache, if CI mode is enabled, we only save if it's empty.
			printf '%s\n' "-> Will try to save to local container build cache at '${local_cache_dir}'."
			build_opts+=("--cache-to" "type=local,dest=${local_cache_dir},mode=max,compression=uncompressed")
		fi
	fi

	run_opts=(${container_runtime_opts[@]})
	[ "$inspect_container" ] && run_opts+=("-it")
	[ "$container_security_privileged" ] && run_opts+=("--privileged")

	case "$container_runtime" in
		podman)
			printf '%s\n' "${containerfile}" | podman build ${build_opts[@]} --tag "${container_name}" --file - ${temp_dir} ||
				{ printf '%s\n' "Error: Failed to build '${container_name}' image."; exit 1; }
			podman run ${run_opts[@]} --rm "${container_name}" ${container_run_command} ||
				{ printf '%s\n' "Error: '${container_name}' exited with non-zero status '$?'. Aborting."; exit 1; }
			;;
		docker)
			printf '%s\n' "${containerfile}" | docker buildx build ${build_opts[@]} --load --tag "${container_name}" --file - ${temp_dir} ||
				{ printf '%s\n' "Error: Failed to build '${container_name}' image."; exit 1; }
			docker run ${run_opts[@]} --rm "${container_name}" ${container_run_command} ||
				{ printf '%s\n' "Error: '${container_name}' exited with non-zero status '$?'. Aborting."; exit 1; }
			;;
	esac
}

# -------------------
# Packaging functions
# -------------------
build_apk() {
	mkdir -p "${temp_dir}/"{APKBUILD/src,packages} # Create the shared directories
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

	containerfile="$(cat <<'EOF'
FROM docker.io/library/alpine:latest

# Install the build dependencies
RUN apk add \
	abuild \
	build-base
EOF
)"
	containerfile_test="$(cat <<'EOF'


# Install the test dependencies
RUN apk add \
	linux-lts-dev \
	akms

# Remove /proc mount from akms-runas. This works around 'Can't mount proc on /newroot/proc: Operation not permitted' in GitHub Actions.
# Not sure what/if it is needed for but it seems to not have any negative effects right now.
# Update: This removes the --privileged requirement for Podman, but Docker needs --privileged regardless. For now it's commented out and we will be using --privileged for any bwrap related-issues.
# RUN sed -i '/--proc \/proc \\/d' /usr/libexec/akms/akms-runas

# Save kernel dev name
RUN printf '%s\n' "$(ls /lib/modules/ | head -n 1)" >/kernel_dev_name.txt
EOF
)"
	container_runtime_opts=(
		"--mount type=bind,source=${temp_dir}/APKBUILD,target=/APKBUILD"
		"--mount type=bind,source=${temp_dir}/packages,target=/root/packages"
		"--mount type=bind,source=${temp_dir}/run_script.sh,target=/run_script.sh"
	)
	container_run_script=(
		"("
		"cd /APKBUILD"
		"&& abuild-keygen -a -n" # We can't not sign the package, so we generate a one time use key, the user has to install it with `--allow-untrusted`
		"&& abuild -F checksum"
		"&& abuild -F srcpkg"
		"&& abuild -F"
		")"
		"&& printf '%s\n' '-> Package building complete.'"
	)
	if [ "$container_run_pkg_tests" == 'true' ]; then # Testing installing the package and akmod dynamic builds
		containerfile="${containerfile}${containerfile_test}" # Append the test setup and dependencies
		container_run_script+=(
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
		container_run_script+=(
			"; printf '%s\n' '-> Dropping into container shell.'"
			"; ash"
		)
	fi
	install -D -m 0755 <(printf '%s\n\n%s\n' '#!/bin/sh' "${container_run_script[*]}") "${temp_dir}/run_script.sh" # Write the run command

	if [ "$container_run_pkg_tests" == 'true' ]; then
		container_build_and_run "${software_name}-apk-build-and-test" "/run_script.sh"
	else
		container_build_and_run "${software_name}-apk-build" "/run_script.sh"
	fi

	# Copy out the built packages
	mkdir -p "./.release/"
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
	mkdir -p "${temp_dir}/"{SOURCES,SPECS,RPMS,SRPMS} # Create shared build directories in temp dir
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

	containerfile="$(cat <<'EOF'
FROM registry.fedoraproject.org/fedora-minimal:latest

# Install the build dependencies
RUN microdnf install -y \
	rpmdevtools \
	kmodtool

# Create the rpmbuild directory structure
RUN rpmdev-setuptree
EOF
)"
	containerfile_test="$(cat <<'EOF'


# Install the test dependencies
# Note: Unlike with Alpine, we can't get away with only the -dev(el) package, we need the full kernel package.
# TODO: Unfortunately we need the full 'kernel' package for build testing, maybe there is a way to reliably install it without dependencies?
# DNF is needed by akmods to install the resulting package.
RUN microdnf install -y \
	kernel \
	kernel-devel \
	akmods \
	dnf

# Save kernel dev name
RUN printf '%s\n' "$(ls /lib/modules/ | head -n 1)" >/kernel_dev_name.txt
EOF
)"
	container_runtime_opts=(
		"--mount type=bind,source=${temp_dir}/SOURCES,target=/root/rpmbuild/SOURCES"
		"--mount type=bind,source=${temp_dir}/SPECS,target=/root/rpmbuild/SPECS"
		"--mount type=bind,source=${temp_dir}/RPMS,target=/root/rpmbuild/RPMS"
		"--mount type=bind,source=${temp_dir}/SRPMS,target=/root/rpmbuild/SRPMS"
		"--mount type=bind,source=${temp_dir}/run_script.sh,target=/run_script.sh"
	)
	container_run_script=(
		"rpmbuild -ba /root/rpmbuild/SPECS/*.spec"
		"&& printf '%s\n' '-> Package building complete.'"
	)
	if [ "$container_run_pkg_tests" == 'true' ]; then # Testing installing the package and akms dynamic builds
		containerfile="${containerfile}${containerfile_test}" # Append the test setup and dependencies
		container_run_script+=(
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
		container_run_script+=(
			"; printf '%s\n' '-> Dropping into container shell.'"
			"; bash"
		)
	fi
	install -D -m 0755 <(printf '%s\n\n%s\n' '#!/bin/sh' "${container_run_script[*]}") "${temp_dir}/run_script.sh"

	if [ "$container_run_pkg_tests" == 'true' ]; then
		container_build_and_run "${software_name}-rpm-build-and-test" "/run_script.sh"
	else
		container_build_and_run "${software_name}-rpm-build" "/run_script.sh"
	fi

	mkdir -p "./.release/"{SRPMS,RPMS}
	cp "${temp_dir}/SRPMS/"*.src.rpm "./.release/SRPMS/"
	cp "${temp_dir}/RPMS/"*/*.rpm "./.release/RPMS/"
}

build_deb() { # TODO: Support this packaging method like apk and rpm
	cp -r "../${PWD##*/}" "${temp_dir}/${software_name}"

	containerfile="$(cat <<'EOF'
FROM docker.io/library/debian:stable-slim

RUN apt-get update && apt-get install -y \
	debhelper \
	dkms
EOF
)"
	containerfile_test="$(cat <<'EOF'

# Building the package already needs dkms for some reason, which includes the kernel dev stuff, so this is kind of pointless.
# Save kernel dev name
RUN printf '%s\n' "$(ls /lib/modules/ | head -n 1)" >/kernel_dev_name.txt
EOF
)"
	container_runtime_opts=(
		"--mount type=bind,source=${temp_dir}/,target=/root"
		"--mount type=bind,source=${temp_dir}/run_script.sh,target=/run_script.sh"
	)
	container_run_script=(
		"("
		"cd /root/${software_name}"
		"&& dpkg-buildpackage --no-sign"
		")"
		"&& printf '%s\n' '-> Package building complete.'"
	)
	if [ "$container_run_pkg_tests" == 'true' ]; then # Testing installing the package and dkms dynamic builds
		containerfile="${containerfile}${containerfile_test}" # Append the test setup and dependencies
		container_run_script+=(
			"&& dpkg --install /root/*.deb"
			"&& modinfo /lib/modules/\$(cat /kernel_dev_name.txt)/updates/dkms/${software_name}.ko*"
			"&& printf '%s\n' '-> Checking if module is removed on package uninstall.'"
			"&& dpkg-query --show --showformat='\${Package}' '*${software_name}*' | xargs dpkg --remove"
			"&& { ! modinfo --filename /lib/modules/\$(cat /kernel_dev_name.txt)/updates/dkms/${software_name}.ko* &>/dev/null || { printf '%s\n' '-> Error: Module was not removed on package uninstall.'; return 1; }; }"
			"&& printf '%s\n' '-> Package installation and akms dynamic build tests successful.'"
		)
	fi
	if [ "$inspect_container" == 'true' ]; then
		container_run_script+=(
			"; printf '%s\n' '-> Dropping into container shell.'"
			"; bash"
		)
	fi
	install -D -m 0755 <(printf '%s\n\n%s\n' '#!/bin/sh' "${container_run_script[*]}") "${temp_dir}/run_script.sh"

	if [ "$container_run_pkg_tests" == 'true' ]; then
		container_build_and_run "${software_name}-deb-build-and-test" "/run_script.sh"
	else
		container_build_and_run "${software_name}-deb-build" "/run_script.sh"
	fi	

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
