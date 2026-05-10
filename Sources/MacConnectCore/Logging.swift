import Foundation
import os

public enum Log {
    public static let subsystem = "org.macconnect.MacConnect"
    public static let net = Logger(subsystem: subsystem, category: "net")
    public static let pair = Logger(subsystem: subsystem, category: "pair")
    public static let plugin = Logger(subsystem: subsystem, category: "plugin")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
