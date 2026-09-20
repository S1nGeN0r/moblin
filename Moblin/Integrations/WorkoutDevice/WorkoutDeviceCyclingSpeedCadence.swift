import CoreBluetooth
import Foundation

nonisolated(unsafe) let workoutDeviceCyclingSpeedCadenceServiceId = CBUUID(string: "1816")
nonisolated(unsafe) let workoutDeviceCyclingSpeedCadenceMeasurementCharacteristicId = CBUUID(string: "2A5B")

private let measurementWheelRevolutionDataFlagIndex = 0
private let measurementCrankRevolutionDataFlagIndex = 1
private let maximumCyclingSpeedMetersPerSecond = 100.0

struct WorkoutDeviceCyclingSpeedSample {
    let speed: Double
    let time: ContinuousClock.Instant

    func value(now: ContinuousClock.Instant = .now) -> Double {
        time.duration(to: now) < .seconds(3) ? speed : 0
    }
}

struct WorkoutDeviceCyclingMetrics: Codable, Equatable {
    var speed: Double?
    var distance: Double?
}

struct WorkoutDeviceCyclingMetricsStore {
    private var metrics: [UUID: WorkoutDeviceCyclingMetrics] = [:]
    private var speedSamples: [UUID: WorkoutDeviceCyclingSpeedSample] = [:]
    private var selectedDeviceId: UUID?

    var speed: Double {
        selectedDeviceId.flatMap { speedSamples[$0]?.value() } ?? 0
    }

    var distance: Double {
        selectedDeviceId.flatMap { metrics[$0]?.distance } ?? 0
    }

    mutating func update(deviceId: UUID, speed: Double?, distance: Double?,
                         now: ContinuousClock.Instant = .now)
    {
        guard speed != nil || distance != nil else {
            return
        }
        if selectedDeviceId == nil {
            selectedDeviceId = deviceId
        }
        var value = metrics[deviceId] ?? .init()
        if let speed {
            speedSamples[deviceId] = WorkoutDeviceCyclingSpeedSample(speed: speed, time: now)
            value.speed = speed
        }
        if let distance {
            value.distance = distance
        }
        metrics[deviceId] = value
    }

    mutating func disconnect(deviceId: UUID) {
        speedSamples.removeValue(forKey: deviceId)
        metrics[deviceId]?.speed = nil
    }

    mutating func remove(deviceId: UUID) {
        disconnect(deviceId: deviceId)
        metrics.removeValue(forKey: deviceId)
        if selectedDeviceId == deviceId {
            selectedDeviceId = nil
        }
    }

    func metricsByName(devices: [(id: UUID, name: String)], now: ContinuousClock.Instant)
        -> [String: WorkoutDeviceCyclingMetrics]
    {
        var result: [String: WorkoutDeviceCyclingMetrics] = [:]
        let devicesByName = Dictionary(grouping: devices, by: { $0.name.lowercased() })
        for (name, devices) in devicesByName {
            // Old imports may contain case-insensitive duplicates. Never pick an arbitrary sensor.
            guard devices.count == 1, let device = devices.first, var value = metrics[device.id] else {
                continue
            }
            value.speed = speedSamples[device.id]?.value(now: now)
            result[name] = value
        }
        return result
    }
}

private struct CyclingSpeedCadenceMeasurement {
    var cumulativeWheelRevolutions: UInt32?
    var lastWheelEventTime: UInt16?
    var cumulativeCrankRevolutions: UInt16?
    var lastCrankEventTime: UInt16?

    init(value: Data) throws {
        let reader = ByteReader(data: value)
        let flags = try reader.readUInt8()
        if flags.isBitSet(index: measurementWheelRevolutionDataFlagIndex) {
            cumulativeWheelRevolutions = try reader.readUInt32Le()
            lastWheelEventTime = try reader.readUInt16Le()
        }
        if flags.isBitSet(index: measurementCrankRevolutionDataFlagIndex) {
            cumulativeCrankRevolutions = try reader.readUInt16Le()
            lastCrankEventTime = try reader.readUInt16Le()
        }
    }
}

