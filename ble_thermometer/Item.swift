//
//  Item.swift
//  ble_thermometer
//
//  Created by Mohamed Djemai on 2025-03-30.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
