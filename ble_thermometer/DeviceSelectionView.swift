import SwiftUI
import CoreBluetooth

struct DeviceSelectionView: View {
    @ObservedObject var bleManager: BLEManager
    @Binding var isPresented: Bool
    @Environment(\.presentationMode) var presentationMode
    @Binding var selectedTab: Int
    @State private var connectedPeripheral: CBPeripheral?

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(bleManager.peripherals, id: \.identifier) { peripheral in
                        HStack {
                            Text(peripheral.name ?? "Unknown Device")
                            Spacer()
                            if bleManager.connectedPeripheral == peripheral {
                                Text("Connected")
                                    .foregroundColor(.green)
                            } else {
                                Button("Connect") {
                                    bleManager.connect(peripheral: peripheral)
                                    connectedPeripheral = peripheral
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Device")
            .padding()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        if let connectedPeripheral = connectedPeripheral {
                            bleManager.disconnect(peripheral: connectedPeripheral)
                        }
                        isPresented = false
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if bleManager.connectedPeripheral != nil {
                            isPresented = false
                            presentationMode.wrappedValue.dismiss()
                            selectedTab = 0
                        }
                    }
                }
            }
            .onDisappear {
                bleManager.stopScan()
            }
        }
    }
}
