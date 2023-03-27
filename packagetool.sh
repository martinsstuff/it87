#!/usr/bin/env bash
set -e


# -----------------
# Utility functions
# -----------------
print_usage() {
	usage="$(cat <<EOF
Usage: $0 [options]
Options:
	(Required) --runtime=RUNTIME
		Container runtime to use. Valid values are 'podman' and 'docker'.
	(Required) --package_system=PACKAGE_SYSTEM
		Package system to target. Valid values are 'apk', 'deb', 'rpm', and 'tarball'.
	(Optional) --software_name=SOFTWARE_NAME
		Name of the software to package. Defaults to the name of the current directory ('${PWD##*/}').
	(Optional) --print_repo_info
		Print information about the current repository and exit.
	(Optional) --keep_temp_dir
		Do not delete the temporary directory after the script exits.
	(Optional) --print_temp_dir=PRINT_TEMP_DIR
		Print the path to the temporary directory and exit. Valid values are 'none', 'normal', and 'verbose'.
		'none' is the default and prints nothing.
		'normal' uses 'tree' or 'ls -R' to print the contents of the temporary directory.
		'verbose' uses 'ls -laR' to print the contents of the temporary directory.
	(Optional) --help, -h
		Print this help message and exit.
EOF
)"
	printf '%s\n' "$usage"
}

parse_arguments() {
	while [ "$1" ]; do
		case "$1" in
			--runtime=*)
				runtime="${1#*=}"
				valid_runtimes='(podman|docker)'
				if [[ ! "$runtime" =~ ^${valid_runtimes}$ ]]; then
					printf '%s\n' "Error: Invalid runtime '$runtime', must be one of '$valid_runtimes'"
					exit 1
				fi
				shift
				;;
			--package_system=*)
				package_system="${1#*=}"
				valid_package_systems='(apk|deb|rpm|tarball)'
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
	"runtime"
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
	current_commit="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')" # Commit hash of the current commit
	working_tree_changed="$(git diff-index --quiet HEAD -- &>/dev/null; printf '%s' "$?")" # Whether the working tree has been modified

	if [ "$working_tree_changed" = '0' ]; then # If the working tree is clean, use the commit date. $working_tree_changed is also >0 if we're not a git repository.
		timestamp="$(git show -s --format=%cd --date=iso-strict "${current_commit}" 2>/dev/null || printf 'unknown')"
	else # Otherwise, use the current date
		timestamp="$(date --iso-8601=seconds)"
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
		"timestamp" "$timestamp" \
		"origin_url" "$origin_url" \
		"origin_name" "$origin_name" \
		"origin_owner" "$origin_owner"
}

startup() {
	printf '%s' "Deleting old .release/ folder and creating temporary directory..."
	rm -rf ".release/" || { printf '\n%s\n' "Error: Failed to delete previous release directory."; exit 1; }
	temp_dir="$(mktemp -t --directory ${software_name}_tmp.XXXXXXXXXX)" || { printf '\n%s\n' "Error: Failed to create temporary directory."; exit 1; }
	printf '%s\n' " OK."
}

cleanup() {
	if [ "$print_temp_dir" == 'normal' ]; then
		tree "${temp_dir}" 2>/dev/null || ls -R "${temp_dir}"
	elif [ "$print_temp_dir" == 'verbose' ]; then
		ls -laR "${temp_dir}"
	fi
	printf '%s' "Deleting temporary directory at '${temp_dir}'..."
	rm -rf "${temp_dir}" || { printf '\n%s\n' "Error: Failed to delete temporary directory."; exit 1; }
	printf '%s\n' " OK."
}


# -------------------
# Packaging functions
# -------------------
build_apk() {
	mkdir -p "${temp_dir}/"{APKBUILD/src,packages}
	build_overrides=(
		"source_modname=\"${software_name}\""
		"repo_name=\"${origin_name}\""
		"repo_owner=\"${origin_owner}\""
		"repo_commit=\"${current_commit}\""
		"repo_commit_date=\"${timestamp}\""
		"package_timestamp=\"${current_date}\""
	)
	for build_file in "./packaging/apk-akms/"{APKBUILD,AKMBUILD}; do
		build_file_target="${temp_dir}/APKBUILD/${build_file##*/}"
		printf '%s\n' "${build_overrides[@]}" >"${build_file_target}"
		cat "${build_file}" >>"${build_file_target}"
	done
	tar -czvf "${temp_dir}/APKBUILD/${origin_name}.tar.gz" "../${PWD##*/}"
	echo "$(cat "./alpine/Containerfile")" | ${container_runtime} build -t ${software_name}-apk-builder -
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/APKBUILD,target=/APKBUILD"
		"--mount type=bind,source=${temp_dir}/packages,target=/root/packages"
	)
	run_command="abuild-keygen -a -n && abuild -F checksum && abuild -F srcpkg && abuild -F"
	${container_runtime} run --rm ${container_mounts[@]} ${software_name}-apk-builder ash -c "${run_command}" || { printf '%s\n' "Error: Container exited with non-zero status '$?'"; exit 1; }
	mkdir -p ".release/"
	cp "${temp_dir}/packages/"*/*.apk ".release/"
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
	echo "$(cat "./redhat/Containerfile")" | ${container_runtime} build -t ${software_name}-rpm-builder - # Piping in the Containerfile allows for Docker support since naming isn't an issue.
	container_mounts=(
		"--mount type=bind,source=${temp_dir}/SOURCES,target=/root/rpmbuild/SOURCES"
		"--mount type=bind,source=${temp_dir}/SPECS,target=/root/rpmbuild/SPECS"
		"--mount type=bind,source=${temp_dir}/RPMS,target=/root/rpmbuild/RPMS"
		"--mount type=bind,source=${temp_dir}/SRPMS,target=/root/rpmbuild/SRPMS"
	)
	run_command="rpmbuild -ba /root/rpmbuild/SPECS/*.spec"
	${container_runtime} run --rm ${container_mounts[@]} ${software_name}-rpm-builder bash -c "${run_command}" || { printf '%s\n' "Error: Container exited with non-zero status '$?'"; exit 1; }
	mkdir -p ".release/"{SRPMS,RPMS}
	cp "${temp_dir}/SRPMS/"*.src.rpm ".release/SRPMS/"
	cp "${temp_dir}/RPMS/"*/*.rpm ".release/RPMS/"
}

build_deb() {
	# The deb build process is less flexible than the others.
	echo "Test"
}

build_tarball() {
	printf '%s\n' "NOT IMPLEMENTED YET"
}


# ----
# Main
# ----
gather_repo_info
parse_arguments "$@"
[ ! "$keep_temp_dir" ] && trap cleanup EXIT

startup
print_repo_info
exit 0