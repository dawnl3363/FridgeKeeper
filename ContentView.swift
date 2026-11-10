import SwiftUI
import UIKit

enum ListFilter {
    case all, soon, expired
}

enum PickerSource: Int, Identifiable {
    case camera, library
    var id: Int { rawValue }
}

enum SheetKind: Identifiable {
    case add
    case edit(FoodItem)
    case scan(UIImage)
    case settings

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let item): return "edit-" + item.id.uuidString
        case .scan: return "scan"
        case .settings: return "settings"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: FridgeStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var filter: ListFilter = .all
    @State private var zone: String = "全部"
    @State private var query: String = ""
    @State private var sheet: SheetKind?
    @State private var pickerSource: PickerSource?
    @State private var pickedImage: UIImage?
    @State private var showPhotoChoice = false
    @State private var scanMode: ScanMode = .food
    @State private var needKey = false
    @State private var undoItem: FoodItem?

    private var expiredItems: [FoodItem] {
        store.items.filter { store.freshness($0) == .expired }
    }

    private var soonItems: [FoodItem] {
        store.items.filter { store.freshness($0) == .soon }
    }

    private var visibleItems: [FoodItem] {
        var list: [FoodItem]
        switch filter {
        case .all: list = store.items
        case .soon: list = soonItems
        case .expired: list = expiredItems
        }
        if zone != "全部" {
            list = list.filter { $0.zone == zone }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }
        return list.sorted { a, b in
            let da = a.daysLeft ?? 99999
            let db = b.daysLeft ?? 99999
            if da != db { return da < db }
            return a.name < b.name
        }
    }

    /// 宽屏（iPhone Duo 展开的内屏、iPad 尺寸）用左右两栏，普通手机和 Duo 外屏用单列
    private var isWide: Bool {
        hSize == .regular
    }

    var body: some View {
        NavigationStack {
            Group {
                if isWide {
                    wideLayout
                } else {
                    compactLayout
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("冰箱管家")
            .searchable(text: $query, prompt: "搜索食材")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
        }
        .task {
            // 打开着的时候每 10 秒同步一次，另一台手机的改动很快就能看到
            while !Task.isCancelled {
                await store.syncNow()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.syncNow() }
            }
        }
        .confirmationDialog("添加照片", isPresented: $showPhotoChoice, titleVisibility: .hidden) {
            Button("拍照") { startPick(.camera) }
            Button("从相册选择") { startPick(.library) }
            Button("取消", role: .cancel) {}
        }
        .alert("还没有填写识别密钥", isPresented: $needKey) {
            Button("去设置") { sheet = .settings }
            Button("取消", role: .cancel) {}
        } message: {
            Text("拍照识别需要一个 Claude API 密钥，填一次就可以一直用。")
        }
        .fullScreenCover(item: $pickerSource, onDismiss: {
            if let image = pickedImage {
                pickedImage = nil
                sheet = .scan(image)
            }
        }) { source in
            ImagePicker(source: source == .camera ? .camera : .photoLibrary) { image in
                pickedImage = image
            }
            .ignoresSafeArea()
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .add:
                EditItemView(item: newItem(), isNew: true)
            case .edit(let item):
                EditItemView(item: item, isNew: false)
            case .scan(let image):
                ScanView(image: image, mode: scanMode)
            case .settings:
                SettingsView()
            }
        }
    }

    // MARK: - 两种布局

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summaryPane
                itemsPane
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            syncFooter
                .padding(.bottom, 12)
        }
        .refreshable {
            await store.syncNow()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let removed = undoItem {
                    undoBar(removed)
                }
                dock
            }
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左栏：提醒、统计、筛选和添加按钮，始终可见
            VStack(alignment: .leading, spacing: 12) {
                summaryPane
                Spacer(minLength: 0)
                if let removed = undoItem {
                    undoBar(removed)
                        .padding(.horizontal, -16)
                }
                sideButtons
                syncFooter
            }
            .padding(16)
            .frame(width: 340)

            Divider()

            // 右栏：食材清单，屏幕够宽时自动排成多列
            ScrollView {
                itemsPane
                    .padding(16)
            }
            .refreshable {
                await store.syncNow()
            }
        }
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            noticeView
            tiles
            Picker("位置", selection: $zone) {
                ForEach(["全部"] + allZones, id: \.self) { z in
                    Text(z).tag(z)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var itemsPane: some View {
        if visibleItems.isEmpty {
            emptyView
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 8, alignment: .top)], spacing: 8) {
                ForEach(visibleItems) { item in
                    ItemRow(
                        item: item,
                        freshness: store.freshness(item),
                        onEdit: { sheet = .edit(item) },
                        onMinus: { minus(item) },
                        onPlus: { store.changeQty(item.id, by: 1) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var syncFooter: some View {
        if store.syncEnabled {
            Text("家庭共享：" + (store.syncStatus.isEmpty ? "已连接" : store.syncStatus))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var sideButtons: some View {
        VStack(spacing: 10) {
            addButton("拍照添加", "camera.fill", prominent: true) { startScan(.food) }
            addButton("扫描小票", "doc.text.viewfinder", prominent: false) { startScan(.receipt) }
            addButton("手动添加", "plus", prominent: false) { sheet = .add }
        }
    }

    // MARK: - 小部件

    @ViewBuilder
    private var noticeView: some View {
        if !expiredItems.isEmpty || !soonItems.isEmpty {
            let color: Color = expiredItems.isEmpty ? .orange : .red
            VStack(alignment: .leading, spacing: 4) {
                if !expiredItems.isEmpty {
                    Text("已经过期：" + names(expiredItems))
                }
                if !soonItems.isEmpty {
                    Text("快到期了，尽快吃掉：" + names(soonItems))
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func names(_ list: [FoodItem]) -> String {
        let head = list.prefix(4).map { $0.name }.joined(separator: "、")
        return list.count > 4 ? head + " 等\(list.count)样" : head
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            tile(expiredItems.count, "已过期", .red, .expired)
            tile(soonItems.count, "\(store.remindDays)天内到期", .orange, .soon)
            tile(store.items.count, "全部食材", .green, .all)
        }
    }

    private func tile(_ count: Int, _ title: String, _ color: Color, _ target: ListFilter) -> some View {
        Button {
            filter = (filter == target && target != .all) ? .all : target
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(filter == target ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Text(store.items.isEmpty ? "拍一张冰箱的照片开始" : "没有符合条件的食材")
                .font(.headline)
            Text(store.items.isEmpty ? "点「拍照」自动认出里面的食材和大概的保质期；买菜回来点「小票」扫一下购物小票；也可以手动添加。" : "换个筛选条件试试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var dock: some View {
        HStack(spacing: 8) {
            addButton("拍照", "camera.fill", prominent: true) { startScan(.food) }
            addButton("小票", "doc.text.viewfinder", prominent: false) { startScan(.receipt) }
            addButton("手动", "plus", prominent: false) { sheet = .add }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func addButton(_ title: String, _ icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func startScan(_ mode: ScanMode) {
        scanMode = mode
        showPhotoChoice = true
    }

    private func undoBar(_ removed: FoodItem) -> some View {
        HStack {
            Text("\(removed.name) 吃完了，已移出冰箱")
                .font(.subheadline)
            Spacer()
            Button("撤销") {
                var back = removed
                if back.qty <= 0 { back.qty = 1 }
                store.upsert(back)
                undoItem = nil
            }
            .font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .task(id: removed.id) {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                undoItem = nil
            } catch {
            }
        }
    }

    // MARK: - 操作

    private func minus(_ item: FoodItem) {
        if let removed = store.changeQty(item.id, by: -1) {
            undoItem = removed
        }
    }

    private func newItem() -> FoodItem {
        var item = FoodItem()
        if zone != "全部" { item.zone = zone }
        item.expiry = daysFromNow(7)
        return item
    }

    private func startPick(_ source: PickerSource) {
        if Keychain.get("apiKey").isEmpty {
            needKey = true
            return
        }
        if source == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) {
            pickerSource = .library
        } else {
            pickerSource = source
        }
    }
}

// MARK: - 一行食材

struct ItemRow: View {
    let item: FoodItem
    let freshness: Freshness
    let onEdit: () -> Void
    let onMinus: () -> Void
    let onPlus: () -> Void

    private var dateText: String {
        guard let expiry = item.expiry else { return "" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: expiry) + " 到期"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onEdit) {
                HStack(spacing: 10) {
                    Text(item.emoji)
                        .font(.system(size: 26))
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.body.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(item.expiryLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(freshness.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(freshness.color.opacity(0.14))
                                .clipShape(Capsule())
                            Text(item.zone)
                            Text(dateText)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                Button(action: onMinus) {
                    Image(systemName: "minus")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("吃掉一个")

                VStack(spacing: 0) {
                    Text(item.qtyText)
                        .font(.body.weight(.bold))
                        .monospacedDigit()
                    Text(item.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 38)

                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("加一个")
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 10)
        .padding(.leading, 15)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(freshness.color)
                .frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 相机 / 相册

struct ImagePicker: UIViewControllerRepresentable {
    let source: UIImagePickerController.SourceType
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
