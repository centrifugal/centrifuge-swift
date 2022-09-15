//
//  DebugLogger.swift
//  SwiftCentrifuge_Example
//
//  Created by Anton Selyanin on 15.09.2022.
//  Copyright © 2022 CocoaPods. All rights reserved.
//

import Foundation
import SwiftCentrifuge

final class PrintLogger: CentrifugeLogger {
    func log(level: CentrifugeLoggerLevel,
             message: @autoclosure () -> String,
             file: String,
             function: String,
             line: UInt) {
        let file = (URL(string: file)?.lastPathComponent) ?? file
        print("[\(level)] \(file):\(line) \(message())")
    }
}
