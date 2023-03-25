#!/usr/bin/env bash
set -e

# Get information
# ---------------
software_name="it87"
current_date="$(date +%Y%m%d)"

origin_url="$(git remote get-url origin 2>/dev/null || printf 'unknown')"
[ "$origin_url" != 'unknown' ] && origin_name="${origin_url##*/}"
[ "$origin_url" != 'unknown' ] && origin_owner="${origin_url%/*}"; origin_owner="${origin_owner##*/}"

current_commit="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
[ "$current_commit" == 'unknown' ] && current_commit="${current_date}"

current_commit_date="$(git show -s --format=%cd --date=short "${current_commit}" 2>/dev/null || printf 'unknown')"
[ "$current_commit_date" == 'unknown' ] && current_commit_date="${current_date}"

generic_version="0~${origin_owner}^${current_date}git${current_commit:0:7}"

printf '%s\n' "Determined the following values:"
printf '\t%s:%s\n' \
	"software_name" "$software_name" \
	"origin_name" "$origin_name" \
	"origin_url" "$origin_url" \
	"origin_owner" "$origin_owner" \
	"current_commit" "$current_commit" \
	"current_commit_date" "$current_commit_date" \
	"current_date" "$current_date" \
	"generic_version" "$generic_version" 

# Functions
# ---------

build_apk() {
	mkdir -p "${temp_dir}/"{APKBUILD/src,packages}
	build_overrides=(
		"source_modname=\"${software_name}\""
		"repo_name=\"${origin_name}\""
		"repo_owner=\"${origin_owner}\""
		"repo_commit=\"${current_commit}\""
		"repo_commit_date=\"${current_commit_date}\""
		"package_timestamp=\"${current_date}\""
	)
	for build_file in "./packaging/apk-akms/"{APKBUILD,AKMBUILD}; do
		build_file_target="${temp_dir}/APKBUILD/${build_file##*/}"
		printf '%s\n' "${build_overrides[@]}" >"${build_file_target}"
		cat "${build_file}" >>"${build_file_target}"
	done
	tar -czvf "${temp_dir}/APKBUILD/${origin_name}.tar.gz" "../${PWD##*/}"
	echo "$(cat "./packaging/apk-akms/Containerfile")" | ${container_runtime} build -t ${software_name}-apk-builder -
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/APKBUILD,target=/APKBUILD"
		"--mount type=bind,source=${temp_dir}/packages,target=/root/packages"
	)
	run_command="abuild-keygen -a -n && abuild -F checksum && abuild -F srcpkg && abuild -F"
	${container_runtime} run --rm ${container_mounts[@]} ${software_name}-apk-builder ash -c "${run_command}" || { echo "Error: Container exited with non-zero status '$?'"; exit 1; }
	mkdir -p ".release/"
	cp "${temp_dir}/packages/"*/*.apk ".release/"
}

build_deb() {
	printf '%s\n' "NOT IMPLEMENTED YET"
}

build_rpm() {
	mkdir -p "${temp_dir}/"{SOURCES,SPECS,RPMS,SRPMS} # Create shared build directories in temp dir
	spec_overrides=(
		"%global source_modname ${software_name}"
		"%global repo_name ${origin_name}"
		"%global repo_owner ${origin_owner}"
		"%global repo_commit ${current_commit}"
		"%global package_timestamp ${current_date}"
	)
	for spec_file in "./packaging/rpm-akmod/"*.spec; do # Write overrides, then insert the original spec file
		spec_file_target="${temp_dir}/SPECS/${spec_file##*/}"
		printf '%s\n' "${spec_overrides[@]}" >"${spec_file_target}"
		cat "${spec_file}" >>"${spec_file_target}"
	done
	tar -czvf "${temp_dir}/SOURCES/${origin_name}.tar.gz" "../${PWD##*/}" # The spec files expect the sources in a subdirectory of the archive (as with GitHub tarballs)
	echo "$(cat "./packaging/rpm-akmod/Containerfile")" | ${container_runtime} build -t ${software_name}-rpm-builder - # Piping in the Containerfile allows for Docker support since naming isn't an issue.
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/SOURCES,target=/root/rpmbuild/SOURCES"
		"--mount type=bind,source=${temp_dir}/SPECS,target=/root/rpmbuild/SPECS"
		"--mount type=bind,source=${temp_dir}/RPMS,target=/root/rpmbuild/RPMS"
		"--mount type=bind,source=${temp_dir}/SRPMS,target=/root/rpmbuild/SRPMS"
	)
	run_command="rpmbuild -ba /root/rpmbuild/SPECS/*.spec"
	${container_runtime} run --rm ${container_mounts[@]} ${software_name}-rpm-builder bash -c "${run_command}" || { echo "Error: Container exited with non-zero status '$?'"; exit 1; }
	mkdir -p ".release/"{SRPMS,RPMS}
	cp "${temp_dir}/SRPMS/"*.src.rpm ".release/SRPMS/"
	cp "${temp_dir}/RPMS/"*/*.rpm ".release/RPMS/"
}

build_generic_dkms() {
	printf '%s\n' "NOT IMPLEMENTED YET"
}

startup() {
	printf '%s\n' "Starting program..."
	rm -rf ".release/" && printf '%s\n' "Deleted previous release directory." || { printf '%s\n' "Error: Failed to delete previous release directory."; exit 1; }
	temp_dir="$(mktemp -t --directory ${software_name}_tmp.XXXXXXXXXX)" && printf '%s\n' "Created temporary directory '${temp_dir}'." || { printf '%s\n' "Error: Failed to create temporary directory."; exit 1; }
	printf '%s\n' "Startup complete."
}

cleanup() {
	printf '%s\n' "Cleaning up..."
	printf '%s\n' "Listing contents of shared temp dir at '${temp_dir}':"
	tree "${temp_dir}" 2>/dev/null || ls -R "${temp_dir}" || printf '%s\n' "Error: Failed to list contents of '${temp_dir}'."
	printf '%s' "Deleting temporary directory '${temp_dir}'... "
	rm -rf "${temp_dir}" && printf '%s\n' "OK." || { printf '%s\n' "Error: Failed to delete '${temp_dir}'."; exit 1; }
	printf '%s\n' "Cleanup complete."
}

# Main
# ----

help="Usage: $0 [docker (experimental)|podman (recommended)] [apk|deb|rpm|tar]"

startup
trap cleanup EXIT

case "$1" in
	docker|d|dock)
		if ! command -v docker &>/dev/null; then
			printf '%s\n' "Error: Docker is not installed."
			exit 1
		fi
		printf '%s\n' "Warning: Docker support is experimental, Podman is recommended."
		read -p "Continue? [y/N] "
		if [[ ! "$REPLY" =~ ^[Yy] ]]; then
			printf '%s\n' "Aborting..."
			exit 1
		fi
		container_runtime="docker"
		;;
	podman|p|pod)
		if ! command -v podman &>/dev/null; then
			printf '%s\n' "Error: Podman is not installed."
			exit 1
		fi
		container_runtime="podman"
		;;
	*)
		printf '%s\n' "$help"
		exit 1
		;;
esac

case "$2" in
	apk)
		build_apk
		;;
	deb)
		build_deb
		;;
	rpm)
		build_rpm
		;;
	generic_dkms)
		build_generic_dkms
		;;
	*)
		printf '%s\n' "$help"
		exit 1
		;;
esac

echo "Done."; exit 0
