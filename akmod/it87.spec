# Placeholder information, will be overridden by the wrapper script. Change it manually when specfiles are used directly.
#global project_name it87
#global repo_owner frankcrawford
#global repo_commit 77abcbe0c49d7d8dc4530dcf51cecb40ef39f49a
#global addepmod true
#global addmodload true
#global acpiworkaround true
# Placeholder information end

%define commit_short() %{lua:print(string.sub(rpm.expand('%repo_commit'),1,arg[1]))}

%global debug_package %{nil}

#__WRAPPEROVERRIDEMARKER__

%{!?timestamp:%global timestamp %{lua:print(os.date('!%Y%m%d'))}}

Name:           %{project_name}
Version:        %{!?version_override:0^%{timestamp}.git%{commit_short 7}}%{?version_override:%{version_override}} 
Release:        1%{?dist}
Summary:        Out-of-tree fork of the it87 kernel module with support for more chips
License:        GPLv2

URL:            https://github.com/%{repo_owner}/%{project_name}
Source0:        %{url}/tarball/%{repo_commit}/%{project_name}.tar.gz

Requires:       %{name}-kmod >= %{version}
Provides:       %{name}-kmod-common = %{version}

BuildArch:      noarch

%description
Out-of-tree fork of the it87 kernel module with support for more chips. This is the userland package.

%prep

%setup -q -c
source_dirname=$(archivecontents=$(tar -tzf %{SOURCE0} | head -n 1); printf "${archivecontents:0:-1}")

cp -a "${source_dirname}/"{LICENSE,README,ISSUES} "./"

%build
if [ %{?adddepmod} ]; then
    printf '%s' "override %{project_name} * extra/%{project_name}" >"depmod_%{project_name}.conf"
fi
if [ %{?addmodload} ]; then
    printf '%s' "%{project_name}" >"modload_%{project_name}.conf"
fi
if [ %{?acpiworkaround} ]; then
    printf '%s' "options %{project_name} ignore_resource_conflict" >"modprobe_%{project_name}.conf"
fi

%install
# Unlike with "_modprobedir", I was unable to find a macro for depmod.d, so we hardcode the path.
%{?addepmod:install -D -m 0644 "depmod_%{project_name}.conf" "%{buildroot}/%{_prefix}/lib/depmod.d/%{project_name}.conf"}
%{?addmodload:install -D -m 0644 "modload_%{project_name}.conf" "%{buildroot}/%{_modulesloaddir}/%{project_name}.conf"}
%{?acpiworkaround:install -D -m 0644 "modprobe_%{project_name}.conf" "%{buildroot}/%{_modprobedir}/%{project_name}.conf"}

%files
%doc README ISSUES
%license LICENSE
%{?addepmod:%{_prefix}/lib/depmod.d/%{project_name}.conf}
%{?addmodload:%{_modulesloaddir}/%{project_name}.conf}
%{?acpiworkaround:%{_modprobedir}/%{project_name}.conf}

%changelog
# Nothing so far
