import SwiftUI

struct WorkoutDevicesSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var workoutDevices: SettingsWorkoutDevices

    var body: some View {
        Form {
            Section {
                VStack {
                    HCenter {
                        IntegrationImageView(imageName: "HeartRateDevice", height: 80)
                        IntegrationImageView(imageName: "HeartRateDeviceCoros", height: 80)
                    }
                    IntegrationImageView(imageName: "CyclingPowerDevice", height: 80)
                }
            }
            Section {
                List {
                    ForEach(workoutDevices.devices) { device in
                        WorkoutDeviceSettingsView(model: model,
                                                  workoutDevices: workoutDevices,
                                                  device: device,
                                                  status: model.statusTopRight)
                            .contextMenuDeleteButton {
                                model.removeWorkoutDevice(device: device)
                            }
                    }
                    .onDelete { offsets in
                        let devices = offsets.map { workoutDevices.devices[$0] }
                        for device in devices {
                            model.removeWorkoutDevice(device: device)
                        }
                    }
                }
                CreateButtonView {
                    let device = SettingsWorkoutDevice()
                    device.name = makeUniqueName(name: SettingsWorkoutDevice.baseName,
                                                 existingNames: workoutDevices.devices)
                    workoutDevices.devices.append(device)
                }
            } footer: {
                SwipeLeftToDeleteHelpView(kind: String(localized: "a device"))
            }
        }
        .navigationTitle("Workout devices")
    }
}
