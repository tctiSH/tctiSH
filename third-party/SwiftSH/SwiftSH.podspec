# SwiftSH, vendored so that it can link a libssh2 we build.
#
# Upstream (github.com/Frugghi/SwiftSH) has not changed since 2019, and its pod
# ships libssh2 1.8.0 and a matching OpenSSL as prebuilt archives. That libssh2
# predates every key exchange and host key algorithm the guest's dropbear still
# accepts, so the app could no longer log in at all. See build_libssh2.sh.
#
# The sources here are upstream's at the commit below, with two changes for
# libssh2 1.11, both marked in place:
#
#   Libssh2.swift  the SFTP error switch no longer converts to Int32, because
#                  1.11 types those constants as unsigned long
#   Libssh2.m      session callbacks are set with libssh2_session_callback_set2,
#                  as 1.11.1 deprecates the original
#
# Otherwise what changed is only where the Libssh2 module comes from:
# build-libssh2/out, rather than archives inside the pod.
Pod::Spec.new do |s|
  s.name = "SwiftSH"
  s.version = "0.1.2"
  s.summary = "A Swift SSH framework that wraps libssh2."
  s.homepage = "https://github.com/Frugghi/SwiftSH"
  s.license = { :type => "MIT", :file => "LICENSE" }
  s.authors = { "Tommaso Madonia" => "tommaso@madonia.me" }
  s.source = {
    :git => "https://github.com/Frugghi/SwiftSH.git",
    :commit => "67776928e8fa8b5817c17ecb502aaa53ad9abfdc",
  }

  s.platform = :ios, "18.0"
  s.swift_version = "4.1"
  s.requires_arc = true

  # Upstream split this into Core and Libssh2 subspecs so that another backend
  # could be slotted in. None ever was, and the Podfile only ever took both.
  s.source_files = "SwiftSH/*.{h,m,swift}"

  # build-libssh2/out holds the three archives, the headers, and the module map
  # that `import Libssh2` resolves through; one directory serves all three
  # search paths. PODS_TARGET_SRCROOT is this directory.
  libssh2 = "$(PODS_TARGET_SRCROOT)/../../build-libssh2/out"
  s.pod_target_xcconfig = {
    "SWIFT_INCLUDE_PATHS" => libssh2,
    "HEADER_SEARCH_PATHS" => libssh2,
    "LIBRARY_SEARCH_PATHS" => libssh2,
  }
end
