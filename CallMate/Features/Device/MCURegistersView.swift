//
//  MCURegistersView.swift
//  CallMate
//
//  View MCU register dump (SF32LB52x): expandable peripherals, search by name or hex.
//

import SwiftUI

struct MCURegistersView: View {
    let language: Language
    @ObservedObject private var ble = CallMateBLEClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    /// Which peripheral names are expanded. Default all collapsed.
    @State private var expandedPeripheralNames: Set<String> = []

    private func t(_ zh: String, _ en: String) -> String { language == .zh ? zh : en }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Filter peripherals and their registers by search; if not searching, return all.
    private func filteredPeripherals(from data: MCURegDumpData) -> [MCUPeripheralRegs] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return data.peripherals
        }
        let svd = SVDRegistry.shared
        return data.peripherals.compactMap { periph -> MCUPeripheralRegs? in
            let nameMatch = periph.name.lowercased().contains(q)
            let matchingRegs = periph.registers.filter { reg in
                if nameMatch { return true }
                if String(format: "%08X", reg.addr).lowercased().contains(q) { return true }
                if String(format: "%08X", reg.value).lowercased().contains(q) { return true }
                if let meta = svd.metadata(peripheralName: periph.name, byteOffset: reg.offset * 4) {
                    if meta.name.lowercased().contains(q) { return true }
                    if meta.fields.contains(where: { $0.name.lowercased().contains(q) }) { return true }
                }
                return false
            }
            if matchingRegs.isEmpty && !nameMatch { return nil }
            if nameMatch { return periph }
            return MCUPeripheralRegs(name: periph.name, base: periph.base, registers: matchingRegs)
        }
    }

    var body: some View {
        Group {
            switch ble.regDumpState {
            case .idle:
                idleView
            case .loading(let received, let total):
                loadingView(received: received, total: total)
            case .loaded(let data):
                loadedView(data: data)
            case .error(let message):
                errorView(message: message)
            }
        }
        .navigationTitle(t("MCU 寄存器", "MCU Registers"))
        .searchable(text: $searchText, prompt: t("外设名或地址/值", "Peripheral or addr/value"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    ble.requestRegDump()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!ble.isReady || ble.regDumpState.isLoading)
            }
        }
        .onAppear {
            if case .idle = ble.regDumpState, ble.isReady {
                ble.requestRegDump()
            }
        }
    }

    private var idleView: some View {
        List {
            Section {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "cpu")
                        .font(.system(size: 24))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(t("点击右上角刷新获取寄存器快照", "Tap refresh to fetch register snapshot"))
                        .font(AppTypography.caption1)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    private func loadingView(received: Int, total: Int) -> some View {
        List {
            Section {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .scaleEffect(0.9)
                    if total > 0 {
                        Text(t("接收中 \(received)/\(total)…", "Receiving \(received)/\(total)…"))
                            .font(AppTypography.caption1)
                            .foregroundStyle(AppColors.textSecondary)
                    } else {
                        Text(t("等待数据…", "Waiting for data…"))
                            .font(AppTypography.caption1)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    private func loadedView(data: MCURegDumpData) -> some View {
        let list = filteredPeripherals(from: data)
        return List {
            ForEach(list, id: \.name) { periph in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedPeripheralNames.contains(periph.name) },
                        set: { if $0 { expandedPeripheralNames.insert(periph.name) } else { expandedPeripheralNames.remove(periph.name) } }
                    )
                ) {
                    ForEach(Array(periph.registers.enumerated()), id: \.offset) { _, reg in
                        registerRow(peripheralName: periph.name, reg: reg)
                    }
                } label: {
                    HStack {
                        Text(periph.name)
                            .font(AppTypography.caption1)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(periph.registers.count) regs")
                            .font(AppTypography.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func registerRow(peripheralName: String, reg: MCURegisterEntry) -> some View {
        let byteOffset = reg.offset * 4
        let svd = SVDRegistry.shared.metadata(peripheralName: peripheralName, byteOffset: byteOffset)
        let regName = svd?.name
        let fields = svd?.fields ?? []

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "+0x%02X", byteOffset))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    if let name = regName, !name.isEmpty {
                        Text(name)
                            .font(AppTypography.caption1)
                            .fontWeight(.medium)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
                .frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "0x%08X", reg.addr))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(String(format: "0x%08X", reg.value))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppColors.primary)
                }
                Spacer(minLength: 0)
            }
            if !fields.isEmpty {
                let summary = fields.prefix(10).map { f in
                    "\(f.name)=\(f.value(from: reg.value))"
                }.joined(separator: " ")
                Text(summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func errorView(message: String) -> some View {
        List {
            Section {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(AppTypography.caption1)
                        .foregroundStyle(AppColors.error)
                }
                .listRowBackground(AppColors.error.opacity(0.08))
            }
        }
    }
}

extension MCURegDumpState {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
