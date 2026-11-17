import AppKit
import OrganizerCore
import ServiceManagement
import SwiftUI

struct SettingsTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RecognitionSettings(model: model)
                .tabItem { Label("识别", systemImage: "sparkle.magnifyingglass") }
            DistributionSettings(model: model)
                .tabItem { Label("分发", systemImage: "tray.and.arrow.up") }
            DeskStructureSettings(model: model)
                .tabItem { Label("桌面结构", systemImage: "square.split.2x2") }
            RuleSettings(model: model)
                .tabItem { Label("规则", systemImage: "list.bullet") }
            PlatformSettings(model: model)
                .tabItem { Label("发布平台", systemImage: "paperplane") }
            SafetySettings(model: model)
                .tabItem { Label("安全", systemImage: "lock") }
        }
        .frame(minWidth: 600, minHeight: 480)
        .modifier(RecognitionQuoteDialog(window: .settings, model: model))
    }
}

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section("素材库") {
                LabeledContent("位置") {
                    PathLabel(
                        path: model.preferences.libraryRoot.isEmpty ? "未选择" : model.preferences.libraryRoot,
                        home: model.homeDirectory
                    )
                }
                Button("更换素材库…") { model.chooseLibrary() }
            }
            Section("外观") {
                Picker("外观", selection: Binding(
                    get: { AppearanceChoice.resolve(saved: model.preferences.appearance, arguments: CommandLine.arguments) },
                    set: { choice in
                        model.preferences.appearance = choice == .system ? nil : choice.rawValue
                        model.savePreferences()
                        AppAppearance.apply(choice)
                    }
                )) {
                    Text("跟随系统").tag(AppearanceChoice.system)
                    Text("浅色").tag(AppearanceChoice.light)
                    Text("深色").tag(AppearanceChoice.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("外观")
            }
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .accessibilityLabel("登录时启动")
                Text("需要从「素材整理器.app」打开才会记住。直接运行构建出来的二进制不会注册登录项。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("监视") {
                Toggle("监视扫描位置里的新文件", isOn: $model.preferences.watchEnabled)
                    .onChange(of: model.preferences.watchEnabled) { _, _ in model.savePreferences() }
                    .accessibilityLabel("监视扫描位置里的新文件")
                Text("新文件只会进入待整理，不会自动移动。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("快捷键") {
                LabeledContent("全局快捷键", value: model.hotkey.display)
                Button(model.capturingHotkey ? "请按下组合键，Esc 取消" : "录制新快捷键") {
                    toggleCapture()
                }
                Text("快捷键写在 ~/.chanwu/sealed。启动时不读钥匙串。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ExpandableFormSection(title: "高级") {
                if AppearanceChoice.launchOverride(arguments: CommandLine.arguments) != nil {
                    Text("命令行里的外观只对这一次启动有效，不会自己写进设置。重新打开后，会用已经保存的选择。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("安装标识") {
                    Text(model.installID)
                        .font(.body)
                        .textSelection(.enabled)
                }
                Text("偏好在 ~/.chanwu/preferences.json，桌面结构在 ~/.chanwu/desk.json，识别和分发在 ~/.chanwu/distribution.json。这些都不是钥匙串，也不是 OpenClaw 的配置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(Space.xs)
    }

    private func toggleCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            model.capturingHotkey = false
            return
        }
        model.capturingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    model.capturingHotkey = false
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    self.monitor = nil
                }
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return event
            }
            let display = HotkeyCapture.display(event: event)
            let carbon = HotkeyCapture.carbon(from: flags)
            let keyCode = UInt32(event.keyCode)
            Task { @MainActor in
                model.applyHotkey(keyCode: keyCode, modifiers: carbon, display: display)
                model.capturingHotkey = false
                if let monitor { NSEvent.removeMonitor(monitor) }
                self.monitor = nil
            }
            return nil
        }
    }
}

