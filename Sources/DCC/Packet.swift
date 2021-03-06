//
//  Packet.swift
//  DCC
//
//  Created by Scott James Remnant on 5/15/18.
//

import Util

public protocol Packet : Packable {
    
    var bytes: [UInt8] { get }

}

extension Packet {
    
    public func add<T : Packer>(into packer: inout T) {
        for byte in bytes {
            packer.add(0, length: 1)
            packer.add(byte, length: 8)
        }
        
        let errorDetectionByte = bytes.reduce(0, { $0 ^ $1 })
        packer.add(0, length: 1)
        packer.add(errorDetectionByte, length: 8)
        
        packer.add(1, length: 1)
    }
    
}

public struct Preamble : Packable {
    
    // FIXME: This is just a thought experiment, it might not be the best way
    // to do preambles.
    
    public var timing: SignalTiming
    public var withCutout: Bool
    
    init(timing: SignalTiming, withCutout: Bool = true) {
        self.timing = timing
        self.withCutout = withCutout
    }
    
    public func add<T : Packer>(into packer: inout T) {
        let count = timing.preambleCount + (withCutout ? timing.railComCount : 0)
        if count <= UInt64.bitWidth {
            // FIXME: since Packer iterates the bits anyway, is this really an
            // optimisation?
            packer.add(UInt64.mask(bits: count), length: count)
        } else {
            for _ in 0..<count {
                packer.add(1, length: 1)
            }
        }
    }
    
}
