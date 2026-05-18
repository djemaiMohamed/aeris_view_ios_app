import SwiftUI
import CoreBluetooth

struct DevicePairingView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var isScanning = false
    var autoStartScan: Bool = false
    var onEnableDemoMode: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)

                    Text("Pair Aeris View")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text("Make sure your sensor is in pairing mode and nearby.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 40)

                // Connection status banner — shown while a connect attempt is in flight
                if bleManager.isConnecting, let target = bleManager.connectingPeripheral {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waiting for device to respond…")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(target.name ?? "Unknown Device")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.25), value: bleManager.isConnecting)
                }

                // Device List
                if bleManager.peripherals.isEmpty && !isScanning {
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)

                        Text("No devices found")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("Tap scan to search for Aeris View devices")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if bleManager.peripherals.isEmpty && isScanning {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Scanning for devices...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    if isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Scanning for more devices...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }

                    List {
                        ForEach(bleManager.peripherals, id: \.identifier) { peripheral in
                            DeviceRow(
                                peripheral: peripheral,
                                isThisConnecting: bleManager.connectingPeripheral?.identifier == peripheral.identifier,
                                isAnyConnecting: bleManager.isConnecting,
                                onTap: {
                                    bleManager.connect(peripheral: peripheral)
                                },
                                bleManager: bleManager
                            )
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }

                Spacer()

                // Scan Button
                Button(action: {
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    } else {
                        bleManager.startScan()
                        isScanning = true

                        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                            if isScanning {
                                bleManager.stopScan()
                                isScanning = false
                            }
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: isScanning ? "stop.circle.fill" : "magnifyingglass")
                        Text(isScanning ? "Stop Scanning" : "Scan for Devices")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isScanning ? Color.red : Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Button("Continue in Demo Mode") {
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    }
                    onEnableDemoMode?()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .navigationBarHidden(true)
            .onAppear {
                if autoStartScan && !isScanning {
                    bleManager.startScan()
                    isScanning = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        if isScanning {
                            bleManager.stopScan()
                            isScanning = false
                        }
                    }
                }
            }
            .onDisappear {
                if isScanning {
                    bleManager.stopScan()
                    isScanning = false
                }
            }
            .onChange(of: bleManager.connectedPeripheral) { newValue in
                if newValue != nil {
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DeviceRow: View {
    let peripheral: CBPeripheral
    let isThisConnecting: Bool
    let isAnyConnecting: Bool
    let onTap: () -> Void
    @ObservedObject var bleManager: BLEManager

    var deviceName: String {
        bleManager.customDeviceNames[peripheral.identifier.uuidString]
            ?? peripheral.name
            ?? "Unknown Device"
    }

    var body: some View {
        HStack(spacing: 14) {
            // Device icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "sensor.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 20))
            }

            // Device info
            VStack(alignment: .leading, spacing: 3) {
                Text(deviceName)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(peripheral.identifier.uuidString.prefix(8) + "…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action area
            if isThisConnecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("Waiting…")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1))
            } else {
                Button(action: onTap) {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.caption.weight(.semibold))
                        Text("Connect")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isAnyConnecting ? Color.gray.opacity(0.5) : Color.blue)
                    .clipShape(Capsule())
                }
                .disabled(isAnyConnecting)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

#Preview {
    DevicePairingView(bleManager: BLEManager())
}
