import SwiftUI
import CoreText

public enum InterfaceStyle {
    public static func registerFonts() {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Medium"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
    public static let blue = color(0x176BDB)
    static let ink = color(0x293D57)
    static let muted = color(0x7E8BA1)
    static func color(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    static func technical(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular", size: size)
    }
}

struct InterfaceButtonStyle: ButtonStyle {
    var primary = false
    var width: CGFloat? = nil
    var height: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? .white : InterfaceStyle.ink)
            .padding(.horizontal, 14).frame(width: width, height: height)
            .background(primary ? InterfaceStyle.blue : InterfaceStyle.color(0xF1F3F6), in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
