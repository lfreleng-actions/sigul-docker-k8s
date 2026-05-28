# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
#
# Minimal noarch RPM used by the Sigul integration test suite to
# exercise sign-rpm / sign-rpms end-to-end against the live stack.
#
# This is NOT a real RPM you would ever install on a system: it
# carries no payload of substance, declares no dependencies, and
# exists only so that scripts/run-signing-tests.sh has a small,
# reproducible RPM to sign.
#
# To rebuild this in a throwaway directory:
#   rpmbuild --define "_topdir $(pwd)/build" \
#            --define "_sourcedir ."         \
#            -bb test/fixtures/sigul-test-rpm.spec
#
# The output ends up under build/RPMS/noarch/.

Name:           sigul-ci-test
Version:        1.0.0
Release:        1%{?dist}
Summary:        Throwaway RPM for Sigul integration signing tests

License:        Apache-2.0
URL:            https://github.com/lfreleng-actions/sigul-sign-docker
BuildArch:      noarch

# No Source0: this RPM has no payload to fetch.

%description
This RPM exists solely to be signed by the Sigul integration test
suite.  It carries an empty %%files section, has no scriptlets and
declares no dependencies.  Do not install on a real system.

%prep
# nothing to unpack

%build
# nothing to build

%install
# nothing to install - %files is intentionally empty
mkdir -p %{buildroot}

%files
# Intentionally empty: minimal payload makes signing tests fast.

%changelog
* Wed May 06 2026 The Linux Foundation <releng@linuxfoundation.org> - 1.0.0-1
- Initial throwaway test RPM for sigul-docker integration tests
