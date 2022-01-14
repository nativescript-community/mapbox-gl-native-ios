Pod::Spec.new do |m|

  m.name    = 'Mapbox-iOS-SDK'
  m.version = '5.9.0'

  m.summary           = 'Open source vector map solution for iOS with full styling capabilities.'
  m.description       = 'Open source, OpenGL-based vector map solution for iOS with full styling capabilities and Cocoa Touch APIs.'
  m.homepage          = 'https://docs.mapbox.com/ios/maps/'
  m.license           = { :type => 'BSD', :file => 'LICENSE.md' }
  m.author            = { 'Mapbox' => 'mobile@mapbox.com' }
  m.screenshot        = "https://docs.mapbox.com/ios/api/maps/5.9.0/img/screenshot.png"
  m.social_media_url  = 'https://twitter.com/mapbox'
  m.documentation_url = 'https://docs.mapbox.com/ios/api/maps/'

  m.source = { :http => "https://github.com/DroidsOnRoids/mapbox-gl-native-ios/releases/download/5.9.0-1/mapbox-ios-sdk-5.9.0-xcframework.zip" }

  m.platform              = :ios
  m.ios.deployment_target = '9.0'

  m.requires_arc = true

  m.vendored_frameworks = 'Mapbox.xcframework'
  m.module_name = 'Mapbox'

end
