// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.sessionState {
            case .loading:
                LaunchView()
            case .signedOut:
                LoginView()
            case .ready, .offline:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.sessionState)
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                LemonMark(size: 82)
                Text("柠檬音乐")
                    .font(.title2.weight(.bold))
                ProgressView()
                    .tint(.orange)
            }
        }
    }
}

struct LemonMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color.orange.gradient)
            Image(systemName: "headphones")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .orange.opacity(0.25), radius: 18, y: 8)
    }
}

