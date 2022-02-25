# Placeholder information, will be overridden by the wrapper script. Change it manually when specfiles are used directly.
#%global project_name it87
#%global repo_owner frankcrawford
#%global repo_commit 77abcbe0c49d7d8dc4530dcf51cecb40ef39f49a
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
source_dirname=$(archivecontents=$(tar -tzf %{SOURCE0} | head -n 1); printf "${archivecontents:0:-1}")
printf "%{repo_owner}-%{version}" >"${source_dirname}/VERSION"

for kernel_version in %{?kernel_versions}; do
    cp -a "${source_dirname}" "_kmod_build_${kernel_version%%___*}"
done

%build
for kernel_version in %{?kernel_versions}; do
    (cd _kmod_build_${kernel_version%%___*}/; make %{?_smp_mflags} modules)
done

%install
for kernel_version in %{?kernel_versions}; do
    install -D -m 0755 "_kmod_build_${kernel_version%%___*}/%{project_name}.ko" "%{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/%{project_name}.ko"
done
%{?akmod_install}

%changelog
# Nothing so far
