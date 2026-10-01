import PicoClaudeCore
import SwiftUI

/// One limit: label, reset countdown, percentage and a bar with a pace marker.
struct LimitRow: View {
    let label: String
    let window: LimitWindow?
    let windowSeconds: Double
    let now: Date

    var body: some View {
        let nowS = Int(now.timeIntervalSince1970)
        let remaining = window.flatMap { $0.reset > nowS ? $0.reset - nowS : nil }
        let expired = window.map { $0.reset != 0 && $0.reset <= nowS } ?? false
        let pct = expired ? 0 : window?.pct
        let color = Palette.level(pct)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                if window == nil {
                    Text("no reading yet")
                } else if let remaining {
                    Text("resets \(Format.duration(remaining))")
                } else {
                    Text("window reset")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.dim)
            HStack(spacing: 10) {
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(pct == nil ? Palette.dim : color)
                    .frame(width: 62, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Palette.track)
                        Rectangle().fill(color)
                            .frame(width: geo.size.width * min(1, (pct ?? 0) / 100))
                        if let remaining {
                            // pace marker: how far through the window we are
                            let elapsed = min(1, max(0, 1 - Double(remaining) / windowSeconds))
                            Rectangle().fill(Palette.text)
                                .frame(width: 2, height: geo.size.height + 6)
                                .offset(x: (geo.size.width - 2) * elapsed)
                        }
                    }
                }
                .frame(height: 18)
            }
        }
    }
}

struct WeekChart: View {
    let week: [Int]
    let now: Date

    var body: some View {
        let top = max(week.max() ?? 1, 1)
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let today = Calendar.current.component(.weekday, from: now) - 1
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(week.enumerated()), id: \.offset) { index, value in
                let last = index == week.count - 1
                VStack(spacing: 3) {
                    Rectangle()
                        .fill(last ? Palette.orange : value > 0 ? Palette.dim : Palette.track)
                        .frame(width: 14, height: value > 0 ? max(2, 40 * CGFloat(value) / CGFloat(top)) : 1)
                    Text(symbols[((today - (week.count - 1 - index)) % 7 + 7) % 7])
                        .font(.system(size: 9))
                        .foregroundStyle(last ? Palette.text : Palette.dim)
                }
            }
        }
    }
}

/// The same picture the Pico shows.
struct UsageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "asterisk").foregroundStyle(Palette.orange).fontWeight(.bold)
                Text("Claude Code").foregroundStyle(Palette.text).fontWeight(.semibold)
                Spacer()
                Text(model.now, format: .dateTime.hour().minute()).foregroundStyle(Palette.dim)
            }
            .font(.system(size: 13))
            if let p = model.payload {
                LimitRow(label: "5h session", window: p.h5, windowSeconds: 5 * 3600, now: model.now)
                LimitRow(label: "Week", window: p.d7, windowSeconds: 7 * 86400, now: model.now)
                Rectangle().fill(Palette.rule).frame(height: 1)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.model.isEmpty ? "Today" : "Today · \(p.model)")
                            .font(.system(size: 12)).foregroundStyle(Palette.dim)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Format.tokens(p.today.tok))
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(Palette.text)
                            Text("tok").font(.system(size: 12)).foregroundStyle(Palette.dim)
                        }
                        Text("\(Format.tokens(p.today.out)) out · \(p.today.msgs) msgs")
                            .font(.system(size: 12)).foregroundStyle(Palette.dim)
                    }
                    Spacer()
                    WeekChart(week: p.week, now: model.now)
                }
            } else {
                Text("Reading transcripts…").font(.system(size: 12)).foregroundStyle(Palette.dim)
            }
        }
    }
}

struct HostsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let nowS = Int(model.now.timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 4) {
            Text("HOSTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.dim)
            ForEach(model.hosts) { host in
                HStack {
                    Text(host.name).foregroundStyle(Palette.text)
                    Spacer()
                    Text("\(Format.tokens(host.todayTokens)) today").foregroundStyle(Palette.dim)
                    Text(host.isLocal ? "this Mac" : "\(Format.duration(max(0, nowS - host.lastSeen))) ago")
                        .foregroundStyle(Palette.dim)
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
            if let p = model.payload, let ts = [p.h5?.ts, p.d7?.ts].compactMap({ $0 }).max() {
                Text("Limits read \(Format.duration(max(0, nowS - ts))) ago")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.top, 2)
            }
        }
    }
}

struct ControlsView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(model.connected ? Color.green : Palette.red).frame(width: 7, height: 7)
                Text(model.connected ? "Connected to \(model.brokerHost)" : "Not connected")
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
                Spacer()
                Toggle("Pico display", isOn: Binding(
                    get: { model.displayOn ?? true },
                    set: { model.setDisplay(on: $0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 12)).foregroundStyle(Palette.text)
                    .disabled(!model.connected)
            }
            if let problem = model.problem, !model.connected {
                Text(problem).font(.system(size: 11)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showSettings {
                HStack {
                    TextField("Broker address", text: $model.brokerHost)
                    TextField("Port", value: $model.brokerPort, format: .number.grouping(.never))
                        .frame(width: 60)
                    Button("Apply") { model.applyBroker() }
                }
                .textFieldStyle(.roundedBorder).controlSize(.small)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .controlSize(.small).font(.system(size: 12)).foregroundStyle(Palette.text)
            }
            HStack {
                Button(showSettings ? "Hide settings" : "Settings") { showSettings.toggle() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.link).font(.system(size: 12))
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    var controls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageView(model: model)
            Rectangle().fill(Palette.rule).frame(height: 1)
            HostsView(model: model)
            if controls {
                Rectangle().fill(Palette.rule).frame(height: 1)
                ControlsView(model: model)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Palette.background)
        .environment(\.colorScheme, .dark)
    }
}
