//
//  Driver.swift
//  SignalBox
//
//  Created by Scott James Remnant on 12/30/16.
//
//

import Dispatch

import RaspberryPi


public class Driver {
    
    public static let dccGpio = 18
    public static let railComGpio = 17
    public static let debugGpio = 19
    
    public static let dmaChannel = 5
    public static let clockIdentifier: ClockIdentifier = .pwm

    public static let desiredBitDuration: Float = 14.5
    public let bitDuration: Float
    let divisor: Int

    public let raspberryPi: RaspberryPi

    /// Number of DREQ signals to delay non-PWM events to synchronize with the PWM output.
    ///
    /// Writing to the PWM FIFO does not immediately result in output, instead the word that we write is first placed into the FIFO, and then next into the PWM's internal queue, before being output. Thus to synchronize an external event, such as a GPIO, with the PWM output we delay it by this many DREQ signals.
    static let eventDelay = 2

    /// Queue of bitstreams.
    ///
    /// The first bitstream in the queue is the one that most recently begun, the last bitstream in the queue is the one that will be repeated.
    ///
    /// - Note: Modifications to this queue must only be made within blocks scheduled on `dispatchQueue`.
    public private(set) var bitstreamQueue: [QueuedBitstream] = []

    /// Dispatch queue for `bitstreamQueue`.
    let dispatchQueue: DispatchQueue

    /// Dispatch group for `dispatchQueue`.
    ///
    /// Items are placed into `dispatchQueue` using `asyncAfter()`, in order to synchronize those on shutdown, items are entered into this dispatch group and removed afterwards.
    let dispatchGroup: DispatchGroup
    
    /// Indicates whether the Driver is currently running.
    public internal(set) var isRunning = false

    public init(raspberryPi: RaspberryPi) {
        self.raspberryPi = raspberryPi
        
        dispatchQueue = DispatchQueue(label: "com.netsplit.DCC.Driver")
        dispatchGroup = DispatchGroup()
        
        divisor = Int(Driver.desiredBitDuration * 19.2)
        bitDuration = Float(divisor) / 19.2
        
        print("DMA Driver: divisor \(divisor), bit duration \(bitDuration)µs")
    }
    
    /// Initialize hardware.
    ///
    /// Sets up the PWM, GPIO and DMA hardware and prepares for a bitstream to be queued. The DMA Engine will not be activated until the first bitstream is queued with `queue(bitstream:)`.
    public func startup() {
        // Disable both PWM channels, and reset the error state.
        var pwm = raspberryPi.pwm()
        pwm.dmaConfiguration.remove(.enabled)
        pwm.control.remove([ .channel1Enable, .channel2Enable ])
        pwm.status.insert([ .busError, .fifoReadError, .fifoWriteError, .channel1GapOccurred, .channel2GapOccurred, .channel3GapOccurred, .channel4GapOccurred ])

        // Clear the FIFO, and ensure neither channel is consuming from it.
        pwm.control.remove([ .channel1UseFifo, .channel2UseFifo ])
        pwm.control.insert(.clearFifo)
        
        // Set the PWM clock, using the oscillator as a source. In order to ensure consistent timings, use an integer divisor only.
        var clock = raspberryPi.clock(identifier: Driver.clockIdentifier)
        clock.disable()
        clock.control = [ .source(.oscillator), .mash(.integer) ]
        clock.divisor = [ .integer(divisor) ]
        clock.enable()
        
        // Make sure that the DMA Engine is enabled, abort any existing use of it, and clear error state.
        var dma = raspberryPi.dma(channel: Driver.dmaChannel)
        dma.enabled = true
        dma.controlStatus.insert(.abort)
        dma.controlStatus.insert(.reset)
        dma.debug.insert([ .readError, .fifoError, .readLastNotSetError ])

        // Set the DCC GPIO for PWM output.
        var gpio = raspberryPi.gpio(number: Driver.dccGpio)
        gpio.function = .alternateFunction5
        
        // Set the RailCom GPIO for output and clear.
        gpio = raspberryPi.gpio(number: Driver.railComGpio)
        gpio.function = .output
        gpio.value = false
        
        // Set the debug GPIO for output and clear.
        gpio = raspberryPi.gpio(number: Driver.debugGpio)
        gpio.function = .output
        gpio.value = false
        
        // Enable the PWM, using the FIFO in serializer mode, and DREQ signals sent to the DMA Engine.
        pwm.dmaConfiguration = [ .enabled, .dreqThreshold(1), .panicThreshold(1) ]
        pwm.control = [ .channel1UseFifo, .channel1SerializerMode, .channel1Enable ]
        
        // Set the DMA Engine priority levels.
        dma.controlStatus = [ .priorityLevel(8), .panicPriorityLevel(8) ]
        
        isRunning = true
        DispatchQueue.global().asyncAfter(deadline: .now() + Driver.watchdogInterval, execute: watchdog)
    }
    
