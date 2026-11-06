import SwiftUI
import HongguoCore

@MainActor
struct NativePhoneLoginView: View {
    let onAuthenticated: (AccountSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var login = PhoneLoginModel()
    @FocusState private var focusedField: LoginField?

    private let agreementURL = URL(string: "https://reading.snssdk.com/wap-hongguo/dr-agreement-v2.html")!
    private let privacyURL = URL(string: "https://reading.snssdk.com/wap-hongguo/dr-privacy-v3.html")!

    private enum LoginField { case phone, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("登入紅果帳號").font(.title2.weight(.semibold))
                        Text("使用手機簡訊驗證，連接你的收藏與觀看進度。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    Picker("國家或地區", selection: $login.countryCode) {
                        ForEach(NativePhoneAuthService.countries, id: \.id) { country in
                            Text("\(country.name) \(country.id)").tag(country.id)
                        }
                    }
                    TextField("手機號碼（不含國碼）", text: $login.localNumber)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .phone)
                        .accessibilityLabel("手機號碼，不含國碼")
                    Text("請依所選地區輸入手機號碼。更換號碼後需重新取得驗證碼。")
                        .font(.caption).foregroundStyle(.secondary)
                    if login.countryCode == "+886" {
                        Text("台灣門號請省略開頭的 0，輸入 9 開頭的 9 位數字。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        TextField("簡訊驗證碼", text: $login.code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .code)
                            .disabled(login.challenge == nil || login.mfa != nil)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = login.resendSeconds(at: context.date)
                            Button(login.isSending ? "發送中…" : remaining > 0 ? "\(remaining) 秒後重發" : "取得驗證碼") {
                                focusedField = nil
                                login.sendCode()
                            }
                            .font(.subheadline.weight(.medium))
                            .disabled(!login.canSendCode || remaining > 0)
                        }
                    }
                    if let challenge = login.challenge {
                        Text(challenge.delivery == .uncertain
                             ? "簡訊發送結果尚未確認。若已收到 \(challenge.maskedPhone) 的驗證碼，可直接輸入；請稍後再嘗試重發。"
                             : "驗證碼已發送至 \(challenge.maskedPhone)。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let mfa = login.mfa {
                    Section("紅果要求進一步驗證") {
                        Text("請使用這次登入的手機，手動發送以下簡訊，再返回繼續驗證。")
                            .font(.subheadline)
                        LabeledContent("收件號碼") { Text(mfa.destination).textSelection(.enabled) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("簡訊內容").font(.caption).foregroundStyle(.secondary)
                            Text(mfa.message).textSelection(.enabled)
                        }
                        Text("簡訊由你的電信業者計費。請先核對收件號碼與內容，再自行決定是否發送。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("驗證期限 \(mfa.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("我已發送，繼續驗證") { login.verifyMFA() }
                            .disabled(login.isBusy || !login.hasConsent || mfa.expiresAt <= Date())
                    }
                }

                Section {
                    Toggle("我已閱讀並同意紅果使用者協議與隱私政策", isOn: $login.hasConsent)
                        .font(.subheadline)
                    HStack(spacing: 18) {
                        Link("使用者協議", destination: agreementURL)
                        Link("隱私政策", destination: privacyURL)
                    }.font(.footnote)
                } footer: {
                    Text("手機號碼與驗證碼只用於這次登入，不保存在片庫。登入狀態會安全保存在這部 iPhone 的鑰匙圈。")
                }

                if let status = login.status {
                    Section {
                        Text(status).font(.footnote).foregroundStyle(login.hasError ? Color.orange : Color.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }

                Section {
                    Button {
                        focusedField = nil
                        login.loginSMS()
                    } label: {
                        HStack {
                            Spacer()
                            if login.isBusy { ProgressView().padding(.trailing, 6) }
                            Text(login.isLoggingIn ? "正在驗證…" : "登入")
                            Spacer()
                        }
                    }
                    .disabled(!login.canLogin)
                }
            }
            .navigationTitle("手機驗證碼登入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { login.invalidate(clearPhone: true); dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
        }
        .onChange(of: login.countryCode) { _, _ in login.phoneChanged() }
        .onChange(of: login.localNumber) { _, _ in login.phoneChanged() }
        .onChange(of: login.code) { _, value in login.normalizeCode(value) }
        .onChange(of: login.hasConsent) { _, value in if !value { login.invalidate(clearPhone: false) } }
        .onChange(of: login.session) { _, session in
            guard let session else { return }
            onAuthenticated(session)
            login.invalidate(clearPhone: true)
            dismiss()
        }
        .onDisappear { login.invalidate(clearPhone: true) }
    }
}

@MainActor
private final class PhoneLoginModel: ObservableObject {
    // A timestamp only: reopening the sheet does not remove the resend guard.
    private static var resendDeadline = Date.distantPast
    @Published var countryCode: String
    @Published var localNumber = ""
    @Published var code = ""
    @Published var hasConsent = false
    @Published private(set) var challenge: PhoneCodeChallenge?
    @Published private(set) var mfa: PhoneMFAChallenge?
    @Published private(set) var session: AccountSession?
    @Published private(set) var status: String?
    @Published private(set) var hasError = false
    @Published private(set) var isSending = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var resendAfter = Date.distantPast

    private let service = NativePhoneAuthService()
    private var operationID = UUID()
    private var operation: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var sentTo: PhoneIdentity?

    private struct PhoneIdentity: Equatable {
        let countryCode: String
        let localNumber: String
    }

    init() {
        let preferred = Locale.current.region?.identifier == "TW" ? "+886" : "+86"
        countryCode = NativePhoneAuthService.countries.contains { $0.id == preferred } ? preferred : "+86"
        resendAfter = Self.resendDeadline
    }

    var isBusy: Bool { isSending || isLoggingIn }
    private var identity: PhoneIdentity {
        .init(countryCode: countryCode, localNumber: localNumber.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var validPhone: Bool {
        let number = identity.localNumber
        if countryCode == "+886", number.count != 9 || !number.hasPrefix("9") { return false }
        return (try? NativePhoneAuthService.normalize(countryCode: countryCode, localNumber: number)) != nil
    }
    var canSendCode: Bool { validPhone && hasConsent && !isBusy && mfa == nil }
    var canLogin: Bool {
        guard let challenge else { return false }
        return hasConsent && !isBusy && mfa == nil && sentTo == identity && challenge.expiresAt > Date()
            && (4...8).contains(code.utf8.count) && code.utf8.allSatisfy { (48...57).contains($0) }
    }
    func resendSeconds(at date: Date) -> Int { max(0, Int(ceil(resendAfter.timeIntervalSince(date)))) }

    func phoneChanged() {
        let value = localNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if countryCode == "+886", value.count == 10, value.hasPrefix("09"), value.utf8.allSatisfy({ (48...57).contains($0) }) {
            localNumber = String(value.dropFirst())
        }
        invalidate(clearPhone: false)
        status = nil
    }

    func normalizeCode(_ value: String) {
        let normalized = String(decoding: value.utf8.filter { (48...57).contains($0) }.prefix(8), as: UTF8.self)
        if normalized != value { code = normalized }
    }

    func sendCode() {
        guard canSendCode, resendSeconds(at: Date()) == 0 else { return }
        let destination = identity
        invalidate(clearPhone: false)
        let pendingCleanup = cleanup
        let generation = UUID(); operationID = generation
        isSending = true; hasError = false; status = nil
        // Preserve a resend guard even if the user cancels after a request reached the provider.
        postponeResend(seconds: 60)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(generation) }
            await pendingCleanup?.value
            guard self.operationID == generation, !Task.isCancelled else { return }
            do {
                let result = try await self.service.sendCode(countryCode: destination.countryCode, localNumber: destination.localNumber)
                guard self.operationID == generation, self.identity == destination, !Task.isCancelled else { return }
                self.sentTo = destination; self.challenge = result
                self.postponeResend(seconds: result.retryAfter)
                self.status = result.delivery == .uncertain ? "若簡訊已送達，請輸入驗證碼；這裡不會自動重發。" : "請輸入收到的簡訊驗證碼。"
            } catch { self.fail(error, generation: generation) }
        }
    }

    func loginSMS() {
        guard canLogin, let challenge else { return }
        let generation = UUID(); operationID = generation
        let submittedCode = code
        isLoggingIn = true; hasError = false; status = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(generation) }
            do {
                let result = try await self.service.loginSMS(challengeID: challenge.id, code: submittedCode)
                guard self.operationID == generation, self.sentTo == self.identity, !Task.isCancelled else { return }
                self.apply(result)
            } catch { self.fail(error, generation: generation) }
        }
    }

    func verifyMFA() {
        guard let mfa, hasConsent, !isBusy, sentTo == identity, mfa.expiresAt > Date() else { return }
        let generation = UUID(); operationID = generation
        isLoggingIn = true; hasError = false; status = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(generation) }
            do {
                let result = try await self.service.verifyMFA(challengeID: mfa.id)
                guard self.operationID == generation, self.sentTo == self.identity, !Task.isCancelled else { return }
                self.apply(result)
            } catch { self.fail(error, generation: generation) }
        }
    }

