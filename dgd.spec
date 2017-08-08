#
#  Preamble
#
%define dgd_top /usr/sbin

%define _with_SysV      %(rpm -q systemd >/dev/null 2>&1; echo $?)

# rpmbuild --with systemd
%if %{?_with_systemd:1}%{!?_with_systemd:0}
%define _with_SysV      0
%endif

# rpmbuild --without systemd
%if %{?_without_systemd:1}%{!?_without_systemd:0}
%define _with_SysV      1
%endif

Summary: DeadGatewayDetection Package
Name: dgd
Version: 2.0.0
Release: 5%{?dist}
License: LANL
Group: Applications/System
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-buildroot
Source: YellowNet:/usr/projects/hpc3_infrastructure/src/DGD/%{name}-%{version}.tar.gz
Packager: Susan Coulter <skc@lanl.gov>
Provides: perl(dgd_init)
BuildArch: noarch

%description
Deploys a number of tests, driven by a configuration file, to test various
parts of an HPC IO subsystem.

%if %{_with_SysV}
Requires(post): /sbin/chkconfig
Requires(preun):/sbin/chkconfig /sbin/service
%else
Requires:       systemd
Requires(post): systemd
Requires(preun):systemd
Requires(postun):systemd
%endif

%prep
# Make sure buildroot is squeaky clean
[[ ( -n "$RPM_BUILD_ROOT" ) && ( "$RPM_BUILD_ROOT" != / ) ]] && 
  (%{__rm} -rf $RPM_BUILD_ROOT)

# Exclude dgd.pl from RPM's dependency check
#   This was causing errors on install looking for dgd_init
cat << \EOF > %{name}-req
#!/bin/sh
%{__perl_requires} $* |\
sed -e '/perl(dgd.pl)/d'
EOF
%define __perl_requires %{_builddir}/%{name}-req
chmod 755 %{__perl_requires}

%setup 


%install

# Directories
install -d $RPM_BUILD_ROOT%{_datadir}/%{name}

# Scripts
install -D dgd.pl $RPM_BUILD_ROOT%{dgd_top}/dgd.pl
install -D dgd_init.pm $RPM_BUILD_ROOT%{dgd_top}/dgd_init.pm
install -D dgdcfg $RPM_BUILD_ROOT%{_datadir}/dgd/dgdcfg.sample

# Startup
%if %{_with_SysV}
install -D dgd $RPM_BUILD_ROOT%{_sysconfdir}/init.d/dgd
%else
install -D dgd $RPM_BUILD_ROOT%{_libexecdir}/dgd
install -D dgd.service $RPM_BUILD_ROOT%{_unitdir}/dgd.service
%endif

# Man page
install -D dgd.1.gz $RPM_BUILD_ROOT%{_mandir}/man1/dgd.1.gz


%clean
[[ ( -n "$RPM_BUILD_ROOT" ) && ( "$RPM_BUILD_ROOT" != / ) ]] && 
  (%{__rm} -rf $RPM_BUILD_ROOT)

%files
# There are four fields for the %defattr tag:
#    Attributes for regular files
#    Owner
#    Group
#    Attributes for directories 
%defattr(-,root,root,-)

# Directories
%attr(0755,root,root)	%dir	%{_datadir}/%{name}

# Scripts
%attr(0544,root,root)		%{dgd_top}/dgd.pl
%attr(0544,root,root)		%{dgd_top}/dgd_init.pm
%attr(0444,root,root)		%{_datadir}/dgd/dgdcfg.sample

# Startup
%if %{_with_SysV}
%attr(0544,root,root)		%{_sysconfdir}/init.d/dgd
%else
%attr(0644,root,root)           %{_unitdir}/dgd.service
%attr(0544,root,root)           %{_libexecdir}/dgd
%endif

# Man page
%attr(0644,root,root)		%{_mandir}/man1/dgd.1.gz


%changelog
* Tue Aug 01 2017 Susan Coulter <skc@lanl.gov> - r5
- Set message for state change to CRITICAL
- Added management of LNet process on nodes that change state
- Move ospf service command to config file
- Added timeout for pexec command
- Minor cleanup
* Thu Nov 17 2016 Susan Coulter <skc@lanl.gov> - r4
- Changes to support systemd and CTS-1 clusters
* Mon Oct 31 2016 Susan Coulter <skc@lanl.gov> - r3
- Minor changes/fixes
-    fix problem honoring DST skip file
-    moved cut parameter for nodes to config file
-    added sanity check to avoid taking out most/all IO nodes
* Tue Sep 06 2016 Susan Coulter <skc@lanl.gov> - r2
- Minor changes to allow multiple image names
-    Found while testing on lightshow
* Mon Aug 29 2016 Susan Coulter <skc@lanl.gov> - r1
- Major upgrade including
-  Tests driven by order in config file
-  Implemented array of functions and function parameters 
-  Results checked after each test for faster identification
-  Three signals implemented
-    Wake up the process
-    Put the process back to sleep
-    Dump the status of the health tracking
* Tue Sep 10 2013 Jesse Martinez <jmartinez@lanl.gov> - r4
- Renamed main file (dgdv2.pl) to dgd.pl
- Added file location for DST file
* Mon Aug 12 2013 Jesse Martinez <jmartinez@lanl.gov> - r3
- Added code to handle IO LOG Health Checking in dgdv2
- Added code to check for DST in dgdv2
- Added logic to handle multiple compute images in dgd_init
* Tue Oct  2 2012 Susan Coulter <skc@lanl.gov> - r2
- Fixed code to recognize failure mode of node refusing ssh connection
- Removed unused special hurricane initialization code
- Added special cerrillos initialization variables
* Fri Jul  3 2012 Susan Coulter <skc@lanl.gov> - r1
- Initial build
