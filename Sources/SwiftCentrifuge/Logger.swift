//
//  Logger.swift
//  SwiftCentrifuge
//
//  Created by Anton Selyanin on 09/15/2022.
//

import Foundation

public enum CentrifugeLoggerLevel {
    case trace
    case debug
    case info
    case warning
    case error
}

public protocol CentrifugeLogger {
    func log(level: CentrifugeLoggerLevel,
             message: @autoclosure () -> String,
             file: StaticString,
             function: StaticString,
             line: UInt)
}

public extension CentrifugeLogger {
    func trace(_ message: @autoclosure () -> String,
               file: StaticString = #file,
               function: StaticString = #function,
               line: UInt = #line) {
        log(level: .trace, message: message(), file: file, function: function, line: line)
    }

    func debug(_ message: @autoclosure () -> String,
               file: StaticString = #file,
               function: StaticString = #function,
               line: UInt = #line) {
        log(level: .debug, message: message(), file: file, function: function, line: line)
    }

    func info(_ message: @autoclosure () -> String,
               file: StaticString = #file,
               function: StaticString = #function,
               line: UInt = #line) {
        log(level: .info, message: message(), file: file, function: function, line: line)
    }

    func warning(_ message: @autoclosure () -> String,
               file: StaticString = #file,
               function: StaticString = #function,
               line: UInt = #line) {
        log(level: .warning, message: message(), file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> String,
               file: StaticString = #file,
               function: StaticString = #function,
               line: UInt = #line) {
        log(level: .error, message: message(), file: file, function: function, line: line)
    }
}


final class EmptyLogger: CentrifugeLogger {
    static let instance = EmptyLogger()

    private init() {}

    func log(level: CentrifugeLoggerLevel, message: @autoclosure () -> String, file: StaticString, function: StaticString, line: UInt) {
        // ignore
    }
}
