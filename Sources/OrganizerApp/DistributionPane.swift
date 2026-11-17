import OrganizerCore
import SwiftUI

struct RecognitionQuoteDialog: ViewModifier {
    var window: RecognitionQuoteWindow
    @Bindable var model: AppModel

    private var presented: Bool {
        model.recognitionQuote != nil && model.recognitionQuoteWindow == window
    }

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(presented)
                .accessibilityHidden(presented)
            if presented {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                    RecognitionQuoteSheet(model: model)
                        .padding(Space.lg)
                        .frame(maxWidth: 520)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityLabel("识别这些文件？")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        }
        .onDisappear {
            if RecognitionPromptSession.shouldClear(active: model.recognitionQuoteWindow, disappeared: window) {
                model.cancelRecognitionQuote()
            }
        }
    }
}

struct RecognitionQuoteSheet: View {
    @Bindable var model: AppModel
    @State private var acceptedRisk = false
    @FocusState private var cancelFocused: Bool

    private var needsRiskAcknowledgement: Bool {
        model.recognitionQuote?.recommendsLightweightAgent == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("识别这些文件？")
                .font(.title2.weight(.semibold))
            Text(model.recognitionQuote?.sentence ?? "")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let names = model.recognitionQuote?.names, !names.isEmpty {
                DisclosureGroup("查看文件（\(names.count)）") {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            if model.recognitionQuote?.recommendsLightweightAgent == true {
                Label("这个代理带工具，文件内容可能让它自己发消息。", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.placeholderWarning)
                Toggle("我知道这次可能会自己发消息", isOn: $acceptedRisk)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.cancelRecognitionQuote() }
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button("开始识别") { model.runQuotedRecognition() }
                    .buttonStyle(StableProminentButtonStyle())
                    .disabled(needsRiskAcknowledgement && !acceptedRisk)
            }
        }
        .padding(Space.lg)
        .frame(minWidth: 440)
        .onAppear { cancelFocused = true }
    }
}

struct CloudRecognitionControls: View {
    @Bindable var model: AppModel

    private var blocked: Bool {
        RecognitionAgent.isMainOrEmpty(model.distribution.agent) && !model.distribution.allowMainAgent
    }