    /// Shutdown hardware.
    ///
    /// Disables the PWM and DMA hardware, and resets the GPIOs to a default state.
    ///
    /// It is essential that this be called before exit, as otherwise the DMA Engine will continue on its programmed sequence and endlessly repeat the last queued bitstream.
    public func shutdown() {
        // Disable the PWM channel.
        var pwm = raspberryPi.pwm()
        pwm.control.remove(.channel1Enable)
        pwm.dmaConfiguration.remove(.enabled)

        // Stop the clock.
        var clock = raspberryPi.clock(identifier: Driver.clockIdentifier)
        clock.disable()

        // Stop the DMA Engine.
        var dma = raspberryPi.dma(channel: Driver.dmaChannel)
        dma.controlStatus.remove(.active)
        dma.controlStatus.insert(.abort)

        // Clear the bitstream queue to free the uncached memory associated with each bitstream, also cancel any pending tasks and wait for them to ensure blocks aren't holding references as well.
        isRunning = false
        dispatchGroup.wait()
        dispatchQueue.sync() {
            bitstreamQueue.removeAll()
        }
        
        // Restore the DCC GPIO to output, and clear all pins.
        var gpio = raspberryPi.gpio(number: Driver.dccGpio)
        gpio.function = .output
        gpio.value = false
        
        gpio = raspberryPi.gpio(number: Driver.railComGpio)
        gpio.value = false
        
        gpio = raspberryPi.gpio(number: Driver.debugGpio)
        gpio.value = false
    }
    
    /// Indicates whether the next queued bitstream will require powering on.
    ///
    /// This is set to `false` when a `powerOnBitstream` is queued, and `true` when a `powerOffBitstream` is queued.
    var requiresPowerOn = true
    
    /// Queue bitstream.
    ///
    /// - Parameters:
    ///   - bitstream: DCC Bitstream to be queued.
    ///   - repeating: when `false` the bitstream will not be repeated.
    ///   - completionHandler: Optional block to be run once `bitstream` has been transmitted at least once.
    ///
    /// - Throws:
    ///   Errors from `DriverError`, `MailboxError`, and `RaspberryPiError` on failure.
    public func queue(bitstream: Bitstream, repeating: Bool = true, completionHandler: (() -> Void)? = nil) throws {
        print("Bitstream duration \(bitstream.duration)µs")
        try dispatchQueue.sync {
            var dma = raspberryPi.dma(channel: Driver.dmaChannel)
            let dmaActive = dma.controlStatus.contains(.active)

            var activateBitstream: QueuedBitstream? = nil
            if requiresPowerOn {
                activateBitstream = try queue(bitstream: powerOnBitstream, repeating: false, removePreviousBitstream: !bitstreamQueue.isEmpty, removeThisBitstream: false)
                requiresPowerOn = false
            }
            
            try queue(bitstream: bitstream, repeating: repeating, removePreviousBitstream: true, removeThisBitstream: false, completionHandler: completionHandler)
            
            if !repeating {
                requiresPowerOn = true
                try queue(bitstream: powerOffBitstream, repeating: false, removePreviousBitstream: true, removeThisBitstream: true)
            }
            
            // Activate the DMA if this is the first bitstream in the queue.
            if !dmaActive {
                dma.controlBlockAddress = activateBitstream!.busAddress
                dma.controlStatus.insert(.active)
            }
        }
    }
    
