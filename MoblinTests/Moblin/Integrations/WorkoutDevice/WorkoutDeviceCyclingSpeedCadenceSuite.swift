import Foundation
@testable import Moblin
import Testing

private func crankMeasurement(revolutions: UInt16, eventTime: UInt16) -> Data {
    var data = Data([0x02])
    data.append(contentsOf: withUnsafeBytes(of: revolutions.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: eventTime.littleEndian) { Array($0) })
    return data
}

private func wheelMeasurement(revolutions: UInt32, eventTime: UInt16) -> Data {
    var data = Data([0x01])
    data.append(contentsOf: withUnsafeBytes(of: revolutions.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: eventTime.littleEndian) { Array($0) })
    return data
}

private func wheelAndCrankMeasurement(wheelRevolutions: UInt32,
                                      wheelEventTime: UInt16,
                                      crankRevolutions: UInt16,
                                      crankEventTime: UInt16) -> Data
{
    var data = Data([0x03])
    data.append(contentsOf: withUnsafeBytes(of: wheelRevolutions.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: wheelEventTime.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: crankRevolutions.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: crankEventTime.littleEndian) { Array($0) })
    return data
}

struct WorkoutDeviceCyclingSpeedCadenceSuite {
    @Test
    func speedExpiresWithoutAnotherPacket() {
        let now = ContinuousClock.now
        let sample = WorkoutDeviceCyclingSpeedSample(speed: 10, time: now)
        #expect(sample.value(now: now.advanced(by: .seconds(2))) == 10)
        #expect(sample.value(now: now.advanced(by: .seconds(3))) == 0)
        #expect(sample.value(now: now.advanced(by: .seconds(60))) == 0)
    }

