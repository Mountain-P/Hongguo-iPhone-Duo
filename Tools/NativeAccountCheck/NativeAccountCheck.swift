import Foundation
import HongguoCore

/// A bounded registration-only probe. It never accepts a phone number, code or account credentials.
@main
struct NativeAccountCheck {
    static func main() async {
        guard Array(CommandLine.arguments.dropFirst()) == ["--prepare-registration"] else {
            print("Usage: NativeAccountCheck --prepare-registration")
            return
        }
        let service = NativePhoneAuthService()
        do {
            try await service.prepareRegistration()
            guard await service.registeredDevice() != nil else { throw PhoneAuthError.invalidResponse }
            await service.cancel()
            print(#"{"registration":"ready","phoneSubmitted":false,"smsSent":false,"credentialsStored":false}"#)
        } catch {
            await service.cancel()
            let message = (error as? PhoneAuthError)?.localizedDescription ?? "Registration probe failed."
            print(message)
            exit(1)
        }
    }
}
