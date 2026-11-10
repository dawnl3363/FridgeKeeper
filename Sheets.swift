import SwiftUI
import UIKit

// MARK: - 添加 / 编辑

struct EditItemView: View {
    @EnvironmentObject var store: FridgeStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: FoodItem
    @State private var hasExpiry: Bool
    @State private var expiryDate: Date
    let isNew: Bool

    init(item: FoodItem, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: item)
        _hasExpiry = State(initialValue: item.expiry != nil)
        _expiryDate = State(initialValue: item.expiry ?? daysFromNow(7))
    }

    private let quickDays: [Int] = [2, 3, 7, 14, 30, 90]

    private func quickLabel(_ days: Int) -> String {
        switch days {
        case 7: return "1周"
        case 14: return "2周"
        case 30: return "1个月"
        case 90: return "3个月"
        default: return "\(days)天"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("食材") {
                    HStack {
                        TextField("图标", text: $draft.emoji)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                        Divider()
                        TextField("名称，例如：鸡蛋", text: $draft.name)
                    }
                    HStack {
                        Text("数量")
                        Spacer()
                        TextField("数量", value: $draft.qty, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        TextField("单位", text: $draft.unit)
                            .frame(width: 50)
                    }
                    Picker("放在", selection: $draft.zone) {
                        ForEach(allZones, id: \.self) { z in
                            Text(z).tag(z)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("保质期") {
                    Toggle("记录到期日期", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("到期日期", selection: $expiryDate, displayedComponents: .date)
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickDays, id: \.self) { days in
                                    Button(quickLabel(days)) {
                                        expiryDate = daysFromNow(days)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button("删除这样食材", role: .destructive) {
                            store.remove(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加食材" : "编辑食材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var item = draft
        item.name = item.name.trimmingCharacters(in: .whitespaces)
        if item.emoji.trimmingCharacters(in: .whitespaces).isEmpty { item.emoji = "🥫" }
        if item.qty < 0 { item.qty = 0 }
        item.expiry = hasExpiry ? expiryDate : nil
        store.upsert(item)
        dismiss()
    }
}

// MARK: - 拍照 / 小票识别结果

struct ScanView: View {
    let image: UIImage
    let mode: ScanMode

    @EnvironmentObject var store: FridgeStore
    @Environment(\.dismiss) private var dismiss

    @State private var results: [ScannedItem] = []
    @State private var info = ScanResult()
    @State private var loading = true
    @State private var errorText: String?

    private var isReceipt: Bool {
        mode == .receipt
    }

    private var pickedCount: Int {
        results.filter { $0.on }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .clipped()
                        .listRowInsets(EdgeInsets())
                }

                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isReceipt ? "正在读小票，长小票要多等一会儿…" : "正在识别照片里的食材…")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorText = errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                } else if results.isEmpty {
                    Text(isReceipt
                         ? "没有在小票上认出食品。把小票铺平、拍清楚一些再试，太长的小票可以分两段拍。"
                         : "没有在照片里认出食材。换个角度再拍一张，或者手动添加。")
                        .foregroundStyle(.secondary)
                } else {
                    if isReceipt {
                        Section {
                            LabeledContent("商店", value: info.store.isEmpty ? "没认出来" : info.store)
                            LabeledContent("日期", value: info.date.isEmpty ? "没认出来" : info.date)
                            LabeledContent("小票合计", value: moneyText(info.total, info.currency))
                        } header: {
                            Text("这次购物")
                        }
                    }
                    Section {
                        ForEach($results) { $row in
                            ScanRow(row: $row, currency: info.currency)
                        }
                    } header: {
                        Text(isReceipt ? "买了 \(results.count) 样食品" : "认出 \(results.count) 样")
                    } footer: {
                        Text(isReceipt
                             ? "确认一下名称、数量和到期日，不想放进冰箱的关掉开关。不是吃的东西已经自动跳过。到期日是按购买日期和常见保质期估算的。"
                             : "确认一下名称、数量和到期日，不要的关掉开关。标着「包装日期」的是从包装上读到的，其余是按常见保质期估算的。")
                    }
                }
            }
            .navigationTitle(isReceipt ? "扫描小票" : "拍照识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pickedCount > 0 ? "加入冰箱（\(pickedCount)）" : "加入冰箱") {
                        confirm()
                    }
                    .disabled(pickedCount == 0)
                }
            }
            .task {
                await run()
            }
        }
    }

    private func confirm() {
        let picked = results.filter { $0.on }
        store.merge(picked)
        if isReceipt {
            // 购物记录里保留小票上的全部食品，不管有没有放进冰箱
            var record = ReceiptRecord()
            record.store = info.store
            record.date = info.date.isEmpty ? SyncClient.dayString(Date()) : info.date
            record.total = info.total
            record.currency = info.currency
            record.lines = results.map { item in
                var line = ReceiptLine()
                line.name = item.name
                line.qty = item.qty
                line.unit = item.unit
                line.price = item.price
                return line
            }
            store.addReceipt(record)
        }
        dismiss()
    }

    private func run() async {
        do {
            let found = try await Recognizer.recognize(
                image: image,
                mode: mode,
                apiKey: Keychain.get("apiKey"),
                model: currentModel()
            )
            info = found
            results = found.items
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

struct ScanRow: View {
    @Binding var row: ScannedItem
    let currency: String

    private var expiryBinding: Binding<Date> {
        Binding(
            get: { row.expiry ?? daysFromNow(7) },
            set: { newValue in
                row.expiry = newValue
                row.printed = false
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.emoji)
                    .font(.title2)
                TextField("名称", text: $row.name)
                    .font(.body.weight(.semibold))
                if row.price != nil {
                    Text(moneyText(row.price, currency))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Toggle("加入", isOn: $row.on)
                    .labelsHidden()
            }
            if !row.raw.isEmpty {
                Text("小票原文：" + row.raw)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                TextField("数量", value: $row.qty, format: .number)
                    .keyboardType(.decimalPad)
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
                TextField("单位", text: $row.unit)
                    .frame(width: 50)
                    .textFieldStyle(.roundedBorder)
                Picker("位置", selection: $row.zone) {
                    ForEach(allZones, id: \.self) { z in
                        Text(z).tag(z)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if row.expiry != nil {
                    DatePicker("到期", selection: expiryBinding, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    if row.printed {
                        Text("包装日期")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14))
                            .clipShape(Capsule())
                    }
                } else {
                    Button("设置到期日") {
                        row.expiry = daysFromNow(7)
                    }
                    .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(row.on ? 1 : 0.45)
    }
}

// MARK: - 购物记录

struct ReceiptHistoryView: View {
    @EnvironmentObject var store: FridgeStore

    var body: some View {
        List {
            if store.receipts.isEmpty {
                Text("还没有扫描过小票。买菜回来在主界面点「小票」，拍一下购物小票就会记在这里。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.receipts) { record in
                DisclosureGroup {
                    ForEach(record.lines) { line in
                        HStack {
                            Text(line.name)
                            Spacer()
                            Text(qtyText(line.qty) + line.unit)
                                .foregroundStyle(.secondary)
                            Text(moneyText(line.price, record.currency))
                                .monospacedDigit()
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                        .font(.subheadline)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.store.isEmpty ? "购物小票" : record.store)
                            .font(.headline)
                        Text(record.date + " · " + String(record.lines.count) + " 样食品 · 合计 " + moneyText(record.total, record.currency))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                store.receipts.remove(atOffsets: offsets)
            }
        }
        .navigationTitle("购物记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var store: FridgeStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = Keychain.get("apiKey")
    @AppStorage("model") private var model: String = defaultModel

    @State private var shareCode: String = ""
    @State private var sbURL: String = ""
    @State private var sbKey: String = ""
    @State private var connecting = false
    @State private var syncError: String?
    @State private var copied = false

    private func connect(_ cfg: SyncConfig?) {
        guard let cfg = cfg else {
            syncError = "填写的内容不完整或格式不对。"
            return
        }
        connecting = true
        syncError = nil
        Task {
            do {
                try await store.connectSync(cfg)
            } catch {
                syncError = error.localizedDescription
            }
            connecting = false
        }
    }

    @ViewBuilder
    private var sharingSection: some View {
        if store.syncEnabled {
            Section {
                LabeledContent("状态", value: store.syncStatus.isEmpty ? "已连接" : store.syncStatus)
                Button(copied ? "已复制共享码" : "复制共享码") {
                    UIPasteboard.general.string = store.shareCode
                    copied = true
                }
                Button("立即同步") {
                    Task { await store.syncNow() }
                }
                Button("断开共享", role: .destructive) {
                    store.disconnectSync()
                }
            } header: {
                Text("家庭共享")
            } footer: {
                Text("把共享码发到另一台手机（微信、隔空投送都行），在那台手机的这个位置粘贴就能连上同一个冰箱。拿到共享码的人都能查看和修改清单，不要发到公开的地方。")
            }
        } else {
            Section {
                TextField("粘贴共享码", text: $shareCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("用共享码加入") {
                    connect(SyncConfig.fromShareCode(shareCode))
                }
                .disabled(connecting || shareCode.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("家庭共享 · 加入已有的冰箱")
            }

            Section {
                TextField("Project URL", text: $sbURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Publishable key", text: $sbKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("创建共享冰箱") {
                    connect(SyncConfig.make(url: sbURL, key: sbKey))
                }
                .disabled(connecting || sbURL.isEmpty || sbKey.isEmpty)
                if connecting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在连接…").foregroundStyle(.secondary)
                    }
                }
                if let syncError = syncError {
                    Text(syncError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("家庭共享 · 第一台手机")
            } footer: {
                Text("第一台手机填 Supabase 项目的地址和密钥来创建；之后其他手机只需要粘贴共享码。连接后，这台手机上已有的食材会自动上传合并。")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ReceiptHistoryView()
                    } label: {
                        LabeledContent("购物记录", value: String(store.receipts.count) + " 张小票")
                    }
                }

                sharingSection

                Section {
                    Stepper("提前 \(store.remindDays) 天提醒", value: $store.remindDays, in: 1...14)
                    Button("打开系统通知设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("到期提醒")
                } footer: {
                    Text("每天早上 9 点，有食材快到期或当天到期时会发通知。收不到的话，请在系统设置里允许本 app 发送通知。")
                }

                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("拍照识别")
                } footer: {
                    Text("拍照识别使用 Claude API，需要填写你自己的 API 密钥。密钥只保存在这台手机的钥匙串里。模型一栏一般不用改。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Keychain.set("apiKey", apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
            .onDisappear {
                Keychain.set("apiKey", apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
