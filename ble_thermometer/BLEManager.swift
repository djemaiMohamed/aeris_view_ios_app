import CoreBluetooth
import Yams

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var isBluetoothEnabled = false
    @Published var peripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    var centralManager: CBCentralManager!
    var serviceDiscoveryCompletion: (([CBService]) -> Void)?
    var readValueCompletion: [CBUUID: (String) -> Void] = [:]
    var characteristicNameCache: [CBUUID: String] = [:]

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadCharacteristicNames()
    }
    
    func getCharacteristicName(uuid: CBUUID) -> String {
        return characteristicNameCache[uuid] ?? "Unknown Characteristic"
    }

    func loadCharacteristicNames() {
        if let url = Bundle.main.url(forResource: "characteristic_uuids", withExtension: "yaml") {
            do {
                let data = try Data(contentsOf: url)
                let yamlString = String(data: data, encoding: .utf8) ?? ""
                
                do {
                    if let yaml = try Yams.load(yaml: yamlString) as? [String: Any],
                       let uuids = yaml["uuids"] as? [[String: Any]] {
                        for item in uuids {
                            if let uuidString = item["uuid"] as? Int,
                               let name = item["name"] as? String {
                                let uuidStr = String(describing: String(format: "%02X", uuidString)).replacingOccurrences(of: "0x", with: "")
                                let uuid = CBUUID(string: uuidStr)
                                characteristicNameCache[uuid] = name
                            }
                        }
                    }
                } catch {
                    print("Error parsing YAML: \(error)")
                }
            } catch {
                print("Error loading characteristic names: \(error)")
            }
        }
    }

    func startScan() {
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        print("Scanning started")
    }

    func stopScan() {
        centralManager.stopScan()
        print("Scanning stopped")
    }

    func connect(peripheral: CBPeripheral) {
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect(peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func discoverServices(for peripheral: CBPeripheral, completion: @escaping ([CBService]) -> Void) {
        peripheral.delegate = self
        serviceDiscoveryCompletion = completion
        peripheral.discoverServices(nil)
    }

    func readValue(for characteristic: CBCharacteristic, of peripheral: CBPeripheral, completion: @escaping (String) -> Void) {
        if peripheral.state == .connected {
            peripheral.delegate = self
            peripheral.readValue(for: characteristic)
            self.readValueCompletion[characteristic.uuid] = completion
        } else {
            print("Peripheral is not connected. Cannot read value.")
        }
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, of peripheral: CBPeripheral) {
        if peripheral.state == .connected {
            peripheral.delegate = self
            peripheral.setNotifyValue(enabled, for: characteristic)
        } else {
            print("Peripheral is not connected. Cannot set notify value.")
        }
    }
    
    func writeValue(for characteristic: CBCharacteristic, of peripheral: CBPeripheral, value: Data) {
        if peripheral.state == .connected {
            peripheral.delegate = self
            peripheral.writeValue(value, for: characteristic, type: .withResponse)
        } else {
            print("Peripheral is not connected. Cannot write value.")
        }
    }

    // CBCentralManagerDelegate methods
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            isBluetoothEnabled = true
            // Check for connected peripherals
            let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [])
            self.peripherals.append(contentsOf: connectedPeripherals)
            startScan()
        } else {
            isBluetoothEnabled = false
            print("Bluetooth is not powered on")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Check if the peripheral's name contains "Example"
        if let name = peripheral.name, name.contains("Example") {
            if !peripherals.contains(peripheral) {
                peripherals.append(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.connectedPeripheral = peripheral
            self.objectWillChange.send()
            peripheral.discoverServices(nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.connectedPeripheral = nil
            self.objectWillChange.send()
        }
    }

    // CBPeripheralDelegate methods
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        print("Discovered services: \(services)")
        serviceDiscoveryCompletion?(services)

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        print("Discovered characteristics: \(characteristics)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating value: \(error.localizedDescription)")
            return
        }
        let value = characteristic.value?.hexEncodedString() ?? "N/A"
        print("Updated value for characteristic \(characteristic.uuid): \(value)")
        readValueCompletion[characteristic.uuid]?(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating notification state: \(error.localizedDescription)")
            return
        }
        print("Characteristic \(characteristic.uuid) is \(characteristic.isNotifying ? "notifying" : "not notifying")")
    }
}

extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhX", $0) }.joined()
    }
}
