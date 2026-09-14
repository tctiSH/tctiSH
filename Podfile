# One number, used both for the platform and for the pin at the bottom.
DEPLOYMENT_TARGET = "18.0"

platform :ios, DEPLOYMENT_TARGET

# Xcode and CocoaPods disagree about how to number this project's format, and
# the disagreement is not settleable: Xcode 27 writes `objectVersion = 71`
# whenever it saves, and no released Xcodeproj knows 71 -- `pod install` then
# dies with "Unable to find compatibility version string for object version".
# Both read 77 quite happily, so normalise to it here.
#
# This has to run from the Podfile body rather than a `pre_install` hook: by the
# time hooks run the analyser has already tried, and failed, to open the project.
require "xcodeproj"

project_path = "tctiSH.xcodeproj/project.pbxproj"
contents = File.read(project_path)
if (found = contents[/^\tobjectVersion = (\d+);/, 1])
  known = Xcodeproj::Constants::COMPATIBILITY_VERSION_BY_OBJECT_VERSION.key?(found.to_i)
  unless known
    puts "Podfile: rewriting unsupported objectVersion #{found} as 77"
    File.write(project_path, contents.sub(/^\tobjectVersion = \d+;/, "\tobjectVersion = 77;"))
  end
end

target "tctiSH" do
  use_frameworks!

  # Pods for tctiSH
  pod "SwiftSH", :git => "https://github.com/Frugghi/SwiftSH.git", :branch => "master"
  pod "BlueSocket"
end

# Both pods declare deployment targets far below ours -- SwiftSH 8.0, BlueSocket
# 10.0 -- and CocoaPods now keeps each podspec's own value rather than raising
# it to the platform, as it did when these were last generated. Xcode 27 refuses
# anything that old, so pin them to ours.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT_TARGET
    end
  end
end
