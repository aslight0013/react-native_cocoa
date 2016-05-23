require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name                = "React"
  s.version             = package['version']
  s.summary             = package['description']
  s.description         = <<-DESC
                            React Native apps are built using the React JS
                            framework, and render directly to native UIKit
                            elements using a fully asynchronous architecture.
                            There is no browser and no HTML. We have picked what
                            we think is the best set of features from these and
                            other technologies to build what we hope to become
                            the best product development framework available,
                            with an emphasis on iteration speed, developer
                            delight, continuity of technology, and absolutely
                            beautiful and fast products with no compromises in
                            quality or capability.
                         DESC
  s.homepage            = "http://facebook.github.io/react-native/"
  s.license             = package['license']
  s.author              = "Facebook"
  s.source              = { :git => "https://github.com/ptmt/react-native-desktop.git", :tag => "v#{s.version}" }
  s.default_subspec     = 'Core'
  s.requires_arc        = true
  s.platform            = :osx, "10.10"
  s.preserve_paths      = "cli.js", "Libraries/**/*.js", "lint", "linter.js", "node_modules", "package.json", "packager", "PATENTS", "react-native-cli"

  s.subspec 'Core' do |ss|
    ss.source_files     = "React/**/*.{c,h,m,mm,S}"
    ss.exclude_files    = "**/__tests__/*", "IntegrationTests/*",
      "React/**/*Map*.*", "React/**/*Navigator*.*", "React/**/*Segmented*.*", "React/**/*StatusBar*.*",
      "React/**/*Keyboard*.*", "React/**/*ModalHost*.*",
      "React/**/*Refresh*.*", "React/**/*NavItem*.*", "React/**/*TabBar*.*", "React/**/*Accessibility*.*"
    ss.frameworks       = "JavaScriptCore"
  end

  s.subspec 'RCTImage' do |ss|
    ss.dependency         'React/Core'
    ss.dependency         'React/RCTNetwork'
    ss.source_files     = "Libraries/Image/*.{h,m}"
    ss.preserve_paths   = "Libraries/Image/*.js"
  end

  s.subspec 'RCTNetwork' do |ss|
    ss.dependency         'React/Core'
    ss.source_files     = "Libraries/Network/*.{h,m}"
    ss.preserve_paths   = "Libraries/Network/*.js"
  end

  s.subspec 'RCTSettings' do |ss|
    ss.dependency         'React/Core'
    ss.source_files     = "Libraries/Settings/*.{h,m}"
    ss.preserve_paths   = "Libraries/Settings/*.js"
  end

  s.subspec 'RCTText' do |ss|
    ss.dependency         'React/Core'
    ss.source_files     = "Libraries/Text/*.{h,m}"
    ss.preserve_paths   = "Libraries/Text/*.js"
  end

  s.subspec 'RCTWebSocket' do |ss|
    ss.dependency         'React/Core'
    ss.source_files     = "Libraries/WebSocket/*.{h,m}"
    ss.preserve_paths   = "Libraries/WebSocket/*.js"
  end

  s.subspec 'RCTLinkingIOS' do |ss|
    ss.dependency         'React/Core'
    ss.source_files     = "Libraries/LinkingIOS/*.{h,m}"
    ss.preserve_paths   = "Libraries/LinkingIOS/*.js"
  end

  s.subspec 'RCTTest' do |ss|
    ss.dependency         'React/Core'
    ss.source_files     = "Libraries/RCTTest/**/*.{h,m}"
    ss.preserve_paths   = "Libraries/RCTTest/**/*.js"
    ss.frameworks       = "XCTest"
  end
end
