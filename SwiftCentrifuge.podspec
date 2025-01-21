Pod::Spec.new do |s|
    s.name                  = 'SwiftCentrifuge'
    s.module_name           = 'SwiftCentrifuge'
    s.swift_version         = '5.0'
    s.version               = '0.7.5'

    s.homepage              = 'https://github.com/centrifugal/centrifuge-swift'
    s.summary               = 'Centrifugo and Centrifuge client in Swift'

    s.author                = { 'Alexander Emelin' => 'frvzmb@gmail.com' }
    s.license               = { :type => 'MIT', :file => 'LICENSE' }
    s.platforms             = { :ios => '12.0' }
    s.ios.deployment_target = '12.0'

    s.source_files          = 'Sources/SwiftCentrifuge/*.swift', 'Sources/SwiftCentrifuge/WebSocket/*.swift'
    s.source                = { :git => 'https://github.com/centrifugal/centrifuge-swift.git', :tag => s.version }

    s.dependency 'SwiftProtobuf'
end
