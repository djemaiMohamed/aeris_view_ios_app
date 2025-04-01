import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @ObservedObject var bleManager = BLEManager()
    @State private var isScanning = false

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(bleManager.peripherals, id: \.identifier) { peripheral in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peripheral.name ?? "Unknown Device")
                                if peripheral.state == .connected {
                                    Text("Connected")
                                        .foregroundColor(.green)
                                } else {
                                    Text("Disconnected")
                                        .foregroundColor(.red)
                                }
                            }
                            Spacer()
                            Button(action: {
                                if peripheral.state == .connected {
                                    bleManager.disconnect(peripheral: peripheral)
                                } else {
                                    bleManager.connect(peripheral: peripheral)
                                }
                            }) {
                                Text(peripheral.state == .connected ? "Disconnect" : "Connect")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!bleManager.isBluetoothEnabled)
                            NavigationLink(destination: DeviceDetailView(bleManager: bleManager, peripheral: peripheral)) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.title3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button(action: {
                    if isScanning {
                        bleManager.stopScan()
                    } else {
                        bleManager.startScan()
                    }
                    isScanning.toggle()
                }) {
                    Text(isScanning ? "Stop Scan" : "Start Scan")
                }
                .padding()
                .disabled(!bleManager.isBluetoothEnabled)
                
                if !bleManager.isBluetoothEnabled {
                    Text("Bluetooth is disabled. Please enable it in settings.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .navigationTitle("BLE Devices")
            .onAppear {
                bleManager.startScan()
                isScanning = true
            }
            .onDisappear {
                bleManager.stopScan()
                isScanning = false
            }
        }
    }
}
