import SwiftUI
import CoreBluetooth

struct HomeView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var isScanning = false
    @State private var isShowingConnectButton = true
    @State private var showPeripheralsList = false
    @State private var showingDeviceSelection = false
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedPeripheral: CBPeripheral?
    @Binding var selectedTab: Int

    var body: some View {
        NavigationView {
            VStack {
                if let connectedPeripheral = bleManager.connectedPeripheral {
                    SensorDataView(bleManager: bleManager, peripheral: connectedPeripheral)
                } else {
                    if isShowingConnectButton {
                        VStack {
                            Button(action: {
                                isShowingConnectButton = false
                                bleManager.startScan()
                                isScanning = true
                                showingDeviceSelection = true
                            }) {
                                Text("Connect Device")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                            }
                            .padding()
                            .buttonStyle(.borderedProminent)
                            .disabled(!bleManager.isBluetoothEnabled)

                            Text("Click 'Connect Device' to start scanning for nearby devices.")
                                .font(.footnote)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                }

                Spacer()

                if !bleManager.isBluetoothEnabled {
                    Text("Bluetooth is disabled. Please enable it in settings.")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            .navigationTitle("Home")
            .onAppear {
                if bleManager.connectedPeripheral == nil {
                    isShowingConnectButton = true
                    showPeripheralsList = false // Hide the list initially
                } else {
                    bleManager.startScan()
                    isScanning = true
                    showPeripheralsList = true // Show the list if already connected
                }
            }
            .onDisappear {
                bleManager.stopScan()
                isScanning = false
            }
            .sheet(isPresented: $showingDeviceSelection) {
                DeviceSelectionView(bleManager: bleManager, isPresented: $showingDeviceSelection, selectedTab: $selectedTab)
            }
        }
    }
}
