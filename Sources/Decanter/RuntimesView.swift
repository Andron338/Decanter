import AppKit
import DecanterCore
import SwiftUI

/// Settings › Runtimes: every engine Decanter can download, whether it is installed, and the
/// install, update and remove actions that apply to it.
struct RuntimesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let runtime = model.runtime {
                Section {
                    ForEach(RuntimeComponent.allCases.filter { $0.applies(to: runtime) }) { component in
                        RuntimeRow(component: component, runtime: runtime)
                    }
                } footer: {
                    if !model.running.isEmpty {
                        Text("Quit running games to change engines.")
                    }
                }
                Section {
                    switchRow(runtime)
                } header: {
                    Text("Main Wine")
                }
            } else {
                Text("Set Decanter up first. The engines it uses are listed here afterwards.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func switchRow(_ runtime: InstalledRuntime) -> some View {
        let target: RuntimeComponent? = runtime.isNative ? .wine
            : RuntimeManager.canRunWithoutRosetta ? .metalSharp : nil
        if let target {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.isNative ? "Switch to Wine 11 with Rosetta 2" : "Switch to MetalSharp Wine")
                    Text(runtime.isNative
                         ? "Installs Rosetta 2 if needed and uses Wine 11 with DXMT and the optional engines again."
                         : "Experimental, without Rosetta 2. About 1.3 GB. Your games' bottles stay, but were made by the other Wine and may need setting up again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .working(let stage, let fraction) = model.componentWork[target] {
                    WorkProgress(stage: stage, fraction: fraction)
                } else {
                    Button("Switch") { model.update(target) }
                        .disabled(!model.canChangeRuntimes)
                }
            }
            if case .failed(let message) = model.componentWork[target] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } else {
            Text("Wine 11 through Rosetta 2. Running without Rosetta needs macOS 15 or later on Apple silicon.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RuntimeRow: View {
    @Environment(AppModel.self) private var model
    let component: RuntimeComponent
    let runtime: InstalledRuntime
    @State private var confirmingRemoval = false
    @State private var confirmingLicence = false

    private var installed: String? { component.installedVersion(in: runtime) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.title)
                    Text(component.purpose).font(.caption).foregroundStyle(.secondary)
                    Text(status).font(.caption).foregroundStyle(statusColor)
                }
                Spacer()
                actions
            }
            if case .failed(let message) = model.componentWork[component] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Remove \(component.title)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { model.remove(component) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its download is deleted. Games set to use it keep their bottles, and Decanter downloads it again the next time one of them needs it.")
        }
        .confirmationDialog("Download Apple's D3DMetal?", isPresented: $confirmingLicence) {
            Button("Agree and Download (about 230 MB)") { model.install(.d3dmetal) }
            Button("Read Apple's Licence") { NSWorkspace.shared.open(RuntimeManager.d3dMetalLicenseURL) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("D3DMetal is Apple's proprietary DirectX 11/12 translator from the Game Porting Toolkit. It isn't open source and is covered by Apple's licence, which you accept by downloading.")
        }
    }

    private var status: String {
        guard let installed else { return "Not installed" }
        if component.updateAvailable(in: runtime) {
            return "Installed: \(installed) · Update available: \(component.currentVersion)"
        }
        return "Installed: \(installed)"
    }

    private var statusColor: Color {
        installed == nil ? .secondary : component.updateAvailable(in: runtime) ? .orange : .green
    }

    @ViewBuilder private var actions: some View {
        if case .working(let stage, let fraction) = model.componentWork[component] {
            WorkProgress(stage: stage, fraction: fraction)
        } else {
            HStack {
                if installed == nil, !component.isCore {
                    Button("Install") {
                        if component == .d3dmetal { confirmingLicence = true } else { model.install(component) }
                    }
                }
                if installed != nil, component.updateAvailable(in: runtime) {
                    Button("Update") { model.update(component) }
                }
                if installed != nil, !component.isCore {
                    Button("Remove") { confirmingRemoval = true }
                }
            }
            .disabled(!model.canChangeRuntimes)
        }
    }
}

private struct WorkProgress: View {
    let stage: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let fraction { ProgressView(value: fraction).frame(width: 140) } else { ProgressView().controlSize(.small) }
            Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 180, alignment: .trailing)
        }
    }
}