    @Test
    func distanceStartsAtZeroAndSurvivesReconnect() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        let (_, _, initialDistance) = try device.handleMeasurement(value: wheelMeasurement(
            revolutions: 50000,
            eventTime: 1024
        ))
        #expect(initialDistance == 0)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 50005, eventTime: 2048))
        #expect(device.distanceMeters == 10)
        device.resetMeasurements()
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 2, eventTime: 1024))
        #expect(device.distanceMeters == 10)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 3, eventTime: 2048))
        #expect(device.distanceMeters == 12)
        device.reset(preserveDistance: true)
        #expect(device.distanceMeters == 12)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 3, eventTime: 2048))
        #expect(device.distanceMeters == 12)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 4, eventTime: 3072))
        #expect(device.distanceMeters == 14)
        device.reset()
        #expect(device.distanceMeters == 0)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 5000, eventTime: 4096))
        #expect(device.distanceMeters == 0)
    }

    @Test(arguments: [false, true])
    func recoversDisconnectedDistanceWithoutSpeedSpike(backgroundStop: Bool) throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        let now = ContinuousClock.now
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 100, eventTime: 0), now: now)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 105, eventTime: 1024),
                                         now: now.advanced(by: .seconds(1)))
        if backgroundStop {
            device.reset(preserveDistance: true)
        } else {
            device.resetMeasurements()
        }
        let resumed = try device.handleMeasurement(
            value: wheelMeasurement(revolutions: 1605, eventTime: 1024),
            now: now.advanced(by: .seconds(301))
        )
        #expect(resumed.distance == 3010)
        #expect(resumed.speed == 0)
        let next = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1610, eventTime: 2048),
                                                now: now.advanced(by: .seconds(302)))
        #expect(next.distance == 3020)
        #expect(next.speed == 10)
    }

    @Test(arguments: [64, 65, 300])
    func distanceDoesNotDependOnShortEventTimer(seconds: Int) throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        let now = ContinuousClock.now
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 100, eventTime: 1024), now: now)
        let result = try device.handleMeasurement(
            value: wheelMeasurement(revolutions: UInt32(100 + 5 * seconds),
                                    eventTime: UInt16(truncatingIfNeeded: 1024 + seconds * 1024)),
            now: now.advanced(by: .seconds(seconds))
        )
        #expect(result.distance == Double(10 * seconds))
        #expect(result.speed == 0)
    }

    @Test
    func rejectsResetDuringDisconnectAndAcceptsFollowingRevolutions() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        let now = ContinuousClock.now
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1000, eventTime: 0), now: now)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1005, eventTime: 1024),
                                         now: now.advanced(by: .seconds(1)))
        device.reset(preserveDistance: true)
        let resumed = try device.handleMeasurement(value: wheelMeasurement(revolutions: 0, eventTime: 0),
                                                   now: now.advanced(by: .seconds(301)))
        #expect(resumed.distance == 10)
        #expect(resumed.speed == 0)
        let next = try device.handleMeasurement(value: wheelMeasurement(revolutions: 5, eventTime: 1024),
                                                now: now.advanced(by: .seconds(302)))
        #expect(next.distance == 20)
        #expect(next.speed == 10)
    }

    @Test
    func counterWrapDuringDisconnectAddsDistanceOnlyOnce() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        let now = ContinuousClock.now
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: .max - 4, eventTime: 65000),
                                         now: now)
        device.resetMeasurements()
        let packet = wheelMeasurement(revolutions: 5, eventTime: 65000)
        let resumed = try device.handleMeasurement(value: packet, now: now.advanced(by: .seconds(64)))
        #expect(resumed.distance == 20)
        #expect(resumed.speed == 0)
        _ = try device.handleMeasurement(value: packet, now: now.advanced(by: .seconds(65)))
        #expect(device.distanceMeters == 20)
    }

    @Test
    func rejectsImplausibleForwardCounterJump() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        let now = ContinuousClock.now
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 100, eventTime: 0), now: now)
        let result = try device.handleMeasurement(
            value: wheelMeasurement(revolutions: 100_000, eventTime: 1024),
            now: now.advanced(by: .seconds(1))
        )
        #expect(result.distance == 0)
        #expect(result.speed == 0)
    }

    @Test
    func rejectsCounterResetAndResumesFromNewBaseline() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1000, eventTime: 1024))
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1001, eventTime: 2048))
        let (speed, _, _) = try device.handleMeasurement(value: wheelMeasurement(
            revolutions: 0,
            eventTime: 3072
        ))
        #expect(speed == 0)
        #expect(device.distanceMeters == 2)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1, eventTime: 4096))
        #expect(device.distanceMeters == 4)
    }

    @Test
    func distanceHandlesRolloverAndWheelSizeChanges() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2000)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: .max, eventTime: 65000))
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 0, eventTime: 488))
        #expect(device.distanceMeters == 2)
        device.setWheelCircumference(millimeters: 2500)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 1, eventTime: 1512))
        #expect(device.distanceMeters == 4.5)
    }

    @Test
    func firstMeasurementOnlySeedsState() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        let (speed, cadence, distance) = try device.handleMeasurement(value: crankMeasurement(
            revolutions: 10,
            eventTime: 1024
        ))
        #expect(cadence == nil)
        #expect(speed == nil)
        #expect(distance == nil)
    }

    @Test
    func calculatesCadenceFromCrankRevolutions() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        _ = try device.handleMeasurement(value: crankMeasurement(revolutions: 10, eventTime: 1024))
        let (_, cadence, _) = try device.handleMeasurement(value: crankMeasurement(
            revolutions: 13,
            eventTime: 1024 + 2048
        ))
        #expect(cadence == 90)
    }

    @Test
    func handlesCrankRevolutionsWrapAround() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        _ = try device.handleMeasurement(value: crankMeasurement(revolutions: 65535, eventTime: 65000))
        let (_, cadence, _) = try device.handleMeasurement(value: crankMeasurement(
            revolutions: 0,
            eventTime: 65000 &+ 1024
        ))
        #expect(cadence == 60)
    }

    @Test
    func ignoresMeasurementWithoutTimeProgress() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        _ = try device.handleMeasurement(value: crankMeasurement(revolutions: 10, eventTime: 1024))
        _ = try device.handleMeasurement(value: crankMeasurement(revolutions: 11, eventTime: 1024 + 1024))
        let (_, cadence, _) = try device.handleMeasurement(value: crankMeasurement(
            revolutions: 11,
            eventTime: 1024 + 1024
        ))
        #expect(cadence == 60)
    }

    @Test
    func cadenceOnlySensorReportsNoSpeed() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        _ = try device.handleMeasurement(value: crankMeasurement(revolutions: 10, eventTime: 1024))
        let (speed, cadence, _) = try device.handleMeasurement(value: crankMeasurement(
            revolutions: 11,
            eventTime: 1024 + 1024
        ))
        #expect(cadence == 60)
        #expect(speed == nil)
    }

    @Test
    func speedOnlySensorReportsNoCadence() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        device.setWheelCircumference(millimeters: 2000)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: 100, eventTime: 1024))
        let (speed, cadence, distance) = try device.handleMeasurement(value: wheelMeasurement(
            revolutions: 105,
            eventTime: 1024 + 1024
        ))
        #expect(cadence == nil)
        #expect(try isEqual(#require(speed), 10, epsilon: 0.001))
        #expect(try isEqual(#require(distance), 10, epsilon: 0.001))
    }

    @Test
    func calculatesSpeedAndCadenceFromCombinedMeasurement() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        device.setWheelCircumference(millimeters: 2000)
        _ = try device.handleMeasurement(value: wheelAndCrankMeasurement(wheelRevolutions: 100,
                                                                         wheelEventTime: 1024,
                                                                         crankRevolutions: 10,
                                                                         crankEventTime: 1024))
        let (speed, cadence, distance) = try device.handleMeasurement(value: wheelAndCrankMeasurement(
            wheelRevolutions: 105,
            wheelEventTime: 1024 + 1024,
            crankRevolutions: 11,
            crankEventTime: 1024 + 1024
        ))
        #expect(cadence == 60)
        #expect(try isEqual(#require(speed), 10, epsilon: 0.001))
        #expect(try isEqual(#require(distance), 10, epsilon: 0.001))
    }

    @Test
    func handlesWheelRevolutionsWrapAround() throws {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        device.setWheelCircumference(millimeters: 2000)
        _ = try device.handleMeasurement(value: wheelMeasurement(revolutions: .max, eventTime: 1024))
        let (speed, _, _) = try device.handleMeasurement(value: wheelMeasurement(
            revolutions: 4,
            eventTime: 1024 + 1024
        ))
        #expect(try isEqual(#require(speed), 10, epsilon: 0.001))
    }

    @Test
    func rejectsTruncatedMeasurement() {
        let device = WorkoutDeviceCyclingSpeedCadence(wheelCircumference: 2105)
        #expect(throws: (any Error).self) {
            try device.handleMeasurement(value: Data([0x02, 0x01]))
        }
    }
}