class WorkoutDeviceCyclingSpeedCadence {
    private var measurementCharacteristic: CBCharacteristic?
    private var previousWheelRevolutions: UInt32?
    private var previousWheelRevolutionsTime: UInt16?
    private var previousWheelMeasurementTime: ContinuousClock.Instant?
    private var needsSpeedBaseline = true
    private let crankCadence = WorkoutDeviceCrankCadence()
    private let averageSpeed = WorkoutDeviceAverageCalculator()
    private var latestAverageSpeedUpdateTime = ContinuousClock.now
    private var reportsWheelRevolutions = false
    private var wheelCircumferenceMeters: Double
    private(set) var distanceMeters = 0.0

    init(wheelCircumference: Int) {
        wheelCircumferenceMeters = Double(wheelCircumference) / 1000
    }

    func reset(preserveDistance: Bool = false) {
        measurementCharacteristic = nil
        resetMeasurements()
        reportsWheelRevolutions = false
        if !preserveDistance {
            distanceMeters = 0
            previousWheelRevolutions = nil
            previousWheelRevolutionsTime = nil
            previousWheelMeasurementTime = nil
        }
    }

    func resetMeasurements() {
        // Keep the wheel counter for distance recovery, but never average speed across a disconnect.
        needsSpeedBaseline = true
        crankCadence.reset()
        averageSpeed.reset()
    }

    func setMeasurementCharacteristic(_ characteristic: CBCharacteristic) {
        measurementCharacteristic = characteristic
    }

    func isAnyCharacteristicDiscovered() -> Bool {
        measurementCharacteristic != nil
    }

    func setWheelCircumference(millimeters: Int) {
        wheelCircumferenceMeters = Double(millimeters) / 1000
    }

    func handleMeasurement(value: Data, now: ContinuousClock.Instant = .now) throws
        -> (speed: Double?, cadence: Int?, distance: Double?)
    {
        let measurement = try CyclingSpeedCadenceMeasurement(value: value)
        let cadence = crankCadence.update(revolutions: measurement.cumulativeCrankRevolutions,
                                          time: measurement.lastCrankEventTime,
                                          now: now)
        updateSpeed(measurement: measurement, now: now)
        return (reportsWheelRevolutions ? averageSpeed.averageIgnoreZeros() : nil,
                cadence,
                reportsWheelRevolutions ? distanceMeters : nil)
    }

    private func updateSpeed(measurement: CyclingSpeedCadenceMeasurement, now: ContinuousClock.Instant) {
        var speed = -1.0
        if let revolutions = measurement.cumulativeWheelRevolutions,
           let time = measurement.lastWheelEventTime
        {
            reportsWheelRevolutions = true
            if let previousWheelRevolutions, let previousWheelRevolutionsTime,
               let previousWheelMeasurementTime
            {
                let elapsed = previousWheelMeasurementTime.duration(to: now).components
                let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let distance = Double(revolutions &- previousWheelRevolutions) * wheelCircumferenceMeters
                // The event timer wraps every 64 seconds. Distance must not depend on that timer.
                // Allow one second of delivery jitter, and reject implausible counter resets/jumps.
                let validDistance = distance <= maximumCyclingSpeedMetersPerSecond * max(
                    1,
                    elapsedSeconds + 1
                )
                if validDistance {
                    distanceMeters += distance
                }
                let eventSeconds = Double(time &- previousWheelRevolutionsTime) / 1024
                if !validDistance || needsSpeedBaseline || elapsedSeconds >= 64 {
                    averageSpeed.reset()
                    speed = 0
                } else if eventSeconds > 0 {
                    let measuredSpeed = distance / eventSeconds
                    if measuredSpeed <= maximumCyclingSpeedMetersPerSecond {
                        speed = measuredSpeed
                    } else {
                        averageSpeed.reset()
                        speed = 0
                    }
                }
            }
            previousWheelRevolutions = revolutions
            previousWheelRevolutionsTime = time
            previousWheelMeasurementTime = now
            needsSpeedBaseline = false
        }
        if speed != -1.0 {
            averageSpeed.update(value: speed)
            latestAverageSpeedUpdateTime = now
        } else if latestAverageSpeedUpdateTime.duration(to: now) > .seconds(3) {
            averageSpeed.reset()
        }
    }
}