struct RecognitionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("置信度") {
                LabeledContent("最低置信度") {
                    Text("\(Int((model.preferences.minimumConfidence * 100).rounded()))%")
                        .monospacedDigit()
                }
                Slider(value: $model.preferences.minimumConfidence, in: 0.5...0.95, step: 0.01)
                    .onChange(of: model.preferences.minimumConfidence) { _, _ in model.savePreferences() }
                    .accessibilityLabel("最低置信度")
                HStack {
                    Text("更多文件")
                    Spacer()
                    Text("更准确")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text("这条滑块决定来源识别要有多把握，才会采用文件名里的工具标记。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("置信度显示为「低」的文件默认不勾选。那条线和这条滑块不是同一个数。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Toggle("连未识别来源的图片、视频、音频也放进预览", isOn: $model.preferences.includeUnidentifiedMedia)
                    .onChange(of: model.preferences.includeUnidentifiedMedia) { _, _ in model.savePreferences() }
                    .accessibilityLabel("连未识别来源的图片、视频、音频也放进预览")
                Stepper(value: $model.preferences.maxDepth, in: 0...32) {
                    Text("扫描深度 \(model.preferences.maxDepth) 层")
                }
                .onChange(of: model.preferences.maxDepth) { _, _ in model.savePreferences() }
                .accessibilityLabel("扫描深度")
            }
            Section("云端模型") {
                CloudRecognitionControls(model: model)
            }
            Section("本地模型") {
                Toggle("询问本机模型", isOn: $model.desk.localAIEnabled)
                    .onChange(of: model.desk.localAIEnabled) { _, _ in model.savePreferences() }
                    .accessibilityLabel("询问本机模型")
                TextField("地址", text: $model.desk.ollamaEndpoint)
                    .onChange(of: model.desk.ollamaEndpoint) { _, _ in model.savePreferences() }
                    .accessibilityLabel("本地模型地址")
                TextField("模型", text: $model.desk.ollamaModel)
                    .onChange(of: model.desk.ollamaModel) { _, _ in model.savePreferences() }
                    .accessibilityLabel("本地模型名称")
                Text("默认关闭。打开之后才会访问上面的地址。连接不上时只用规则判断。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(Space.xs)
    }
}

struct DeskStructureSettings: View {
    @Bindable var model: AppModel
    @State private var tagDraft = ""

    var body: some View {
        Form {
            ForEach(DeskCategory.allCases) { category in
                Section {
                    ForEach(slots(in: category)) { slot in
                        HStack(spacing: Space.xs) {
                            Image(systemName: slot.symbol)
                                .foregroundStyle(category.tint)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(slot.title)
                            Spacer(minLength: Space.sm)
                            Text(model.desk.destinations[slot.rawValue] ?? slot.defaultRelative)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("选择…") {
                                guard let path = FolderPicker.choose(prompt: "选择\(slot.title)") else { return }
                                model.setDestination(slot, absolutePath: path)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: category.symbol)
                            .accessibilityHidden(true)
                        Text(category.title)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(category.title)
                }
            }
            Section {
                Text("路径是素材库里的相对路径。已经在这些目录里的文件不会被再扫出来搬一次。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("项目标签") {
                Text("内置 \(ProjectTags.builtins.joined(separator: "、"))。只有这些名字，或带 package.json、.git、README 的项目目录，才会写进标签和重命名。Downloads、tmp、src 这类文件夹不会。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(model.desk.extraTags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Button("移除") { model.removeTag(tag) }
                    }
                }
                HStack {
                    TextField("添加标签", text: $tagDraft)
                    Button("添加") {
                        model.addTag(tagDraft)
                        tagDraft = ""
                    }
                    .disabled(tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
            }
            Section("重命名") {
                Toggle("把 image_1234 这类名字改成「项目_内容_日期」", isOn: $model.desk.renameMessyNames)
                    .onChange(of: model.desk.renameMessyNames) { _, _ in model.savePreferences() }
                Text("原名留在资料库里，搜索还能找到。没有项目标签时用「内容_日期」，不会写成「未分项目」。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Stepper(value: $model.desk.pendingVideoDays, in: 1...90) {
                    Text("待发布超过 \(model.desk.pendingVideoDays) 天就提醒")
                }
                .onChange(of: model.desk.pendingVideoDays) { _, _ in model.savePreferences() }
            }
        }
        .formStyle(.grouped)
        .padding(Space.xs)
    }

    private func slots(in category: DeskCategory) -> [DeskSlot] {
        DeskSlot.allCases.filter { DeskCategory.from(slot: $0) == category }
    }
}

private enum RuleKind: String, CaseIterable, Identifiable {
    case route
    case source
    var id: String { rawValue }
    var title: String { self == .route ? "目标" : "来源" }
}

private struct ShownRule: Identifiable {
    var id: String
    var kind: RuleKind
}

struct RuleSettings: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var sample = ""
    @State private var selection: String?
    @State private var editing = false
    @State private var draftKind: RuleKind = .route
    @State private var draftID: String?
    @State private var name = ""
    @State private var extensions = ""
    @State private var path = ""
    @State private var slot: DeskSlot = .otherMedia
    @State private var keyword = ""
    @State private var source: SourceTool = .comfyUI

    private var shown: [ShownRule] {
        model.desk.rules.map { ShownRule(id: $0.id, kind: .route) }
            + model.preferences.userRules.map { ShownRule(id: $0.id, kind: .source) }
    }

    var body: some View {
        Form {
            Section {
                TextField("试一试：输入文件名或路径", text: $sample)
                if !tryout.isEmpty {
                    Text(tryout)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                if shown.isEmpty {
                    VStack(spacing: Space.sm) {
                        Text("还没有自定义规则。内置识别覆盖不到的文件，可以按文件名、扩展名或路径指定去处。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("添加规则") { beginCreate() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
                } else {
                    List(selection: $selection) {
                        Section("目标规则") {
                            if model.desk.rules.isEmpty {
                                Text("还没有目标规则。")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.desk.rules) { rule in
                                ruleRow(ShownRule(id: rule.id, kind: .route))
                                    .tag(rule.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { beginEdit(ShownRule(id: rule.id, kind: .route)) }
                            }
                            .onMove { model.moveRoutes(from: $0, to: $1) }
                        }
                        Section("来源规则") {
                            if model.preferences.userRules.isEmpty {
                                Text("还没有来源规则。")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.preferences.userRules) { rule in
                                ruleRow(ShownRule(id: rule.id, kind: .source))
                                    .tag(rule.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { beginEdit(ShownRule(id: rule.id, kind: .source)) }
                            }
                            .onMove { model.moveUserRules(from: $0, to: $1) }
                        }
                    }
                    .frame(minHeight: 220)
                    Text("目标规则和来源规则分开排序。拖到另一组不会改类型，松手会回到原来的组。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button {
                            beginCreate()
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("添加规则")
                        Button {
                            deleteSelection()
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除规则")
                        .disabled(selection == nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(Space.xs)
        .sheet(isPresented: $editing) {
            ruleSheet
        }
    }

    @ViewBuilder
    private func ruleRow(_ item: ShownRule) -> some View {
        HStack(spacing: Space.sm) {
            Text(item.kind.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Text(sentence(item))
                .lineLimit(2)
            Spacer(minLength: Space.xs)
        }
        .contextMenu {
            Button("编辑") { beginEdit(item) }
            Button("删除") { delete(item) }
        }
    }

    private var ruleSheet: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(draftID == nil ? "添加规则" : "编辑规则")
                .font(.title3.weight(.semibold))
            Picker("类型", selection: $draftKind) {
                ForEach(RuleKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(draftID != nil)
            .accessibilityLabel("规则类型")
            if draftKind == .route {
                TextField("名称包含", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("名称包含")
                TextField("扩展名，逗号分隔", text: $extensions)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("扩展名")
                TextField("路径包含", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("路径包含")
                Picker("目标", selection: $slot) {
                    ForEach(DeskSlot.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .accessibilityLabel("目标")
            } else {
                TextField("来源关键词", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("来源关键词")
                Picker("来源", selection: $source) {
                    ForEach(SourceTool.allCases.filter { $0 != .unknown }, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .accessibilityLabel("来源")
            }
            HStack {
                Spacer()
                Button("取消") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveDraft() }
                    .buttonStyle(StableProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.lg)
        .frame(width: 440)
    }

    private var tryout: String {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let rule = RulesEngine.firstMatch(model.desk.rules, name: text, path: text),
           let index = model.desk.rules.firstIndex(where: { $0.id == rule.id }) {
            let category = DeskCategory.from(slot: rule.slot)
            return "会放到：\(category.title) › \(rule.slot.title)（第 \(index + 1) 条规则）"
        }
        return "没有规则命中，会按识别结果自己决定。"
    }

    private func sentence(_ item: ShownRule) -> String {
        if item.kind == .route, let rule = model.desk.rules.first(where: { $0.id == item.id }) {
            let name = rule.nameContains.isEmpty ? "任意名称" : "名称含 \(rule.nameContains)"
            let ext = rule.extensions.isEmpty ? "" : " · \(rule.extensions.joined(separator: "、"))"
            let path = rule.pathUnder.isEmpty ? "" : " · 路径含 \(rule.pathUnder)"
            return "\(name)\(ext)\(path)，放到\(rule.slot.title)"
        }
        if let rule = model.preferences.userRules.first(where: { $0.id == item.id }) {
            return "文件名含 \(rule.keyword) 时，识别为\(rule.source.displayName)"
        }
        return ""
    }

    private func beginCreate() {
        draftID = nil
        draftKind = .route
        name = ""
        extensions = ""
        path = ""
        slot = .otherMedia
        keyword = ""
        source = .comfyUI
        editing = true
    }

    private func beginEdit(_ item: ShownRule) {
        draftID = item.id
        draftKind = item.kind
        if item.kind == .route, let rule = model.desk.rules.first(where: { $0.id == item.id }) {
            name = rule.nameContains
            extensions = rule.extensions.joined(separator: ",")
            path = rule.pathUnder
            slot = rule.slot
        }
        if item.kind == .source, let rule = model.preferences.userRules.first(where: { $0.id == item.id }) {
            keyword = rule.keyword
            source = rule.source
        }
        editing = true
    }

    private func saveDraft() {
        if draftKind == .route {
            let parsedExtensions = extensions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let draftID, let index = model.desk.rules.firstIndex(where: { $0.id == draftID }) {
                model.desk.rules[index].nameContains = name
                model.desk.rules[index].extensions = parsedExtensions
                model.desk.rules[index].pathUnder = path
                model.desk.rules[index].slot = slot
            } else {
                model.addRoute(name: name, extensions: parsedExtensions.joined(separator: ","), path: path, slot: slot)
            }
        } else if let draftID, let index = model.preferences.userRules.firstIndex(where: { $0.id == draftID }) {
            model.preferences.userRules[index].keyword = keyword
            model.preferences.userRules[index].source = source
        } else {
            model.addRule(keyword: keyword, source: source)
        }
        model.savePreferences()
        editing = false
    }

    private func deleteSelection() {
        guard let selection, let item = shown.first(where: { $0.id == selection }) else { return }
        delete(item)
    }

    private func delete(_ item: ShownRule) {
        if item.kind == .route, let rule = model.desk.rules.first(where: { $0.id == item.id }) {
            guard let index = model.desk.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            model.removeRoute(rule.id)
            undoManager?.registerUndo(withTarget: model) { target in
                Task { @MainActor in target.restoreRoute(rule, at: index) }
            }
            undoManager?.setActionName("删除规则")
        } else if let rule = model.preferences.userRules.first(where: { $0.id == item.id }),
                  let index = model.preferences.userRules.firstIndex(where: { $0.id == item.id }) {
            model.removeRule(rule.id)
            undoManager?.registerUndo(withTarget: model) { target in
                Task { @MainActor in target.restoreRule(rule, at: index) }
            }
            undoManager?.setActionName("删除规则")
        }
        if selection == item.id { selection = nil }
    }
}

struct PlatformSettings: View {
    @Bindable var model: AppModel
    @State private var platform: PublishPlatform = .youtube
    @State private var secrets: [String: String] = [:]
    @State private var codes: [String: String] = [:]

    var body: some View {
        Form {
            Picker("平台", selection: $platform) {
                ForEach(PublishPlatform.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Section {
                stepHeading(1, "填写 \(credentialIDTitle)", done: hasClientID, doneText: "已填写")
                TextField(credentialIDTitle, text: clientID, prompt: Text("粘贴 \(credentialIDTitle)"))
                    .accessibilityLabel(credentialIDTitle)
            }
            Section {
                stepHeading(2, "保存 \(credentialSecretTitle)", done: secretSaved, doneText: "已存入钥匙串")
                SecureField(credentialSecretTitle, text: secret, prompt: Text("粘贴 \(credentialSecretTitle)"))
                    .accessibilityLabel(credentialSecretTitle)
                platformButton("保存密钥", primary: primaryAction == .saveSecret, disabled: secret.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    model.saveClientSecret(platform, secret: secrets[platform.rawValue] ?? "")
                }
            }
            Section {
                stepHeading(3, "授权并换取令牌", done: linked, doneText: "已存入钥匙串")
                TextField("授权码", text: code, prompt: Text("浏览器返回的 code"))
                    .accessibilityLabel("授权码")
                HStack {
                    platformButton("打开授权", primary: primaryAction == .authorize, disabled: !hasClientID) {
                        model.authorize(platform)
                    }
                    platformButton("换取令牌", primary: primaryAction == .exchange, disabled: model.platformBusy || code.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        model.oauthCode = codes[platform.rawValue] ?? ""
                        model.exchangeCode(platform)
                    }
                }
            }
            Section {
                stepHeading(4, "同步发布记录", done: hasSynced, doneText: "已同步")
                HStack {
                    platformButton("同步", primary: primaryAction == .sync, disabled: model.platformBusy || !linked) {
                        model.syncPlatform(platform)
                    }
                    if model.platformBusy {
                        Button("取消") { model.cancelPlatformSync() }
                            .buttonStyle(.bordered)
                    }
                }
                if model.platformBusy {
                    ProgressView(model.platformProgress.isEmpty ? "正在连接…" : model.platformProgress)
                }
                LabeledContent("上次同步") {
                    Text(syncedText)
                }
            }
            if !model.oauthNote.isEmpty {
                Text(model.oauthNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("回调地址") {
                HStack(spacing: Space.xs) {
                    Text(OAuthEndpoints.callbackURL)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                        .accessibilityLabel("回调地址")
                        .accessibilityValue(OAuthEndpoints.callbackURL)
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(OAuthEndpoints.callbackURL, forType: .string)
                    }
                    .accessibilityLabel("复制回调地址")
                }
            }
            Text("令牌只存在钥匙串里。不想连接，也可以在「发布跟踪」里导入 CSV。授权之后，把浏览器地址栏里的 code 贴回到上面的授权码。这个程序不会自己打开回调页面。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(Space.xs)
        .onAppear { model.refreshPlatformLink() }
    }

    private enum PlatformAction: Equatable {
        case saveSecret
        case authorize
        case exchange
        case sync
    }

    private var hasClientID: Bool {
        !clientID.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var secretSaved: Bool { model.platformSecretSaved[platform.rawValue] == true }
    private var linked: Bool { model.platformLinked[platform.rawValue] == true }
    private var hasSynced: Bool { model.platformSyncedAt[platform.rawValue] != nil }

    /// 同一页只亮下一步。前面的步骤还没做完时，后面的按钮保持普通样式。
    private var primaryAction: PlatformAction {
        if !secretSaved { return .saveSecret }
        if !linked {
            let pasted = code.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return pasted.isEmpty ? .authorize : .exchange
        }
        return .sync
    }

    private func stepHeading(_ number: Int, _ title: String, done: Bool, doneText: String) -> some View {
        HStack(spacing: Space.xs) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(done ? Color.green.opacity(0.18) : Color.primary.opacity(0.08)))
            Text(title)
                .font(.body.weight(.semibold))
            Spacer(minLength: Space.xs)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(doneText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? "第 \(number) 步，\(title)，\(doneText)" : "第 \(number) 步，\(title)")
    }

    @ViewBuilder
    private func platformButton(_ title: String, primary: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        if primary {
            Button(title, action: action)
                .buttonStyle(StableProminentButtonStyle())
                .disabled(disabled)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .disabled(disabled)
        }
    }

    private var syncedText: String {
        guard let date = model.platformSyncedAt[platform.rawValue] else { return "还没有同步" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var credentialIDTitle: String {
        switch platform {
        case .youtube: return "Client ID"
        case .tiktok: return "Client Key"
        case .facebook: return "App ID"
        }
    }

    private var credentialSecretTitle: String {
        switch platform {
        case .youtube: return "Client Secret"
        case .tiktok: return "Client Secret"
        case .facebook: return "App Secret"
        }
    }

    private var clientID: Binding<String> {
        switch platform {
        case .youtube:
            return Binding(get: { model.desk.youtubeClientID }, set: { model.desk.youtubeClientID = $0; model.savePreferences() })
        case .tiktok:
            return Binding(get: { model.desk.tiktokClientID }, set: { model.desk.tiktokClientID = $0; model.savePreferences() })
        case .facebook:
            return Binding(get: { model.desk.facebookClientID }, set: { model.desk.facebookClientID = $0; model.savePreferences() })
        }
    }

    private var secret: Binding<String> {
        Binding(
            get: { secrets[platform.rawValue] ?? "" },
            set: { secrets[platform.rawValue] = $0 }
        )
    }

    private var code: Binding<String> {
        Binding(
            get: { codes[platform.rawValue] ?? "" },
            set: { codes[platform.rawValue] = $0 }
        )
    }
}

struct SafetySettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("移动") {
                Toggle("其他磁盘上的文件留在原处，不复制", isOn: $model.desk.moveOnly)
                    .onChange(of: model.desk.moveOnly) { _, _ in model.savePreferences() }
                    .accessibilityLabel("其他磁盘上的文件留在原处")
                if !model.desk.moveOnly {
                    Text("关掉之后，其他磁盘上的文件会复制并保留源文件。撤销不会删除那份副本。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("演练") {
                Button("下次确认重新演练") { model.requireRehearsalAgain() }
                Text("每个素材库的第一次确认只演练，不移动文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ExpandableFormSection(title: "高级") {
                    Text("演练状态写在该库的 .chanwu/state.json。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(Space.xs)
    }
}

/// 设置里的「高级」用按钮展开。macOS 的 DisclosureGroup 没有辅助功能的按下动作。
struct ExpandableFormSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .accessibilityHint(expanded ? "收起\(title)" : "展开\(title)")
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(true)
            .accessibilityAction(.default) { expanded.toggle() }

            if expanded {
                content()
            }
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .contain)
    }
}
