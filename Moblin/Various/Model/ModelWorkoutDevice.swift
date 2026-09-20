import Foundation

struct CyclingSampleInfo {
    let source: CyclingSource
    let time: ContinuousClock.Instant
}

enum CyclingSource: Int {
    case watch
    case cyclingPower
    case cyclingSpeedCadence

    func canReplace(latest: CyclingSampleInfo?) -> Bool {
        guard let latest else {
            return true
        }
        return rawValue >= latest.source.rawValue || latest.time.duration(to: .now) > .seconds(5)
    }
}

extension Model {
    func isWorkoutDeviceEnabled(device: SettingsWorkoutDevice) -> Bool {
        device.enabled
    }

    func enableWorkoutDevice(device: SettingsWorkoutDevice) {
        if !workoutDevices.keys.contains(device.id) {
            let workoutDevice = WorkoutDevice(wheelCircumference: device.wheelCircumference)
            workoutDevice.delegate = self
            workoutDevices[device.id] = workoutDevice
        }
        workoutDevices[device.id]?.start(deviceId: device.bluetoothPeripheralId)
    }

    func disableWorkoutDevice(device: SettingsWorkoutDevice) {
        workoutDevices[device.id]?.stop()
    }

    private func getWorkoutDeviceSettings(device: WorkoutDevice) -> SettingsWorkoutDevice? {
        database.workoutDevices.devices.first(where: { workoutDevices[$0.id] === device })
    }

    func setWorkoutDeviceWheelCircumference(device: SettingsWorkoutDevice) {
        workoutDevices[device.id]?.setWheelCircumference(millimeters: device.wheelCircumference)
    }

    func setCurrentWorkoutDevice(device: SettingsWorkoutDevice) {
        currentWorkoutDeviceSettings = device
        statusTopRight.workoutDeviceState = getWorkoutDeviceState(device: device)
    }

    func getWorkoutDeviceState(device: SettingsWorkoutDevice) -> WorkoutDeviceState {
        workoutDevices[device.id]?.getState() ?? .disconnected
    }

    func autoStartWorkoutDevices() {
        for device in database.workoutDevices.devices where device.enabled {
            enableWorkoutDevice(device: device)
        }
    }

    func stopWorkoutDevices() {
        for device in workoutDevices.values {
            device.stop()
        }
    }

    func isAnyWorkoutDeviceConfigured() -> Bool {
        database.workoutDevices.devices.contains(where: \.enabled)
    }

    func areAllWorkoutDevicesConnected() -> Bool {
        !workoutDevices.values.contains(where: {
            getWorkoutDeviceSettings(device: $0)?.enabled == true && $0.getState() != .connected
        })
    }

    @discardableResult
    func setCyclingPower(_ power: Int, source: CyclingSource) -> Bool {
        guard source.canReplace(latest: latestCyclingPower) else {
            return false
        }
        cyclingPower = power
        latestCyclingPower = CyclingSampleInfo(source: source, time: .now)
        return true
    }

    @discardableResult
    func setCyclingCadence(_ cadence: Int, source: CyclingSource) -> Bool {
        guard source.canReplace(latest: latestCyclingCadence) else {
            return false
        }
        cyclingCadence = cadence
        latestCyclingCadence = CyclingSampleInfo(source: source, time: .now)
        return true
    }
}

extension Model: WorkoutDeviceDelegate {
    nonisolated func workoutDeviceState(_ workoutDevice: WorkoutDevice, state: WorkoutDeviceState) {
        DispatchQueue.main.async {
            guard let device = self.getWorkoutDeviceSettings(device: workoutDevice) else {
                return
            }
            let deviceName = device.name.lowercased()
            self.heartRates.removeValue(forKey: deviceName)
            self.runningMetrics.removeValue(forKey: deviceName)
            if state != .connected {
                self.cyclingSpeedSamples.removeValue(forKey: deviceName)
                self.cyclingMetrics[deviceName]?.speed = nil
                if self.cyclingSpeedDevice === workoutDevice {
                    self.cyclingSpeedSample = nil
                }
            }
            if state == .disconnected {
                self.cyclingMetrics.removeValue(forKey: deviceName)
                if self.cyclingSpeedDevice === workoutDevice {
                    self.cyclingSpeedDevice = nil
                    self.cyclingDistance = 0
                }
            }
            if device === self.currentWorkoutDeviceSettings {
                self.statusTopRight.workoutDeviceState = state
            }
        }
    }

    nonisolated func workoutDeviceHeartRate(_ device: WorkoutDevice, heartRate: Int) {
        DispatchQueue.main.async {
            guard let device = self.getWorkoutDeviceSettings(device: device) else {
                return
            }
            self.heartRates[device.name.lowercased()] = heartRate
            self.addWorkoutHeartRate(heartRate)
        }
    }

    nonisolated func workoutDeviceCyclingPower(_: WorkoutDevice, power: Int, cadence: Int?) {
        DispatchQueue.main.async {
            if self.setCyclingPower(power, source: .cyclingPower) {
                self.addWorkoutCyclingPower(power)
            }
            if let cadence, self.setCyclingCadence(cadence, source: .cyclingPower) {
                self.addWorkoutCyclingCadence(cadence)
            }
        }
    }

    nonisolated func workoutDeviceCyclingSpeedCadence(
        _ device: WorkoutDevice,
        speed: Double?,
        cadence: Int?,
        distance: Double?
    ) {
        DispatchQueue.main.async {
            guard let settings = self.getWorkoutDeviceSettings(device: device), settings.enabled else {
                return
            }
            let deviceName = settings.name.lowercased()
            var metrics = self.cyclingMetrics[deviceName] ?? .init()
            if let cadence, self.setCyclingCadence(cadence, source: .cyclingSpeedCadence) {
                self.addWorkoutCyclingCadence(cadence)
            }
            if let speed {
                let sample = WorkoutDeviceCyclingSpeedSample(speed: speed, time: .now)
                self.cyclingSpeedSample = sample
                self.cyclingSpeedDevice = device
                self.cyclingSpeedSamples[deviceName] = sample
                metrics.speed = speed
            }
            if let distance {
                self.cyclingDistance = distance
                metrics.distance = distance
            }
            self.cyclingMetrics[deviceName] = metrics
        }
    }

    nonisolated func workoutDeviceRunningMetrics(
        _ device: WorkoutDevice,
        metrics: WorkoutDeviceRunningMetrics
    ) {
        DispatchQueue.main.async {
            guard let device = self.getWorkoutDeviceSettings(device: device) else {
                return
            }
            self.runningMetrics[device.name.lowercased()] = metrics
        }
    }
}
