# Placeholder information, will be overridden by the wrapper script. Change it manually when specfiles are used directly.
#global project_name it87
#global repo_owner frankcrawford
#global repo_commit 77abcbe0c49d7d8dc4530dcf51cecb40ef39f49a
# Placeholder information end

%define commit_short() %{lua:print(string.sub(rpm.expand('%repo_commit'),1,arg[1]))}
%global debug_package %{nil}

#__WRAPPEROVERRIDEMARKER__

%{!?timestamp:%global timestamp %{lua:print(os.date('!%Y%m%d'))}}

Name:           %{project_name}-kmod
Version:        %{!?version_override:0^%{timestamp}.git%{commit_short 7}}%{?version_override:%{version_override}} 
Release:        1%{?dist}
Summary:        Out-of-tree fork of the it87 kernel module with support for more chips
License:        GPLv2

URL:            https://github.com/%{repo_owner}/%{project_name}
Source0:        %{url}/tarball/%{repo_commit}/%{project_name}.tar.gz

BuildRequires:  kmodtool

%description
Out-of-tree fork of the it87 kernel module with support for more chips. This is the package for the kmodtool.

%{expand:%(kmodtool --target %{_target_cpu} --kmodname "%{name}" --akmod %{?kernels:--for-kernels "%{?kernels}"} 2>/dev/null)}

%prep
%{?kmodtool_check}

%setup -q -c
# We need to get the name of the first directory in the tarball, we could semi-hardcode based on the known pattern it but this is more flexible.
%global source_dirname %(archivecontents=$(tar -tzf %{SOURCE0} | head -n 1) && printf '%s' "${archivecontents:0:-1}")
# Making sure we got our source_dirname as the macro/variable would be empty if the command failed.
if [ ! "%{source_dirname}" ]; then echo "ERROR: RPM macro source_dirname is empty, missing or broken SOURCE0 tarball?"; exit 1; fi

for kernel_version in %{?kernel_versions}; do
    cp -a "%{source_dirname}" "_kmod_build_${kernel_version%%___*}"
done

%build
for kernel_version in %{?kernel_versions}; do
    (cd "_kmod_build_${kernel_version%%___*}/" &&
    printf '%s' "%{repo_owner}-%{version}" >"VERSION" && # This isn't ideal, we should be sending our desired version to make directly, but I couldn't get it to work as the Makefile's instructions seem to take precedence.
    # The VERSION file is only used if the .git folder wasn't copied (as with the build wrapper) and/or git isn't installed.
    make %{?_smp_mflags} TARGET="${kernel_version%%___*}" modules &&
    xz -f "%{project_name}.ko"
    ) || exit 1
done

%install
for kernel_version in %{?kernel_versions}; do
    install -D -m 0755 "_kmod_build_${kernel_version%%___*}/%{project_name}.ko.xz" "%{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/%{project_name}.ko.xz"
done
%{?akmod_install}

%changelog
# Nothing so far
