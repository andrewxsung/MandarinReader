import SwiftUI

struct LoginView: View {

    @EnvironmentObject private var auth: AuthStore

    @State private var email = ""
    @State private var password = ""
    @State private var isSigningUp = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("MandarinReader")
                .font(.system(size: 36, weight: .bold))
            Text(isSigningUp ? "Create your account" : "Sign in to continue")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (min 8 characters)", text: $password)
                    .textContentType(isSigningUp ? .newPassword : .password)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                HStack {
                    if isBusy { ProgressView().tint(.white) }
                    Text(isSigningUp ? "Create Account" : "Sign In")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: 360)
                .padding()
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isBusy)

            Button(isSigningUp ? "Have an account? Sign in" : "No account? Create one") {
                isSigningUp.toggle()
                errorMessage = nil
            }
            .font(.callout)
            .disabled(isBusy)

            Spacer()
        }
        .padding()
    }

    private func submit() {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else {
            errorMessage = "Enter a valid email address"
            return
        }
        guard password.count >= 8 else {
            errorMessage = "Password must be at least 8 characters"
            return
        }
        errorMessage = nil
        isBusy = true
        let signingUp = isSigningUp
        Task {
            do {
                if signingUp {
                    try await auth.signUp(email: email, password: password)
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch APIError.unauthorized {
                errorMessage = "Invalid email or password"
            } catch APIError.emailTaken {
                errorMessage = "An account with this email already exists"
            } catch APIError.validationFailed {
                errorMessage = "Enter a valid email and a password of at least 8 characters."
            } catch APIError.rateLimited {
                errorMessage = "Too many attempts — wait a moment and try again"
            } catch {
                errorMessage = "Could not reach the server — try again"
            }
            isBusy = false
        }
    }
}

#Preview {
    LoginView().environmentObject(AuthStore(storage: InMemoryTokenStorage()))
}