    /// Queue a single bitstream.
    ///
    /// Internal function used by `queue(bitstream:)` to queue a single bitstream, this must be run on `dispatchQueue`.
    ///
    /// - Parameters:
    ///   - bitstream: bitstream to be queued.
    ///   - repeating: when `false` the bitstream will not be repeated.
    ///   - removePreviousBitstream: when `true` the previous bitstream in the queue should be removed, this should be set for all but the first bitstream in the queue.
    ///   - removeThisBitstream: when `true` this bitstream will be removed from the queue, this should be set for only the last bitstream in the queue and will be ignored if the DMA Channel is still active.
    ///   - completionHandler: Optional block to be run once `bitstream` has been transmitted at least once.
    ///
    /// - Returns: copy of the bitstream queued.
    ///
    /// - Throws:
    ///   Errors from `DriverError`, `MailboxError`, and `RaspberryPiError` on failure.
    @discardableResult
    func queue(bitstream: Bitstream, repeating: Bool, removePreviousBitstream: Bool, removeThisBitstream: Bool, completionHandler: (() -> Void)? = nil) throws -> QueuedBitstream {
        if #available(OSX 10.12, *) {
            dispatchPrecondition(condition: .onQueue(dispatchQueue))
        }

        // Generate the new bitstream based on transferring from the breakpoints of the last one.
        var queuedBitstream = QueuedBitstream(raspberryPi: raspberryPi)
        if let previousBitstream = bitstreamQueue.last {
            let transferOffsets = try queuedBitstream.transfer(from: previousBitstream, into: bitstream, repeating: repeating)
            try queuedBitstream.commit()
            previousBitstream.transfer(to: queuedBitstream, at: transferOffsets)
        } else {
            try queuedBitstream.parseBitstream(bitstream, repeating: repeating)
            try queuedBitstream.commit()
        }
        
        // Once the new bitstream is transmitting, remove the first one from the queue... strictly speaking this isn't necessarily the one we were transmitting just now, but it doesn't matter as long as this is called the right number of times by all the queued blocks—we'll ultimately end up with just queuedBitstream in the queue.
        whenTransmitting(queuedBitstream) {
            if removePreviousBitstream {
                self.bitstreamQueue.remove(at: 0)
            }
            
            // Wait for the transmission of the bistream to be complete; the extra delay here isn't necessary but it saves on unnecessary repeated checking since we actually know off-hand what the duration should be.
            self.whenRepeating(queuedBitstream, after: .microseconds(Int(bitstream.duration))) {
                if removeThisBitstream {
                    // We only remove ourselves if the DMA Channel has gone inactive; if it's still active, that means our next control block address was changed to point at another bitstream, which will remove us in its own whenTransmitting above.
                    var dma = self.raspberryPi.dma(channel: Driver.dmaChannel)
                    if !dma.controlStatus.contains(.active) {
                        self.bitstreamQueue.remove(at: 0)
                    }
                }
                
                // If there's a completion handler, run it.
                if let completionHandler = completionHandler {
                    DispatchQueue.global().async(execute: completionHandler)
                }
            }
        }

        // Append the bitstream to the queue. This has to come last since it's a value type and we want the queued copy to include the parsing.
        bitstreamQueue.append(queuedBitstream)
        debugPrint(queuedBitstream)
        print()
        
