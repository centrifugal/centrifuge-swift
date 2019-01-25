Pod::Spec.new do |s|
    s.name                  = 'SwiftCentrifuge'
    s.module_name           = 'SwiftCentrifuge'

    s.version               = '0.0.1'

    s.homepage              = 'https://github.com/centrifugal/centrifuge-ios'
    s.summary               = 'Centrifugo and Centrifuge client in Swift'

    s.author                = { 'Alexander Emelin' => 'frvzmb@gmail.com' }
    s.license               = { :type => 'MIT', :file => 'LICENSE' }
    s.platforms             = { :ios => '8.0' }
    s.ios.deployment_target = '8.0'

    s.source_files          = 'Sources/*.swift'
    s.source                = { :git => 'https://github.com/centrifugal/centrifuge-ios.git', :tag => s.version }

    s.dependency 'SwiftProtobuf'
    s.dependency 'SwiftWebSocket'
end
