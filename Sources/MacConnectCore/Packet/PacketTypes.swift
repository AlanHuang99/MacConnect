import Foundation

public enum PacketType {
    public static let identity = "kdeconnect.identity"
    public static let pair = "kdeconnect.pair"
    public static let ping = "kdeconnect.ping"

    public static let clipboard = "kdeconnect.clipboard"
    public static let clipboardConnect = "kdeconnect.clipboard.connect"

    public static let notification = "kdeconnect.notification"
    public static let notificationRequest = "kdeconnect.notification.request"
    public static let notificationReply = "kdeconnect.notification.reply"
    public static let notificationAction = "kdeconnect.notification.action"

    public static let shareRequest = "kdeconnect.share.request"
    public static let shareRequestUpdate = "kdeconnect.share.request.update"

    public static let mpris = "kdeconnect.mpris"
    public static let mprisRequest = "kdeconnect.mpris.request"

    public static let systemVolume = "kdeconnect.systemvolume"
    public static let systemVolumeRequest = "kdeconnect.systemvolume.request"

    public static let battery = "kdeconnect.battery"
    public static let batteryRequest = "kdeconnect.battery.request"

    public static let findMyPhoneRequest = "kdeconnect.findmyphone.request"

    public static let runCommand = "kdeconnect.runcommand"
    public static let runCommandRequest = "kdeconnect.runcommand.request"
}

public enum DeviceType: String, Codable, Sendable {
    case desktop, laptop, phone, tablet, tv

    public static let mac: DeviceType = .laptop
}
