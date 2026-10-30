//
//  TunerUsagePanel.swift
//  Consolation
//

import HTTPMPEG2Kit
import SwiftUI

/// What each tuner is doing: free, or the channel it's tuned to and which device on the network is watching. With
/// several configured tuners, each device's tuners sit under its name.
struct TunerUsagePanel: View {
    let devices: [DeviceTuners]
    /// The tuners carrying this app's own streams on a device, from the tuner broker.
    var ours: (DeviceTuners) -> Set<String> = { _ in [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tuners").font(.headline)
            ForEach(devices) { device in
                if devices.count > 1 {
                    Text(device.name).font(.subheadline.weight(.semibold)).padding(.top, 4)
                }
                let ourTuners = ours(device)
                ForEach(device.tuners, id: \.resource) { tuner in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tuner.isInUse ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                        Text(tuner.resource).monospaced()
                        Text(description(of: tuner, ours: ourTuners)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func description(of tuner: TunerStatus, ours: Set<String>) -> String {
        guard tuner.isInUse else { return "free" }
        let channel = [tuner.vctNumber, tuner.vctName].compactMap { $0 }.joined(separator: " ")
        let isOurs = ours.contains { $0.caseInsensitiveCompare(tuner.resource) == .orderedSame }
        let watcher = isOurs ? "· this device" : tuner.targetIP.map { "· \($0)" } ?? ""
        let label = channel.isEmpty ? (tuner.frequency.map { "\($0 / 1_000_000) MHz" } ?? "in use") : channel
        return "\(label) \(watcher)"
    }
}