struct WorkoutDeviceCyclingMetricsStoreSuite {
    @Test
    func genericMetricsKeepTheSameSensorAcrossDisconnects() {
        var store = WorkoutDeviceCyclingMetricsStore()
        let first = UUID()
        let second = UUID()
        store.update(deviceId: first, speed: 10, distance: 100)
        store.update(deviceId: second, speed: 20, distance: 900)
        #expect(store.distance == 100)
        store.disconnect(deviceId: first)
        store.update(deviceId: second, speed: 20, distance: 920)
        #expect(store.distance == 100)
        #expect(store.speed == 0)
        store.update(deviceId: first, speed: 0, distance: 120)
        #expect(store.distance == 120)
        store.remove(deviceId: first)
        #expect(store.distance == 0)
        store.update(deviceId: second, speed: 20, distance: 940)
        #expect(store.distance == 940)
    }

    @Test
    func cadenceOnlySensorDoesNotBecomeGenericSource() {
        var store = WorkoutDeviceCyclingMetricsStore()
        store.update(deviceId: UUID(), speed: nil, distance: nil)
        store.update(deviceId: UUID(), speed: 10, distance: 100)
        #expect(store.distance == 100)
    }

    @Test
    func renamedSensorKeepsDistanceWithoutLeavingStaleNames() {
        var store = WorkoutDeviceCyclingMetricsStore()
        let id = UUID()
        let now = ContinuousClock.now
        store.update(deviceId: id, speed: 10, distance: 100, now: now)
        #expect(store.metricsByName(devices: [(id, "Old")], now: now)["old"]?.distance == 100)
        let renamed = store.metricsByName(devices: [(id, "New")], now: now)
        #expect(renamed["new"]?.distance == 100)
        #expect(renamed["old"] == nil)
        #expect(store.metricsByName(devices: [], now: now).isEmpty)
        store.remove(deviceId: id)
        #expect(store.metricsByName(devices: [(id, "New")], now: now).isEmpty)
    }

    @Test
    func ambiguousNamesDoNotMixSensors() {
        var store = WorkoutDeviceCyclingMetricsStore()
        let first = UUID()
        let second = UUID()
        let now = ContinuousClock.now
        store.update(deviceId: first, speed: 10, distance: 100, now: now)
        store.update(deviceId: second, speed: 20, distance: 900, now: now)
        #expect(store.metricsByName(devices: [(first, "Bike"), (second, "bike")], now: now).isEmpty)
        let renamed = store.metricsByName(devices: [(first, "Bike"), (second, "Other")], now: now)
        #expect(renamed["bike"]?.distance == 100)
        #expect(renamed["other"]?.distance == 900)
    }

    @Test
    func speedExpiresButDistanceSurvivesDisconnect() {
        var store = WorkoutDeviceCyclingMetricsStore()
        let id = UUID()
        let now = ContinuousClock.now
        store.update(deviceId: id, speed: 10, distance: 100, now: now)
        let stale = store.metricsByName(devices: [(id, "Bike")], now: now.advanced(by: .seconds(3)))
        #expect(stale["bike"]?.speed == 0)
        #expect(stale["bike"]?.distance == 100)
        store.disconnect(deviceId: id)
        let disconnected = store.metricsByName(devices: [(id, "Bike")], now: now)
        #expect(disconnected["bike"]?.speed == nil)
        #expect(disconnected["bike"]?.distance == 100)
    }
}
