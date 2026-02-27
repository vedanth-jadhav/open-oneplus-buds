#!/usr/bin/env swift

import Foundation
import CoreBluetooth

let VERSION = "1.0.0"

enum Command {
    case ancOn
    case ancOff
    case transparency
    case battery
    case info
    case eq
    case help
}

class NordBudsCLI: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    var centralManager: CBCentralManager!
    var peripheral: CBPeripheral?
    var cmdChar079A: CBCharacteristic?
    var notifyChar079A: CBCharacteristic?
    var cmdCharFE2C: CBCharacteristic?
    var command: Command = .help
    var done = false
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("[ERROR] Bluetooth is not powered on")
            exit(1)
        }
        
        let retrieve = central.retrieveConnectedPeripherals(withServices: [
            CBUUID(string: "0000079A-D102-11E1-9B23-00025B00A5A5")
        ])
        
        if !retrieve.isEmpty {
            self.peripheral = retrieve[0]
            retrieve[0].delegate = self
            central.connect(retrieve[0], options: nil)
            return
        }
        
        print("[*] Scanning for Nord Buds...")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDiscover peripheral: CBPeripheral, 
                       advertisementData: [String : Any], 
                       rssi RSSI: NSNumber) {
        
        if let name = peripheral.name, 
           (name.contains("Nord Buds") || name.contains("OnePlus")) {
            print("[FOUND] \(name)")
            self.peripheral = peripheral
            peripheral.delegate = self
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[OK] Connected to \(peripheral.name ?? "Nord Buds")")
        peripheral.discoverServices(nil)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didDiscoverCharacteristicsFor service: CBService, 
                   error: Error?) {
        
        for char in service.characteristics ?? [] {
            let props = char.properties.rawValue
            
            if char.uuid.uuidString == "0100079A-D102-11E1-9B23-00025B00A5A5" {
                cmdChar079A = char
                print("[+] Found Write Char: 0100079A")
            }
            
            if char.uuid.uuidString == "0200079A-D102-11E1-9B23-00025B00A5A5" {
                notifyChar079A = char
                peripheral.setNotifyValue(true, for: char)
                print("[+] Found Notify Char: 0200079A")
            }
            
            if char.uuid.uuidString == "FE2C123A-8366-4814-8EB0-01DE32100BEA" {
                cmdCharFE2C = char
                peripheral.setNotifyValue(true, for: char)
                print("[+] Found FE2C Command Char")
            }
            
            if props & 16 != 0 || props & 32 != 0 {
                peripheral.setNotifyValue(true, for: char)
            }
            
            if props & 2 != 0 {
                peripheral.readValue(for: char)
            }
        }
        
        if cmdChar079A != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.runCommand() }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didUpdateValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        print("[RX] \(characteristic.uuid): \(hex)")
        
        if bytes.count >= 10 && bytes[4] == 0x06 && bytes[5] == 0x81 {
            parseBattery(bytes)
        }
        else if bytes.count >= 6 && bytes[4] == 0x03 && bytes[5] == 0x81 {
            parseDeviceInfo(bytes)
        }
        else if bytes.count >= 6 && bytes[4] == 0x05 && bytes[5] == 0x02 {
            parseEQ(bytes)
        }
        else if bytes.count >= 3 && bytes[2] == 0x81 {
            print("[RX] Registration acknowledged")
        }
    }
    
    func parseBattery(_ bytes: [UInt8]) {
        print("\n========== BATTERY INFO ==========")
        if bytes.count >= 16 {
            print("Left Bud:  \(bytes[12])%")
            print("Right Bud: \(bytes[14])%")
            print("Case:     \(bytes[15])%")
        }
        print("==================================\n")
    }
    
    func parseDeviceInfo(_ bytes: [UInt8]) {
        print("\n========== DEVICE INFO ==========")
        if bytes.count >= 8 {
            print("Status: \(bytes[7])")
        }
        print("================================\n")
    }
    
    func parseEQ(_ bytes: [UInt8]) {
        print("\n========== EQ INFO ==========")
        if bytes.count >= 7 {
            print("EQ Mode: \(bytes[6])")
        }
        print("=============================\n")
    }
    
    func runCommand() {
        if done { return }
        done = true
        
        switch command {
        case .ancOn:
            sendAncMode(0x01, name: "ANC ON")
        case .ancOff:
            sendAncMode(0x04, name: "ANC OFF")
        case .transparency:
            sendAncMode(0x02, name: "TRANSPARENCY")
        case .battery:
            sendBatteryQuery()
        case .info:
            sendDeviceInfoQuery()
        case .eq:
            sendEQQuery()
        case .help:
            printHelp()
            exit(0)
        }
    }
    
    func sendPacket(_ data: [UInt8], name: String) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("[TX] \(name): \(hex)")
        peripheral?.writeValue(Data(data), for: cmdChar079A!, type: .withoutResponse)
    }
    
    func sendAncMode(_ mode: UInt8, name: String) {
        sendPacket([0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12], name: "HELLO")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.sendPacket([0xAA, 0x0C, 0x00, 0x00, 0x00, 0x85, 0x41, 0x05, 0x00, 0x00, 0xB5, 0x50, 0xA0, 0x69], name: "REGISTER")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            self.sendPacket([0xAA, 0x09, 0x00, 0x00, 0x04, 0x82, 0x44, 0x02, 0x00, 0x00, 0xF2], name: "QUERY")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let anc: [UInt8] = [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x42, 0x03, 0x00, 0x01, 0x01, mode]
            self.sendPacket(anc, name: "ANC SET: \(name)")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            print("\n[DONE] \(name) command sent")
            exit(0)
        }
    }
    
    func sendBatteryQuery() {
        sendPacket([0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12], name: "HELLO")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.sendPacket([0xAA, 0x0C, 0x00, 0x00, 0x00, 0x85, 0x41, 0x05, 0x00, 0x00, 0xB5, 0x50, 0xA0, 0x69], name: "REGISTER")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.sendPacket([0xAA, 0x07, 0x00, 0x00, 0x06, 0x01, 0x25, 0x00, 0x00], name: "BATTERY QUERY")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            print("\n[DONE]")
            exit(0)
        }
    }
    
    func sendDeviceInfoQuery() {
        sendPacket([0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12], name: "HELLO")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.sendPacket([0xAA, 0x0C, 0x00, 0x00, 0x00, 0x85, 0x41, 0x05, 0x00, 0x00, 0xB5, 0x50, 0xA0, 0x69], name: "REGISTER")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.sendPacket([0xAA, 0x07, 0x00, 0x00, 0x03, 0x01, 0x28, 0x00, 0x00], name: "DEVICE INFO QUERY")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            print("\n[DONE]")
            exit(0)
        }
    }
    
    func sendEQQuery() {
        sendPacket([0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0x23, 0x00, 0x00, 0x12], name: "HELLO")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.sendPacket([0xAA, 0x0C, 0x00, 0x00, 0x00, 0x85, 0x41, 0x05, 0x00, 0x00, 0xB5, 0x50, 0xA0, 0x69], name: "REGISTER")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.sendPacket([0xAA, 0x07, 0x00, 0x00, 0x05, 0x01, 0x2B, 0x00, 0x00], name: "EQ QUERY")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            print("\n[DONE]")
            exit(0)
        }
    }
    
    func printHelp() {
        print("""
        NordBuds ANC Controller v\(VERSION)
        
        Usage: \(CommandLine.arguments[0]) <command>
        
        Commands:
          on         - Enable ANC (Active Noise Cancellation)
          off        - Disable ANC
          trans      - Enable Transparency mode
          battery    - Query battery levels
          info       - Query device information
          eq         - Query equalizer settings
          help       - Show this help message
        
        Examples:
          \(CommandLine.arguments[0]) on
          \(CommandLine.arguments[0]) off
          \(CommandLine.arguments[0]) trans
          \(CommandLine.arguments[0]) battery
        """)
    }
}

func main() {
    let args = CommandLine.arguments
    
    if args.count < 2 {
        let cli = NordBudsCLI()
        cli.command = .help
        cli.printHelp()
        exit(0)
    }
    
    let cmd = args[1].lowercased()
    var command: Command = .help
    
    switch cmd {
    case "on", "anc":
        command = .ancOn
        print("[*] Target: ANC ON")
    case "off":
        command = .ancOff
        print("[*] Target: ANC OFF")
    case "trans", "transparency":
        command = .transparency
        print("[*] Target: TRANSPARENCY")
    case "battery", "bat":
        command = .battery
        print("[*] Query: BATTERY")
    case "info", "device":
        command = .info
        print("[*] Query: DEVICE INFO")
    case "eq", "equalizer":
        command = .eq
        print("[*] Query: EQUALIZER")
    case "help", "--help", "-h":
        command = .help
    default:
        print("[ERROR] Unknown command: \(cmd)")
        print("Run '\(args[0]) help' for usage")
        exit(1)
    }
    
    print("[*] Looking for Nord Buds...")
    
    let cli = NordBudsCLI()
    cli.command = command
    
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 30.0))
    
    print("[ERROR] Timeout - earbuds not responding")
    exit(1)
}

main()
