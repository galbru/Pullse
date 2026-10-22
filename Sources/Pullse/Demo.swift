import AppKit
import ImageIO
import PullseCore
import SwiftUI
import UniformTypeIdentifiers

/// `Pullse --demo <dir>`: renders the README's animated GIFs. Each frame is Pullse's real
/// views, drawn off-screen by `Capture`, inside a small made-up desktop: wallpaper,
/// a menu bar holding the real menu bar label, macOS-style notification banners and a
/// pointer. The data is `Capture`'s sample data; nothing talks to GitHub.
///
/// GIFs are written with ImageIO, so no tools beyond macOS are needed.
@MainActor
enum Demo {
    struct Frame {
        let view: AnyView
        /// Seconds this frame stays on screen.
        let delay: Double
    }

    /// Pixels per point in the GIFs: Retina resolution, shown at half size in the README
    /// so text stays sharp. Flat UI compresses well, so the files stay small.
    static let outputScale: CGFloat = 2

    static func render(to directory: URL) {
        Task {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await write(try notifyFrames(), to: directory.appendingPathComponent("demo-notify.gif"))
                try await write(try settingsFrames(), to: directory.appendingPathComponent("demo-settings.gif"))
                try await write(try updateFrames(), to: directory.appendingPathComponent("demo-update.gif"))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    // MARK: - Scenarios

    /// Two notifications arrive, the count climbs, and a click opens the activity list.
    private static func notifyFrames() throws -> [Frame] {
        // Shifted so the newest sample event reads "now".
        let events = Capture.sampleEvents(now: Date().addingTimeInterval(120))
        func event(_ id: String) -> PREvent { events.first { $0.id == id }! }
        let older = events.filter { ["4", "5", "6"].contains($0.id) }
        let ci = event("3"), review = event("1")

        func desktop(_ history: [PREvent], banner: PREvent? = nil, shown: CGFloat = 1,
                     cursor: CGPoint? = nil, click: Bool = false, menu: Bool = false) throws -> AnyView {
            AnyView(DemoDesktop(
                model: try Capture.sampleModel(events: history, update: false),
                menu: menu, banner: banner.map(DemoBanner.init(event:)), bannerShown: shown,
                cursor: cursor, click: click
            ))
        }

        let start = CGPoint(x: 330, y: 360)
        var frames = [Frame(view: try desktop(older, cursor: start), delay: 1.2)]
        for (history, arriving) in [(older + [ci], ci), (older + [ci, review], review)] {
            for shown in [0.35, 0.7] {
                frames.append(Frame(view: try desktop(history, banner: arriving, shown: shown, cursor: start), delay: 0.05))
            }
            frames.append(Frame(view: try desktop(history, banner: arriving, cursor: start), delay: 2.4))
            frames.append(Frame(view: try desktop(history, banner: arriving, shown: 0.5, cursor: start), delay: 0.05))
        }
        let all = older + [ci, review]
        for point in path(from: start, to: DemoDesktop.icon, steps: 5) {
            frames.append(Frame(view: try desktop(all, cursor: point), delay: 0.06))
        }
        frames.append(Frame(view: try desktop(all, cursor: DemoDesktop.icon, click: true), delay: 0.15))
        frames.append(Frame(view: try desktop(all, cursor: DemoDesktop.icon, menu: true), delay: 4.5))
        return frames
    }

    /// A tour of the Settings tabs, clicked one after another in the sidebar.
    private static func settingsFrames() throws -> [Frame] {
        func window(_ tab: SettingsTab, cursor: CGPoint, click: Bool = false) throws -> AnyView {
            let model = try Capture.sampleModel()
            return AnyView(DemoCanvas(size: CGSize(width: 700, height: 650), cursor: cursor, click: click) {
                Capture.popover(SettingsView(model: model, tab: tab))
                    .fixedSize()
                    .offset(x: 20, y: 20)
            })
        }
        /// Where the pointer rests on a sidebar row.
        func row(_ tab: SettingsTab) -> CGPoint {
            let index = CGFloat(SettingsTab.allCases.firstIndex(of: tab) ?? 0)
            return CGPoint(x: 20 + 76, y: 20 + 26 + index * 28.5)
        }

        let tabs = SettingsTab.allCases
        var frames: [Frame] = []
        for (current, next) in zip(tabs, tabs.dropFirst() + [tabs[0]]) {
            frames.append(Frame(view: try window(current, cursor: row(current)), delay: current == .notifications ? 3.2 : 2.2))
            for point in path(from: row(current), to: row(next), steps: 3) {
                frames.append(Frame(view: try window(current, cursor: point), delay: 0.06))
            }
            frames.append(Frame(view: try window(current, cursor: row(next), click: true), delay: 0.12))
        }
        return frames
    }

    /// An update is found, installed from the menu, and Pullse comes back on the new version.
    private static func updateFrames() throws -> [Frame] {
        let events = Capture.sampleEvents(now: Date()).map { event -> PREvent in
            var event = event
            event.isUnread = false
            return event
        }
        func desktop(update: Bool = true, phase: Updater.Phase = .idle, icon: Bool = true,
                     banner: DemoBanner? = nil, shown: CGFloat = 1,
                     cursor: CGPoint? = nil, click: Bool = false, menu: Bool = false) throws -> AnyView {
            let model = try Capture.sampleModel(events: events, update: update)
            model.updater.showPhase(phase)
            return AnyView(DemoDesktop(
                model: model, iconVisible: icon, menu: menu, banner: banner, bannerShown: shown,
                cursor: cursor, click: click
            ))
        }

        let start = CGPoint(x: 330, y: 380)
        let install = DemoDesktop.menuOrigin.applying(.init(translationX: 347, y: 81))
        var frames = [Frame(view: try desktop(cursor: start), delay: 1.6)]
        for point in path(from: start, to: DemoDesktop.icon, steps: 5) {
            frames.append(Frame(view: try desktop(cursor: point), delay: 0.06))
        }
        frames.append(Frame(view: try desktop(cursor: DemoDesktop.icon, click: true), delay: 0.15))
        frames.append(Frame(view: try desktop(cursor: DemoDesktop.icon, menu: true), delay: 1.8))
        for point in path(from: DemoDesktop.icon, to: install, steps: 4) {
            frames.append(Frame(view: try desktop(cursor: point, menu: true), delay: 0.06))
        }
        frames.append(Frame(view: try desktop(cursor: install, click: true, menu: true), delay: 0.15))
        frames.append(Frame(view: try desktop(phase: .downloading, cursor: install, menu: true), delay: 1.4))
        frames.append(Frame(view: try desktop(phase: .installing, cursor: install, menu: true), delay: 1.4))
        // Pullse quits, the new version is moved in, and it starts again.
        frames.append(Frame(view: try desktop(icon: false, cursor: install), delay: 0.8))
        let updated = DemoBanner(title: "Pullse updated to 1.4.0", subtitle: nil, message: "Click to see what's new.")
        for shown in [0.35, 0.7] {
            frames.append(Frame(view: try desktop(update: false, banner: updated, shown: shown, cursor: install), delay: 0.05))
        }
        frames.append(Frame(view: try desktop(update: false, banner: updated, cursor: install), delay: 3.5))
        return frames
    }

    /// Evenly spaced pointer positions after `start`, ending at `end`.
    private static func path(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        (1...steps).map { step in
            // Ease out, the way a hand slows down onto a target.
            let t = 1 - pow(1 - CGFloat(step) / CGFloat(steps), 2)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
    }

    // MARK: - Writing GIFs

    private static func write(_ frames: [Frame], to url: URL) async throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        let loopForever = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(destination, loopForever as CFDictionary)

        for frame in frames {
            let bitmap = try await Capture.image(of: frame.view, appearance: .aqua, settle: .milliseconds(250))
            guard let captured = bitmap.cgImage,
                  let image = resized(captured, width: Int(bitmap.size.width * outputScale))
            else { throw CocoaError(.fileWriteUnknown) }
            let timing = [kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frame.delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: frame.delay,
            ]]
            CGImageDestinationAddImage(destination, image, timing as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("wrote \(url.path) (\(frames.count) frames, \(bytes / 1024) KB)")
    }

    private static func resized(_ image: CGImage, width: Int) -> CGImage? {
        let height = Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Scene pieces

/// The desktop behind every scene, a shade darker in dark mode.
struct DemoWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.13, green: 0.20, blue: 0.40), Color(red: 0.27, green: 0.18, blue: 0.40)]
                : [Color(red: 0.35, green: 0.53, blue: 0.87), Color(red: 0.60, green: 0.45, blue: 0.80)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// A fixed-size wallpaper with `content` on it and an optional pointer on top.
struct DemoCanvas<Content: View>: View {
    let size: CGSize
    var cursor: CGPoint?
    var click = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            DemoWallpaper()
            content()
            if let cursor {
                DemoPointer(click: click).offset(x: cursor.x, y: cursor.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

/// A desktop with a menu bar; Pullse's label sits in it at `icon`, and its menu opens
/// under it.
struct DemoDesktop: View {
    static let size = CGSize(width: 760, height: 590)
    /// Center of Pullse's menu bar label: the right side of the bar is laid out in fixed
    /// widths so this is known.
    static let icon = CGPoint(x: size.width - 222, y: 13)
    /// Top-left corner of the open menu.
    static let menuOrigin = CGPoint(x: icon.x - 191, y: 31)

    @Environment(\.colorScheme) private var scheme
    let model: AppModel
    var iconVisible = true
    var menu = false
    var banner: DemoBanner?
    var bannerShown: CGFloat = 1
    var cursor: CGPoint?
    var click = false
    /// Narrower than the GIFs' desktop for a still picture of the open menu: the icon and
    /// menu keep their distance from the right edge, so only empty desktop is cut.
    var width: CGFloat

    init(model: AppModel, iconVisible: Bool = true, menu: Bool = false, banner: DemoBanner? = nil,
         bannerShown: CGFloat = 1, cursor: CGPoint? = nil, click: Bool = false,
         width: CGFloat = DemoDesktop.size.width) {
        self.width = width
        self.model = model
        self.iconVisible = iconVisible
        self.menu = menu
        self.banner = banner
        self.bannerShown = bannerShown
        self.cursor = cursor
        self.click = click
    }

    var body: some View {
        // Everything is placed from the right edge, like a real menu bar.
        let shift = width - Self.size.width
        DemoCanvas(size: CGSize(width: width, height: Self.size.height), cursor: cursor, click: click) {
            menuBar
            if menu {
                Capture.popover(MenuView(model: model))
                    .fixedSize()
                    .offset(x: Self.menuOrigin.x + shift, y: Self.menuOrigin.y)
            }
            if let banner {
                banner.offset(x: width - DemoBanner.width - 12 + (1 - bannerShown) * (DemoBanner.width + 24),
                              y: 36)
            }
        }
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "applelogo")
            Text("Finder").fontWeight(.semibold)
            // A narrow desktop has room for the app name only, as a real menu bar would.
            if width >= Self.size.width {
                Text("File")
                Text("Edit")
                Text("View")
                Text("Window")
            }
            Spacer()
            Group {
                if iconVisible {
                    MenuBarLabel(model: model, statusMenu: StatusItemMenu(model: model))
                }
            }
            .frame(width: 64)
            Image(systemName: "wifi").frame(width: 24)
            Image(systemName: "battery.75percent").frame(width: 30)
            Text("Mon 9:41").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(width: width, height: 26)
        .background(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.72))
    }
}

/// A macOS-style notification banner, laid out like the ones `Notifier` posts.
struct DemoBanner: View {
    static let width: CGFloat = 344

    let title: String
    let subtitle: String?
    let message: String

    init(title: String, subtitle: String?, message: String) {
        self.title = title
        self.subtitle = subtitle
        self.message = message
    }

    /// The banner Pullse posts for one event.
    init(event: PREvent) {
        self.init(title: "\(event.prLabel) · \(event.headline)", subtitle: event.prTitle, message: event.snippet)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The demo runs from the built bundle, so this is the real app icon.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).lineLimit(1)
                }
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .foregroundStyle(.black)
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.965))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        )
    }
}

/// The arrow pointer, tip at the view's origin, with a ring while it clicks.
struct DemoPointer: View {
    let click: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if click {
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    .background(Circle().fill(Color.black.opacity(0.15)))
                    .frame(width: 28, height: 28)
                    .offset(x: -14, y: -14)
            }
            Arrow()
                .fill(.black)
                .overlay(Arrow().stroke(.white, lineWidth: 1.5))
                .frame(width: 14, height: 22)
        }
    }

    private struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: .zero)
            for point in [(0, 17), (4, 13.2), (7, 20), (9.6, 18.9), (6.7, 12.3), (12, 12.3)] {
                path.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            path.closeSubpath()
            return path
        }
    }
}