    var body: some View {
        Toggle("把抽出的文字发给云端模型", isOn: $model.distribution.enabled)
            .onChange(of: model.distribution.enabled) { _, _ in model.saveDistribution() }
            .accessibilityLabel("把抽出的文字发给云端模型")
        Text("默认关闭。打开之后，才会在这台 Mac 上抽出文字。大约前 4000 字，加上文件名和路径，经本机 OpenClaw（127.0.0.1:18789）发给云端模型。看起来像密钥的文件不会送出。这里不填写、也不保存 API 密钥。程序不读取 OpenClaw 的配置。OpenClaw 不可用时，仍按原来的规则分类，不改文件。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        TextField("代理", text: $model.distribution.agent, prompt: Text("不带工具的代理名"))
            .onChange(of: model.distribution.agent) { _, _ in
                if !RecognitionAgent.isMainOrEmpty(model.distribution.agent) {
                    model.distribution.allowMainAgent = false
                }
                model.saveDistribution()
            }
            .accessibilityLabel("识别代理")
        Text("新建一个不带工具的代理：在 OpenClaw 里增加一个代理，不要给它消息发送、会话投递或其他工具，只让它回答文字。把那个代理的名字填在这里。不要填 main。具体菜单以你安装的 OpenClaw 说明为准。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        if RecognitionAgent.isMainOrEmpty(model.distribution.agent) {
            Label("main 会带上自己的工具。文件内容不可信，有可能让它自己发消息。换一个不带工具的代理更安全。", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Color.placeholderWarning)
            if model.distribution.allowMainAgent {
                Text("已允许手动识别。移动文件之后仍然不会自动识别。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("撤销允许") {
                    model.distribution.allowMainAgent = false
                    model.saveDistribution()
                }
                .buttonStyle(.bordered)
            } else {
                Button("我了解风险，允许用这个代理识别") {
                    model.distribution.allowMainAgent = true
                    model.saveDistribution()
                }
            }
        }
        Group {
            TextField("命令", text: $model.distribution.cliPath, prompt: Text("~/.local/bin/openclaw"))
                .onChange(of: model.distribution.cliPath) { _, _ in model.saveDistribution() }
                .accessibilityLabel("识别命令")
            Stepper(value: $model.distribution.timeoutSeconds, in: 30...300, step: 10) {
                Text("识别超时 \(model.distribution.timeoutSeconds) 秒")
            }
            .onChange(of: model.distribution.timeoutSeconds) { _, _ in model.saveDistribution() }
            .accessibilityLabel("识别超时")
            Stepper(value: $model.distribution.retries, in: 0...3) {
                Text("识别失败后再试 \(model.distribution.retries) 次")
            }
            .onChange(of: model.distribution.retries) { _, _ in model.saveDistribution() }
            .accessibilityLabel("识别失败后重试次数")
            Text("这只重试识别。发送失败不会自动重试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(model.recognizing ? "正在识别…" : "识别未处理的文件") {
                model.recognizeOutstanding(from: .settings)
            }
            .disabled(model.recognizing || !model.distribution.enabled || blocked)
            .accessibilityLabel("识别未处理的文件")
            if !model.recognitionNote.isEmpty {
                Text(model.recognitionNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("识别状态，\(model.recognitionNote)")
            }
        }
    }
}

struct DistributionSettings: View {
    @Bindable var model: AppModel
    @State private var project = ""
    @State private var kind = ""
    @State private var tag = ""
    @State private var channel = ""
    @State private var account = ""
    @State private var target = ""
    @State private var alias = ""
    @State private var attachFile = false
    @State private var messageTemplate = DistributionConfig.defaultMessageTemplate

    var body: some View {
        Form {
            Section("分发规则") {
                Text("识别开关在「识别」里。项目、类型、标签里至少填一项，填了的都要满足。没有频道和收件人的规则不会匹配。这些都只写在 ~/.chanwu/distribution.json。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("微信收件人以 @im.wechat 结尾，且对方必须先给机器人发过消息。收件人区分大小写。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if model.distribution.rules.isEmpty {
                    Text("还没有规则。")
                        .foregroundStyle(.secondary)
                }
                ForEach($model.distribution.rules) { $rule in
                    DispatchRuleRow(model: model, rule: $rule)
                }
                .onChange(of: model.distribution.rules) { _, _ in model.saveDistribution() }
                Group {
                    TextField("项目", text: $project, prompt: Text("例如 FCCV1"))
                        .accessibilityLabel("新规则的项目")
                    TextField("类型或扩展名", text: $kind, prompt: Text("md 或 文档"))
                        .accessibilityLabel("新规则的类型或扩展名")
                    TextField("标签", text: $tag, prompt: Text("例如 封面"))
                        .accessibilityLabel("新规则的标签")
                    TextField("频道", text: $channel, prompt: Text("频道名称"))
                        .accessibilityLabel("新规则的频道")
                    TextField("账号", text: $account, prompt: Text("对方的账号，可留空"))
                        .accessibilityLabel("新规则的账号")
                    TextField("收件人", text: $target, prompt: Text("区分大小写"))
                        .accessibilityLabel("新规则的收件人")
                    TextField("显示名", text: $alias, prompt: Text("例如 自己"))
                        .accessibilityLabel("新规则的显示名")
                    Toggle("附带文件", isOn: $attachFile)
                        .accessibilityLabel("新规则附带文件")
                    TextField("消息模板", text: $messageTemplate, prompt: Text("不要写 {path}"), axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("新规则的消息模板")
                    pathWarning(messageTemplate)
                }
                Button("添加规则") { addRule() }
                    .disabled(!canAdd)
                if !model.sessionRecipients.isEmpty {
                    ForEach(Array(model.sessionRecipients.enumerated()), id: \.offset) { _, recipient in
                        Button(recipientLine(recipient)) {
                            channel = recipient.channel
                            account = recipient.account
                            target = recipient.target
                        }
                        .accessibilityLabel("用这个收件人填进新规则，\(recipient.channel)，\(recipient.target)")
                    }
                }
                Button(model.loadingRecipients ? "正在读取会话…" : "从 OpenClaw 会话里读取收件人") {
                    model.refreshRecipients()
                }
                .disabled(model.loadingRecipients || model.distribution.agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !model.sessionNote.isEmpty {
                    Text(model.sessionNote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("读到的收件人要点一下才会填进上面的空格，不会自动保存，也不会自动发送。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("待分发") {
                Text("点发送才会发出，发出后不能撤销。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ExpandableFormSection(title: "高级") {
                TextField("PATH 前缀 1", text: prefixBinding(0), prompt: Text("~/.local/bin"))
                    .accessibilityLabel("PATH 前缀 1")
                TextField("PATH 前缀 2", text: prefixBinding(1))
                    .accessibilityLabel("PATH 前缀 2")
                Text("默认只把 ~/.local/bin 加到 PATH 前面。第二个可以留空，需要 Node 或其他命令时再填。不会打印环境变量，也不会备份 OpenClaw 的配置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if DistributionConfig.offersPathReset(model.distribution.pathPrefixes) {
                    Button("恢复默认 PATH") {
                        model.distribution.pathPrefixes = DistributionConfig.defaultPathPrefixes
                        model.saveDistribution()
                    }
                    .accessibilityLabel("恢复默认 PATH")
                    Text("不会自动改已经保存的 PATH。点了以后只保留 ~/.local/bin，其他设置不动。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                TextField("参数模板", text: $model.distribution.sendTemplate, axis: .vertical)
                    .lineLimit(3...6)
                    .onChange(of: model.distribution.sendTemplate) { _, _ in model.saveDistribution() }
                    .accessibilityLabel("发送命令模板")
                let rejected = SendCommand.unexpectedTokens(model.distribution.sendTemplate)
                if !rejected.isEmpty {
                    Text("这些不会发出去：\(rejected.joined(separator: "、"))。")
                        .font(.subheadline)
                        .foregroundStyle(Color.placeholderWarning)
                }
                Text("发送命令由程序组装成 message send。频道、账号和收件人用规则里的。正文整段作为 --message 的值。模板只能附加 --reply-to、--thread-id、--silent、--pin、--gif-playback、--force-document、--verbose。演练由程序加上 --dry-run。-t、--to、--deliver、--presentation、--delivery 和环境变量不会发出去。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(Space.xs)
    }

    private var canAdd: Bool {
        let hasConstraint = !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAddress = !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasConstraint && hasAddress
    }

    private func addRule() {
        model.addDispatchRule(
            project: project,
            kind: kind,
            tag: tag,
            channel: channel,
            account: account,
            target: target,
            alias: alias,
            messageTemplate: messageTemplate,
            attachFile: attachFile
        )
        project = ""
        kind = ""
        tag = ""
        channel = ""
        account = ""
        target = ""
        alias = ""
        attachFile = false
        messageTemplate = DistributionConfig.defaultMessageTemplate
    }

    @ViewBuilder
    private func pathWarning(_ template: String) -> some View {
        if DispatchTemplate.sendsLocalPath(template) {
            Label("这个模板里的 {path} 会把本机绝对路径发给对方。", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Color.placeholderWarning)
        }
    }

    private func prefixBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                index < model.distribution.pathPrefixes.count ? model.distribution.pathPrefixes[index] : ""
            },
            set: { value in
                var prefixes = model.distribution.pathPrefixes
                while prefixes.count <= index { prefixes.append("") }
                prefixes[index] = value
                model.distribution.pathPrefixes = prefixes
                model.saveDistribution()
            }
        )
    }

    private func recipientLine(_ recipient: KnownRecipient) -> String {
        let account = recipient.account.isEmpty ? "未填账号" : recipient.account
        return "\(recipient.channel) · \(account) · \(recipient.target)"
    }
}

private struct DispatchRuleRow: View {
    @Bindable var model: AppModel
    @Binding var rule: DispatchRule
    @State private var expanded = false

    private var summary: String { DispatchRuleSummary.line(rule) }

    private var sendsPath: Bool { DispatchTemplate.sendsLocalPath(rule.messageTemplate) }

    private var editedNames: [String] {
        model.distribution.pending.compactMap { item in
            guard item.ruleID == rule.id, item.bodyEdited else { return nil }
            guard item.message.contains(item.path) || DispatchTemplate.containsLocalAbsolutePath(item.message) else { return nil }
            return item.fileName
        }
    }

    private var accessibilityName: String {
        var parts = ["分发规则，\(summary)"]
        if sendsPath {
            parts.append("这个模板里的 {path} 会把本机绝对路径发给对方")
        }
        if !editedNames.isEmpty {
            parts.append("\(editedNames.joined(separator: "、")) 是你改过的，还留着本机路径")
        }
        return parts.joined(separator: "。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: Space.xs) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        if sendsPath {
                            Text("这个模板里的 {path} 会把本机绝对路径发给对方。")
                                .font(.subheadline)
                                .foregroundStyle(Color.placeholderWarning)
                                .multilineTextAlignment(.leading)
                        }
                        if !editedNames.isEmpty {
                            Text("\(editedNames.joined(separator: "、")) 是你改过的，还留着本机路径。请到待分发里点编辑，自己删掉。")
                                .font(.subheadline)
                                .foregroundStyle(Color.placeholderWarning)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .accessibilityHint(expanded ? "收起这条规则" : "展开这条规则")
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(true)
            .accessibilityAction(.default) { expanded.toggle() }
            .modifier(RemovePathAction(enabled: sendsPath) { model.removePath(fromRule: rule.id) })

            if sendsPath {
                Button("去掉路径") { model.removePath(fromRule: rule.id) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("去掉路径，\(summary)")
                    .accessibilityHint("从这条规则和还没改过的待分发里去掉本机路径。不用先展开。")
            }

            if expanded {
                ruleFields
                HStack {
                    Spacer()
                    Button("删除这条规则") { model.removeDispatchRule(rule.id) }
                }
            }
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var ruleFields: some View {
        TextField("项目", text: $rule.project, prompt: Text("例如 FCCV1"))
            .accessibilityLabel("规则项目")
        TextField("类型或扩展名", text: $rule.kind, prompt: Text("md 或 文档"))
            .accessibilityLabel("规则类型或扩展名")
        TextField("标签", text: $rule.tag, prompt: Text("例如 封面"))
            .accessibilityLabel("规则标签")
        TextField("频道", text: $rule.channel, prompt: Text("频道名称"))
            .accessibilityLabel("规则频道")
        TextField("账号", text: $rule.account, prompt: Text("对方的账号，可留空"))
            .accessibilityLabel("规则账号")
        TextField("收件人", text: $rule.target, prompt: Text("区分大小写"))
            .accessibilityLabel("规则收件人")
        TextField("显示名", text: $rule.alias, prompt: Text("例如 自己"))
            .accessibilityLabel("规则显示名")
        Toggle("附带文件", isOn: $rule.attachFile)
            .accessibilityLabel("附带文件")
        TextField("消息模板", text: $rule.messageTemplate, prompt: Text("不要写 {path}"), axis: .vertical)
            .lineLimit(2...5)
            .accessibilityLabel("规则消息模板")
    }
}

private struct RemovePathAction: ViewModifier {
    var enabled: Bool
    var perform: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: "去掉路径", perform)
        } else {
            content
        }
    }
}

struct DispatchQueuePane: View {
    @Bindable var model: AppModel
    @State private var editingID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("点发送才会发出，发出后不能撤销。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DisclosureGroup("了解更多") {
                    Text("新的收件人第一次是演练发送，不会真正发出。演练成功之后，下一次才是发送。")
                    Text("微信收件人以 @im.wechat 结尾，且对方必须先给机器人发过消息。收件人区分大小写。")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !model.recognitionNote.isEmpty, !recognitionBlocked {
                    Text(model.recognitionNote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("识别状态，\(model.recognitionNote)")
                }
                if !model.dispatchNote.isEmpty {
                    Text(model.dispatchNote)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("分发状态，\(model.dispatchNote)")
                }
                if recognitionBlocked {
                    Label(RecognitionAgent.refusal, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Color.placeholderWarning)
                }
                Button(model.recognizing ? "正在识别…" : "识别未处理的文件") {
                    model.recognizeOutstanding(from: .main)
                }
                .disabled(model.recognizing || !model.distribution.enabled)
                .accessibilityLabel("识别未处理的文件")
                if model.distribution.pending.isEmpty {
                    ContentUnavailableView(
                        "没有待分发的文件",
                        systemImage: "tray.and.arrow.up",
                        description: Text("规则匹配到文件之后，会先放在这里。要你点发送，才会交给 OpenClaw。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ForEach(model.distribution.pending) { item in
                        queueRow(item)
                    }
                }
                if !model.distribution.log.isEmpty {
                    Text("发送记录")
                        .font(.title3.weight(.semibold))
                    ForEach(Array(model.distribution.log.suffix(12).reversed())) { entry in
                        logRow(entry)
                    }
                }
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(
            get: { model.confirmingSendID != nil },
            set: { if !$0 { model.confirmingSendID = nil } }
        )) {
            if let item = model.distribution.pending.first(where: { $0.id == model.confirmingSendID }) {
                SendConfirmationSheet(
                    item: item,
                    priorNotice: DispatchRetry.priorNotice(item: item, log: model.distribution.log, sent: model.distribution.sentIndex)
                ) {
                    model.confirmPendingSend()
                } cancel: {
                    model.confirmingSendID = nil
                }
                .id(item.id)
            }
        }
    }

    private var recognitionBlocked: Bool {
        RecognitionAgent.isMainOrEmpty(model.distribution.agent) && !model.distribution.allowMainAgent
    }

    private var firstRealSendID: String? {
        model.distribution.pending.first { item in
            !RehearsalBook.needsDryRun(
                channel: item.channel,
                account: item.account,
                target: item.target,
                rehearsed: model.distribution.rehearsedTargets
            ) && !DispatchMessageGuard.blocksSend(item.message)
        }?.id
    }

    private func queueRow(_ item: DispatchItem) -> some View {
        let dryRun = RehearsalBook.needsDryRun(
            channel: item.channel,
            account: item.account,
            target: item.target,
            rehearsed: model.distribution.rehearsedTargets
        )
        let title = DispatchBoard.primaryTitle(
            channel: item.channel,
            account: item.account,
            target: item.target,
            rehearsed: model.distribution.rehearsedTargets
        )
        let busy = model.sendingID == item.id
        let blocked = DispatchMessageGuard.blocksSend(item.message)
        let prominent = item.id == firstRealSendID
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(item.fileName)
                .font(.body.weight(.semibold))
            Text(addressLine(item))
                .font(.subheadline)
                .textSelection(.enabled)
            if !item.alias.isEmpty {
                Text(item.target)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            confidenceLine(item)
            Picker("项目", selection: projectBinding(item)) {
                if !item.project.isEmpty && !model.knownProjectTags().contains(item.project) {
                    Text(item.project).tag(item.project)
                }
                Text("不指定项目").tag("")
                ForEach(model.knownProjectTags(), id: \.self) { tag in
                    Text(tag).tag(tag)
                }
            }
            .accessibilityLabel("分发项目")
            if editingID == item.id {
                TextEditor(text: messageBinding(item))
                    .font(.body)
                    .frame(minHeight: 88)
                    .accessibilityLabel("消息")
            } else {
                Text(item.message.isEmpty ? "没有文字，只会发送附件" : item.message)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(item.attachment.isEmpty ? "不附带文件" : item.attachment)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if blocked {
                Label(DispatchMessageGuard.warning, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.placeholderWarning)
            }
            if DispatchTemplate.containsLocalAbsolutePath(item.message) {
                Label(item.bodyEdited ? "这条正文是你改过的，还留着本机路径。请点编辑删掉。" : "这条消息里有本机绝对路径，发出去对方会看到。", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.placeholderWarning)
            }
            HStack(spacing: Space.sm) {
                sendButton(item: item, title: busy ? "正在发送…" : title, dryRun: dryRun, busy: busy, blocked: blocked, prominent: prominent)
                if !dryRun {
                    Button("再演练一次") { model.sendDispatch(id: item.id, forceDryRun: true) }
                        .buttonStyle(.bordered)
                        .disabled(busy || blocked)
                }
                Button(editingID == item.id ? "完成" : "编辑") {
                    editingID = editingID == item.id ? nil : item.id
                }
                .disabled(busy)
                Button("跳过") { model.skipDispatch(id: item.id) }
                    .disabled(busy)
            }
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func sendButton(item: DispatchItem, title: String, dryRun: Bool, busy: Bool, blocked: Bool, prominent: Bool) -> some View {
        if dryRun {
            Button(title) { model.sendDispatch(id: item.id, forceDryRun: true) }
                .buttonStyle(.bordered)
                .disabled(busy || blocked)
                .accessibilityLabel(title)
        } else if prominent {
            Button(title) { model.confirmingSendID = item.id }
                .buttonStyle(StableProminentButtonStyle(neutralWhenDisabled: true))
                .disabled(busy || blocked)
                .accessibilityLabel(title)
        } else {
            Button(title) { model.confirmingSendID = item.id }
                .buttonStyle(.bordered)
                .disabled(busy || blocked)
                .accessibilityLabel(title)
        }
    }

    private func confidenceLine(_ item: DispatchItem) -> some View {
        let percent = Int((item.confidence * 100).rounded())
        let recognized = item.recognizedProject.trimmingCharacters(in: .whitespacesAndNewlines)
        let below = !recognized.isEmpty && item.confidence < model.preferences.minimumConfidence && recognized.caseInsensitiveCompare(item.project) != .orderedSame
        return Group {
            if recognized.isEmpty {
                EmptyView()
            } else if below {
                Text("识别为 \(recognized) · 置信度 \(percent)%，低于最低置信度，分发仍用原来的项目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("识别为 \(recognized) · 置信度 \(percent)%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addressLine(_ item: DispatchItem) -> String {
        let account = item.account.isEmpty ? "未填账号" : item.account
        let who = item.alias.isEmpty ? item.target : item.alias
        return "频道 \(item.channel) · 账号 \(account) · \(who)"
    }

    private func logRow(_ entry: DispatchLogEntry) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: logSymbol(entry.outcome))
                .foregroundStyle(logTint(entry.outcome))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("\(entry.outcome.title) · \(entry.fileName)")
                    .font(.body.weight(.medium))
                Text("\(entry.channel) · \(entry.account.isEmpty ? "未填账号" : entry.account) · \(entry.target)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(entry.detail)
                    .font(.subheadline)
                    .foregroundStyle(entry.outcome == .failed ? Color.placeholderWarning : .secondary)
                if entry.outcome == .failed, !DispatchRetry.superseded(entry, log: model.distribution.log, sent: model.distribution.sentIndex) {
                    Button("重试") { model.retryDispatch(entry) }
                        .disabled(model.sendingID != nil)
                }
                if entry.outcome == .skipped, !entry.restored, entry.snapshot != nil {
                    Button("放回待分发") { model.restoreSkipped(entry) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func logSymbol(_ outcome: DispatchOutcome) -> String {
        switch outcome {
        case .sent: return "checkmark.circle"
        case .rehearsed: return "eye"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private func logTint(_ outcome: DispatchOutcome) -> Color {
        switch outcome {
        case .sent: return .green
        case .failed: return .red
        case .rehearsed, .skipped: return .secondary
        }
    }

    private func messageBinding(_ item: DispatchItem) -> Binding<String> {
        Binding(
            get: { model.distribution.pending.first { $0.id == item.id }?.message ?? item.message },
            set: { model.updateDispatchMessage(id: item.id, message: $0) }
        )
    }

    private func projectBinding(_ item: DispatchItem) -> Binding<String> {
        Binding(
            get: { model.distribution.pending.first { $0.id == item.id }?.project ?? item.project },
            set: { model.updateDispatchProject(id: item.id, project: $0) }
        )
    }
}

struct SendConfirmationSheet: View {
    var item: DispatchItem
    var priorNotice: String?
    var confirm: () -> Void
    var cancel: () -> Void
    @State private var acknowledgedRepeat = false

    var body: some View {
        let name = item.alias.isEmpty ? item.target : item.alias
        VStack(alignment: .leading, spacing: Space.md) {
            Text("发给 \(name)？")
                .font(.title2.weight(.semibold))
            Label("发出后不能撤销。", systemImage: "exclamationmark.triangle")
                .font(.body)
                .labelStyle(.titleAndIcon)
            LabeledContent("频道", value: item.channel)
            LabeledContent("账号", value: item.account.isEmpty ? "未填" : item.account)
            LabeledContent("收件人", value: name)
            if !item.alias.isEmpty {
                LabeledContent("收件人 ID", value: item.target)
            }
            Text(item.message.isEmpty ? "没有文字" : item.message)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.attachment.isEmpty ? "不附带文件" : "附件 \(item.attachment)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let priorNotice {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label(priorNotice, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Color.placeholderWarning)
                    Toggle("我知道这会再发一次", isOn: $acknowledgedRepeat)
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("发送给 \(name)", action: confirm)
                    .buttonStyle(StableProminentButtonStyle())
                    .disabled(priorNotice != nil && !acknowledgedRepeat)
                    .accessibilityLabel("发送给 \(name)")
            }
        }
        .padding(Space.lg)
        .frame(minWidth: 460)
        .background(ClearDefaultButton())
    }
}

/// 发送不是回车的默认按钮。取消走 Esc。
private struct ClearDefaultButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.defaultButtonCell = nil
        }
    }
}