        return queuedBitstream
    }
    
    /// Interval between bitstream state checks.
    ///
    /// We use a repeated dispatch block of this interval, rather than a loop/sleep, to allow interleaving of checks for multiple queued bitstreams.
    static let bitstreamCheckInterval: DispatchTimeInterval = .milliseconds(1)

    /// Executes a block once a queued bitstream is transmitting.
    ///
    /// This must be called on `dispatchQueue`. May execute immediately, otherwise schedules regular checks.
    ///
    /// - Parameters:
    ///   - queuedBitstream: bitstream to wait for transmission to begin.
    ///   - work: block to execute.
    func whenTransmitting(_ queuedBitstream: QueuedBitstream, execute work: @escaping () -> Void) {
        if #available(OSX 10.12, *) {
            dispatchPrecondition(condition: .onQueue(dispatchQueue))
        }

        // Bail out if the Driver is no longer running. Otherwise if the bitstream isn't transmitting yet, schedule another call to ourselves after an interval; continuing the capture of queuedBitstream and self.
        guard isRunning else { return }
        guard queuedBitstream.isTransmitting else {
            dispatchGroup.enter()
            dispatchQueue.asyncAfter(deadline: .now() + Driver.bitstreamCheckInterval) {
                self.whenTransmitting(queuedBitstream, execute: work)
                self.dispatchGroup.leave()
            }
            return
        }
        
        work()
    }
    
    /// Executes a block once a queued bitstream has begun repeating.
    ///
    /// This must be called on `dispatchQueue`. May execute immediately, otherwise schedules a check after `delay`, and then at regular intervals afterwards.
    ///
    /// - Parameters:
    ///   - queuedBitstream: bitstream to wait for transmission to repeat.
    ///   - delay: initial delay to wait if not already repeating, only used for first check.
    ///   - work: block to execute.
    func whenRepeating(_ queuedBitstream: QueuedBitstream, after delay: DispatchTimeInterval = Driver.bitstreamCheckInterval, execute work: @escaping () -> Void) {
        if #available(OSX 10.12, *) {
            dispatchPrecondition(condition: .onQueue(dispatchQueue))
        }

        // Bail out if the Driver is no longer running. Otherwise if the bitstream isn't repeating yet, schedule another call to ourselves after an interval; continuing the capture of queuedBitstream and self.
        guard isRunning else { return }
        guard queuedBitstream.isRepeating else {
            dispatchGroup.enter()
            dispatchQueue.asyncAfter(deadline: .now() + delay) {
                self.whenRepeating(queuedBitstream, execute: work)
                self.dispatchGroup.leave()
            }
            return
        }
        
        work()
    }
    
    /// Returns a bitstream that will power on the tracks and prime the FIFO so that future PWM and GPIO events will be aligned.
    var powerOnBitstream: Bitstream {
        var bitstream = Bitstream(bitDuration: bitDuration)

        for _ in 0..<Driver.eventDelay {
            bitstream.append(.data(word: 0, size: bitstream.wordSize))
        }

        bitstream.append(.railComCutoutEnd)
        
        return bitstream
    }
    
    /// Returns a bitstream that will power off the tracks and leave the queue in a clean state.
    var powerOffBitstream: Bitstream {
        var bitstream = Bitstream(bitDuration: bitDuration)
        
        bitstream.append(.railComCutoutStart)
        bitstream.append(.debugEnd)
        
        for _ in 0..<Driver.eventDelay {
            bitstream.append(.data(word: 0, size: bitstream.wordSize))
        }
        
        return bitstream
    }
    
    /// Stop the Driver gracefully.
    ///
    /// The currently transmitting bitstream is completed if not already repeating, and then transferred out at the next breakpoint with delayed events cleared as normal. Both the RailCom and Debug GPIO pins are cleared.
    ///
    /// - Parameters:
    ///   - completionHandler: block to execute once the stop has completed.
    public func stop(completionHandler: @escaping () -> Void) throws {
        try dispatchQueue.sync {
            if requiresPowerOn {
                DispatchQueue.global().async(execute: completionHandler)
            } else {
                requiresPowerOn = true
                try queue(bitstream: powerOffBitstream, repeating: false, removePreviousBitstream: true, removeThisBitstream: true, completionHandler: completionHandler)
            }
        }
    }

    
    /// Interval between watchdog checks.
    static let watchdogInterval: DispatchTimeInterval = .milliseconds(10)

    /// Checks for and clears PWM and DMA error states.
    func watchdog() {
        guard self.isRunning else { return }

        var pwm = raspberryPi.pwm()
        if pwm.status.contains(.busError) {
            // Always seems to be set, and doesn't go away *shrug*
            //print("PWM Bus Error")
            pwm.status.insert(.busError)
        }
        
        if pwm.status.contains(.fifoReadError) {
            print("PWM FIFO Read Error")
            pwm.status.insert(.fifoReadError)
        }
        
        if pwm.status.contains(.fifoWriteError) {
            print("PWM FIFO Write Error")
            pwm.status.insert(.fifoWriteError)
        }
        
        if pwm.status.contains(.channel1GapOccurred) {
            print("PWM Channel 1 Gap Occurred")
            pwm.status.insert(.channel1GapOccurred)
        }
        
        if pwm.status.contains(.fifoEmpty) {
            // Doesn't seem to be an issue, unless maybe we get a gap as above?
            //print("PWM FIFO Empty")
        }
        
        var dma = raspberryPi.dma(channel: Driver.dmaChannel)
        
        if dma.controlStatus.contains(.errorDetected) {
            print("DMA Error Detected:")
        }
        
        if dma.debug.contains(.readError) {
            print("DMA Read Error")
            dma.debug.insert(.readError)
        }
        
        if dma.debug.contains(.fifoError) {
            print("DMA FIFO Error")
            dma.debug.insert(.fifoError)
        }
        
        if dma.debug.contains(.readLastNotSetError) {
            print("DMA Read Last Not Set Error")
            dma.debug.insert(.readLastNotSetError)
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + Driver.watchdogInterval, execute: watchdog)
    }

}
