//
//  Memory.swift
//  SignalBox
//
//  Created by Scott James Remnant on 12/18/16.
//
//

#if os(Linux)
    import Glibc
    
    let MAP_FAILED = UnsafeMutableRawPointer(bitPattern: -1)! as UnsafeMutableRawPointer!
#else
    import Darwin
    
    let O_SYNC: Int32 = 0
#endif

import Foundation

import Mailbox


let pageSize = 4096
let peripheralBlockSize = pageSize


let bcm2835PhysicalBaseAddress = 0x20000000
let bcm2835Size = 0x01000000

let peripheralBusBaseAddress = 0x7e000000

let (peripheralPhysicalBaseAddress, peripheralAddressSize) = ranges()

func ranges() -> (Int, Int) {
    let rangeMap = try! loadRangeMap()
    if let (physicalAddress, size) = rangeMap[peripheralBusBaseAddress] {
        return (physicalAddress, size)
    } else {
        return (bcm2835PhysicalBaseAddress, bcm2835Size)
    }
}

let socRangesPath = "/proc/device-tree/soc/ranges"
func loadRangeMap() throws -> [Int: (Int, Int)] {
    let ranges = try Data(contentsOf: URL(fileURLWithPath: socRangesPath))
    return ranges.withUnsafeBytes { (addresses: UnsafePointer<Int>) -> [Int: (Int, Int)] in
        let numberOfAddresses = ranges.count / MemoryLayout<Int>.size
        var addressMap: [Int: (Int, Int)] = [:]
        
        for i in 0..<(numberOfAddresses / 3) {
            addressMap[addresses[i + 0].byteSwapped] = (addresses[i + 1].byteSwapped, addresses[i + 2].byteSwapped)
        }
        
        return addressMap
    }
}

let memPath = "/dev/mem"
let memFd: Int32 = {
    let memFd = open(memPath, O_RDWR | O_SYNC)
    guard memFd >= 0 else { fatalError("Couldn't open /dev/mem") }
    return memFd
}()


func mapPeripheral(at offset: Int) -> UnsafeMutableRawPointer {
    guard let pointer = mmap(nil, peripheralBlockSize, PROT_READ | PROT_WRITE, MAP_SHARED, memFd, off_t(peripheralPhysicalBaseAddress + offset)), pointer != MAP_FAILED else { fatalError("Couldn't mmap peripheral") }
    return pointer
}


let mailbox: Mailbox = {
    return try! Mailbox()
}()

//let mailbox = try! Mailbox()


func makeUncachedMap(pages: Int) -> (UInt32, Int, Int, UnsafeMutablePointer<Int>) {
    let handle = try! mailbox.allocateMemory(size: pageSize * pages, alignment: pageSize * pages, flags: .direct)
    let busAddress = try! mailbox.lockMemory(handle: handle)
    
    let physicalAddress = busAddress & Int(bitPattern: ~0xc0000000)
    guard let block = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_SHARED, memFd, off_t(physicalAddress)),
        block != MAP_FAILED else { fatalError("Couldn't mmap") }
    
    print("Mapped")
    print("  BUS  0x" + String(UInt(bitPattern: busAddress), radix: 16))
    print("  PHYS  0x" + String(UInt(bitPattern: physicalAddress), radix: 16))
    print("  VIRT 0x" + String(Int(bitPattern: block), radix: 16))
    print("")
    
    return (handle, busAddress, physicalAddress, block.bindMemory(to: Int.self, capacity: pageSize / MemoryLayout<Int>.stride * pages))
}

func cleanup(handle: Mailbox.MemoryHandle) {
    try! mailbox.unlockMemory(handle: handle)
    try! mailbox.releaseMemory(handle: handle)
}
