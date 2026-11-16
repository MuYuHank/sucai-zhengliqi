import SwiftUI
import OrganizerCore

struct SearchSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("搜索归档")
                .font(.title3.weight(.semibold))
            TextField("原名、项目、平台、发布状态、版本或路径", text: $model.searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.runSearch() }
            if model.searchHits.isEmpty {
                ContentUnavailableView("没有匹配", systemImage: "magnifyingglass", description: Text("归档之后可以用原名搜到改过名的文件。"))
            } else {
                List(model.searchHits) { hit in
                    Button {
                        model.reveal(hit.path)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.fileName).font(.body.weight(.medium))
                            Text("\(hit.originalName) · \(hit.projectTag.isEmpty ? "未分项目" : hit.projectTag) · \(hit.publishStatus.isEmpty ? hit.contentClass : hit.publishStatus) · \(hit.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(hit.path)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("搜索") { model.runSearch() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("关闭") { model.searchOpen = false }
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
        .onAppear { model.runSearch() }
    }
}

struct ReportsPage: View {
    @Bindable var model: AppModel
    @State private var tag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("空间").font(.headline)
                Text(model.spaceSummary.isEmpty ? "还没有索引。完成一次真正的移动后，这里会列出最大的文件和可以收回的渲染帧、历史版本、缓存。" : model.spaceSummary)
                    .foregroundStyle(.secondary)
                if !model.staleVideos.isEmpty {
                    Text("待发布超过 \(model.desk.pendingVideoDays) 天").font(.headline)
                    ForEach(model.staleVideos) { video in
                        Text("\(video.fileName) · \(video.path)")
                            .font(.caption.monospaced())
                    }
                }
                Text("本周").font(.headline)
                Text(model.weeklyMarkdown.isEmpty ? "周日会把周报写到桌面的「产物整理器报告」。" : model.weeklyMarkdown)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Button("现在写周报") { model.writeWeeklyReport() }
                Divider()
                Text("交付打包").font(.headline)
                TextField("项目标签，例如 FCCV1", text: $tag)
                    .textFieldStyle(.roundedBorder)
                Button("打包这个项目的最新版本") { model.makeDelivery(tag: tag) }
                    .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("压缩包里带 清单.json，每项有大小和 SHA256。历史版本不会打进去。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("报告")
        .onAppear { model.refreshReports() }
    }
}

struct DeskSettings: View {
    @Bindable var model: AppModel
    @State private var ruleName = ""
    @State private var ruleExt = ""
    @State private var rulePath = ""
    @State private var ruleSlot: DeskSlot = .finishedImage
    @State private var tag = ""
    @State private var importText = ""
    @State private var importPlatform: PublishPlatform = .youtube
    @State private var secret = ""

    var body: some View {
        Group {
            Section("桌面文件夹") {
                Text("这些相对路径写在产物库下面。产物库默认是桌面。改完会在下一次扫描时使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(DeskSlot.allCases) { slot in
                    TextField(slot.title, text: binding(slot))
                        .font(.body.monospaced())
                }
                Stepper(value: $model.desk.pendingVideoDays, in: 1...180) {
                    Text("待发布提醒 \(model.desk.pendingVideoDays) 天")
                }
                .onChange(of: model.desk.pendingVideoDays) { _, _ in model.savePreferences() }
                Toggle("整理乱七八糟的文件名", isOn: $model.desk.renameMessyNames)
                    .onChange(of: model.desk.renameMessyNames) { _, _ in model.savePreferences() }
                Toggle("不确定的文件问本地模型（默认关，只连本机）", isOn: $model.desk.localAIEnabled)
                    .onChange(of: model.desk.localAIEnabled) { _, _ in model.savePreferences() }
                TextField("Ollama 地址", text: $model.desk.ollamaEndpoint)
                    .onSubmit { model.savePreferences() }
            }
            Section("归档规则") {
                Text("从上到下匹配。名称包含、扩展名、路径三者里写了的都要满足。空规则不会匹配所有文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.desk.rules) { rule in
                    HStack {
                        Text(rule.note.isEmpty ? "\(rule.nameContains) \(rule.extensions.joined(separator: ",")) → \(rule.slot.title)" : rule.note)
                            .lineLimit(1)
                        Spacer()
                        Button("上移") { model.moveRoute(rule.id, up: true) }
                        Button("下移") { model.moveRoute(rule.id, up: false) }
                        Button("删除") { model.removeRoute(rule.id) }
                    }
                }
                TextField("名称包含", text: $ruleName)
                TextField("扩展名，用逗号分隔", text: $ruleExt)
                TextField("路径包含", text: $rulePath)
                Picker("放到", selection: $ruleSlot) {
                    ForEach(DeskSlot.allCases) { slot in
                        Text(slot.title).tag(slot)
                    }
                }
                Button("添加规则") {
                    model.addRoute(name: ruleName, extensions: ruleExt, path: rulePath, slot: ruleSlot)
                    ruleName = ""
                    ruleExt = ""
                    rulePath = ""
                }
            }
            Section("项目标签") {
                Text("内置 FCCV1、案头、YUUKI，也可以自己加。只有这些名字，或带 package.json、.git、README 的项目目录，才会写进标签和重命名。Downloads、tmp、src 这类文件夹不会。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.desk.extraTags, id: \.self) { item in
                    Text(item)
                }
                TextField("再加一个标签", text: $tag)
                Button("添加标签") {
                    model.addTag(tag)
                    tag = ""
                }
            }
            Section("发布平台") {
                HStack(spacing: 8) {
                    if model.platformBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.platformBusy && !model.platformProgress.isEmpty ? model.platformProgress : model.oauthNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.platformBusy {
                        Button("取消") { model.cancelPlatformSync() }
                    }
                }
                TextField("YouTube Client ID", text: $model.desk.youtubeClientID)
                TextField("TikTok Client ID", text: $model.desk.tiktokClientID)
                TextField("Facebook Client ID", text: $model.desk.facebookClientID)
                SecureField("Client Secret，写入钥匙串", text: $secret)
                HStack {
                    Button("保存 YouTube 密钥") { model.saveClientSecret(.youtube, secret: secret); secret = "" }
                    Button("保存 TikTok 密钥") { model.saveClientSecret(.tiktok, secret: secret); secret = "" }
                    Button("保存 Facebook 密钥") { model.saveClientSecret(.facebook, secret: secret); secret = "" }
                }
                TextField("浏览器返回的 code", text: $model.oauthCode)
                HStack {
                    Button("打开 YouTube 授权") { model.savePreferences(); model.authorize(.youtube) }
                    Button("换取令牌") { model.exchangeCode(.youtube) }
                        .disabled(model.platformBusy)
                    Button("同步") { model.syncPlatform(.youtube) }
                        .disabled(model.platformBusy)
                }
                HStack {
                    Button("打开 TikTok 授权") { model.savePreferences(); model.authorize(.tiktok) }
                    Button("换取令牌") { model.exchangeCode(.tiktok) }
                        .disabled(model.platformBusy)
                    Button("同步") { model.syncPlatform(.tiktok) }
                        .disabled(model.platformBusy)
                }
                HStack {
                    Button("打开 Facebook 授权") { model.savePreferences(); model.authorize(.facebook) }
                    Button("换取令牌") { model.exchangeCode(.facebook) }
                        .disabled(model.platformBusy)
                    Button("同步") { model.syncPlatform(.facebook) }
                        .disabled(model.platformBusy)
                }
                Text("也可以不连平台，把已发布列表贴在下面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("导入到", selection: $importPlatform) {
                    ForEach(PublishPlatform.allCases, id: \.self) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                TextEditor(text: $importText)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                Button("导入 CSV 或 JSON") { model.importPublished(text: importText, platform: importPlatform) }
            }
        }
    }

    private func binding(_ slot: DeskSlot) -> Binding<String> {
        Binding(
            get: { model.desk.relative(for: slot) },
            set: { value in
                model.desk.destinations[slot.rawValue] = value
                model.savePreferences()
            }
        )
    }
}
