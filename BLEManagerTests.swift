import XCTest
@testable import ble_thermometer
import CoreBluetooth

/// Test cases for Air Quality device prioritization in BLEManager
class BLEManagerTests: XCTestCase {
    
    var bleManager: BLEManager!
    
    override func setUp() {
        super.setUp()
        bleManager = BLEManager()
    }
    
    override func tearDown() {
        bleManager = nil
        super.tearDown()
    }
    
    func testAirQualityDeviceDetection() {
        // Create mock peripherals with different names
        let airQualityDevice = MockCBPeripheral(name: "Air Quality Monitor Pro")
        let regularThermometer = MockCBPeripheral(name: "Temperature Sensor")
        let unknownDevice = MockCBPeripheral(name: nil)
        
        // Test Air Quality device detection
        XCTAssertTrue(bleManager.isAirQualityDevice(airQualityDevice), "Should detect Air Quality device")
        XCTAssertFalse(bleManager.isAirQualityDevice(regularThermometer), "Should not detect regular thermometer as Air Quality device")
        XCTAssertFalse(bleManager.isAirQualityDevice(unknownDevice), "Should not detect device with no name as Air Quality device")
    }
    
    func testDevicePrioritization() {
        // Create mock peripherals
        let airQualityDevice = MockCBPeripheral(name: "Air Quality Sensor")
        let targetServiceDevice = MockCBPeripheral(name: "Thermometer")
        let strongSignalDevice = MockCBPeripheral(name: "Strong Device")
        let weakSignalDevice = MockCBPeripheral(name: "Weak Device")
        
        let targetServiceUUID = CBUUID(string: "1809")
        
        // Test priority calculation
        let airQualityPriority = bleManager.getDevicePriority(
            airQualityDevice, 
            rssi: NSNumber(value: -50), 
            advertisedServices: []
        )
        
        let targetServicePriority = bleManager.getDevicePriority(
            targetServiceDevice, 
            rssi: NSNumber(value: -60), 
            advertisedServices: [targetServiceUUID]
        )
        
        let strongSignalPriority = bleManager.getDevicePriority(
            strongSignalDevice, 
            rssi: NSNumber(value: -45), 
            advertisedServices: []
        )
        
        let weakSignalPriority = bleManager.getDevicePriority(
            weakSignalDevice, 
            rssi: NSNumber(value: -85), 
            advertisedServices: []
        )
        
        // Air Quality devices should have highest priority
        XCTAssertGreaterThan(airQualityPriority, targetServicePriority, "Air Quality device should have higher priority than target service device")
        XCTAssertGreaterThan(airQualityPriority, strongSignalPriority, "Air Quality device should have higher priority than strong signal device")
        XCTAssertGreaterThan(airQualityPriority, weakSignalPriority, "Air Quality device should have higher priority than weak signal device")
        
        // Target service should have higher priority than signal-only devices
        XCTAssertGreaterThan(targetServicePriority, strongSignalPriority, "Target service device should have higher priority than signal-only device")
        XCTAssertGreaterThan(targetServicePriority, weakSignalPriority, "Target service device should have higher priority than weak signal device")
        
        // Strong signal should have higher priority than weak signal
        XCTAssertGreaterThan(strongSignalPriority, weakSignalPriority, "Strong signal device should have higher priority than weak signal device")
    }
    
    func testAirQualityDeviceFiltering() {
        // Add multiple mock peripherals to the manager
        let airQualityDevice1 = MockCBPeripheral(name: "Air Quality Pro")
        let airQualityDevice2 = MockCBPeripheral(name: "Air Quality Monitor")
        let regularDevice1 = MockCBPeripheral(name: "Thermometer")
        let regularDevice2 = MockCBPeripheral(name: "Humidity Sensor")
        
        // Simulate adding devices to peripherals array
        bleManager.peripherals = [regularDevice1, airQualityDevice1, regularDevice2, airQualityDevice2]
        
        // Test getting only Air Quality devices
        let airQualityDevices = bleManager.getAirQualityDevices()
        
        XCTAssertEqual(airQualityDevices.count, 2, "Should return exactly 2 Air Quality devices")
        XCTAssertTrue(airQualityDevices.contains(airQualityDevice1), "Should contain first Air Quality device")
        XCTAssertTrue(airQualityDevices.contains(airQualityDevice2), "Should contain second Air Quality device")
        XCTAssertFalse(airQualityDevices.contains(regularDevice1), "Should not contain regular thermometer")
        XCTAssertFalse(airQualityDevices.contains(regularDevice2), "Should not contain humidity sensor")
    }
    
    func testConnectToFirstAirQualityDevice() {
        // Test when no Air Quality devices are available
        bleManager.peripherals = [
            MockCBPeripheral(name: "Thermometer"),
            MockCBPeripheral(name: "Humidity Sensor")
        ]
        
        let result1 = bleManager.connectToFirstAirQualityDevice()
        XCTAssertFalse(result1, "Should return false when no Air Quality devices are available")
        
        // Test when Air Quality devices are available
        let airQualityDevice = MockCBPeripheral(name: "Air Quality Monitor")
        bleManager.peripherals = [
            MockCBPeripheral(name: "Thermometer"),
            airQualityDevice,
            MockCBPeripheral(name: "Humidity Sensor")
        ]
        
        let result2 = bleManager.connectToFirstAirQualityDevice()
        XCTAssertTrue(result2, "Should return true when Air Quality devices are available")
    }
}

// MARK: - Mock CBPeripheral for Testing
class MockCBPeripheral: CBPeripheral {
    private let mockName: String?
    
    init(name: String?) {
        self.mockName = name
        super.init()
    }
    
    override var name: String? {
        return mockName
    }
}
