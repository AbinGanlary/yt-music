import SwiftUI

/// Optional Google sign-in through Google's "TV device code" flow: you approve a short code at google.com/device,
/// and the app never sees your password. The tokens stay inside the app on this phone.
struct SignInSheet: View {
    @EnvironmentObject var engine: EngineHost
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ytSignedIn") private var signedIn = false
    @AppStorage("ytName") private var accountName = ""

    @State private var info: SignInInfo?
    @State private var error: String?

    static let risk = "This uses Google's sign-in for TV apps. It isn't an official way to use YouTube Music, so Google could limit the account. A spare account is the safer choice."

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let e = error {
                    Text("The sign-in wasn't completed: " + e).font(.subheadline).foregroundStyle(Color.red)
                    Button("Try again") { Task { await begin() } }
                } else if let i = info {
                    Text("1. Open **google.com/device** on this phone or any device.\n2. Choose your account and enter this code:")
                        .font(.subheadline)
                    Text(i.code)
                        .font(.system(size: 38, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .textSelection(.enabled)
                    if let u = URL(string: i.url) {
                        Link(destination: u) {
                            Text("Open google.com/device").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(Theme.accent, in: Capsule()).foregroundStyle(Color.black)
                        }
                    }
                    Button { UIPasteboard.general.string = i.code; tap() } label: {
                        Text("Copy the code").frame(maxWidth: .infinity).padding(.vertical, 12).background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to approve it… The app notices on its own.").font(.footnote).foregroundStyle(Theme.muted)
                    }
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Getting a sign-in code…").foregroundStyle(Theme.muted) }
                }
                Text(Self.risk).font(.caption).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(20)
            .background(Theme.bg)
            .navigationTitle("Sign in with Google")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Close") { dismiss() } } }
            .task { await begin() }
        }
    }

    private func begin() async {
        error = nil
        info = nil
        do {
            info = try await engine.beginSignIn()
            let acct = try await engine.finishSignIn()
            accountName = acct.name ?? acct.handle ?? "Signed in"
            signedIn = true
            dismiss()
        } catch {
            self.error = String(error.localizedDescription.prefix(140))
        }
    }
}