    func invalidate(clearPhone: Bool) {
        operationID = UUID(); operation?.cancel(); operation = nil
        isSending = false; isLoggingIn = false
        challenge = nil; mfa = nil; sentTo = nil; code = ""
        if clearPhone { localNumber = ""; hasConsent = false; session = nil }
        let earlierCleanup = cleanup
        let service = service
        cleanup = Task { await earlierCleanup?.value; await service.cancel() }
    }

    private func apply(_ result: PhoneLoginResult) {
        code = ""
        switch result {
        case .authenticated(let session): self.session = session
        case .verificationRequired(let verification):
            mfa = verification
            status = "請依紅果要求完成下方驗證。"
        }
    }

    private func finish(_ generation: UUID) {
        guard operationID == generation else { return }
        operation = nil; isSending = false; isLoggingIn = false
    }

    private func fail(_ error: any Error, generation: UUID) {
        guard operationID == generation, !Task.isCancelled else { return }
        if error is CancellationError { return }
        if let error = error as? PhoneAuthError {
            switch error {
            case .cooldown(let seconds), .rateLimited(let seconds): postponeResend(seconds: seconds)
            case .invalidPhone, .unsupportedCountry, .rejected, .unsupportedChallenge:
                if isSending { clearUnsentResendGuard() }
            case .denied(let status) where (400...499).contains(status) && status != 408 && status != 429:
                if isSending { clearUnsentResendGuard() }
            default: break
            }
        }
        hasError = true
        status = (error as? PhoneAuthError)?.localizedDescription ?? "登入暫時無法完成，請檢查網路後重試。"
    }

    private func postponeResend(seconds: Int) {
        let deadline = Date().addingTimeInterval(TimeInterval(min(max(seconds, 60), 86_400)))
        resendAfter = max(resendAfter, deadline)
        Self.resendDeadline = max(Self.resendDeadline, resendAfter)
    }

    private func clearUnsentResendGuard() {
        resendAfter = .distantPast
        Self.resendDeadline = .distantPast
    }
}
