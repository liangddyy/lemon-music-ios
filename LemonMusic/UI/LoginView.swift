// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var message: String?
    @FocusState private var focused: Field?

    private enum Field { case server, username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        LemonMark(size: 88)
                        VStack(spacing: 5) {
                            Text("柠檬音乐")
                                .font(.largeTitle.weight(.bold))
                            Text("连接你的 Lemon Music 服务器")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 48)

                    VStack(spacing: 14) {
                        LoginField(title: "服务器地址", icon: "server.rack", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .focused($focused, equals: .server)
                        LoginField(title: "用户名", icon: "person", text: $username)
                            .textInputAutocapitalization(.never)
                            .focused($focused, equals: .username)
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .focused($focused, equals: .password)

                        if let message {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: login) {
                            HStack {
                                if isLoggingIn { ProgressView().tint(.white) }
                                Text(isLoggingIn ? "正在连接" : "登录")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(isLoggingIn || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                    }
                    .padding(20)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func login() {
        focused = nil
        isLoggingIn = true
        message = nil
        Task {
            do {
                try await model.login(baseURL: serverURL, username: username, password: password)
            } catch {
                message = error.localizedDescription
            }
            isLoggingIn = false
        }
    }
}

private struct LoginField: View {
    let title: String
    let icon: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            TextField(title, text: $text)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
