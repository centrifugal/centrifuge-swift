
struct disconnectOptions: Decodable {
    var reason: String
    var reconnect: Bool
}

//
//  Helpers.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 05/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//


struct resolveData {
    var error: Error?
    var reply: Proto_Reply?
}

func serializeCommands(commands: [Proto_Command]) throws -> Data {
    let stream = OutputStream.toMemory()
    stream.open()
    for command in commands {
        try BinaryDelimited.serialize(message: command, to: stream)
    }
    stream.close()
    return stream.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
}

func deserializeCommands(data: Data) throws -> [Proto_Reply] {
    var commands = [Proto_Reply]()
    let stream = InputStream(data: data as Data)
    stream.open()
    while true {
        do {
            let res = try BinaryDelimited.parse(messageType: Proto_Reply.self, from: stream)
            commands.append(res)
        } catch BinaryDelimited.Error.truncated {
            // End of stream
            break
        }
    }
    return commands
}

