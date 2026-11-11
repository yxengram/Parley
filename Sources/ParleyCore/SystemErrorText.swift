import Foundation

/// An error's description in fixed English, for text that is saved in a conversation or sent to the
/// model. Foundation's own descriptions (URL, Cocoa and POSIX errors) follow the interface language,
/// so under the Chinese interface `localizedDescription` would put Chinese into stored errors, tool
/// results and notes. The app translates the known sentences back at display time.
public enum SystemErrorText {
    /// CFNetwork's English text for the URL errors that ErrorPresentation and Parley Reader recognize.
    public static let urlErrors: [Int: String] = [
        NSURLErrorTimedOut: "The request timed out.",
        NSURLErrorCannotFindHost: "A server with the specified hostname could not be found.",
        NSURLErrorCannotConnectToHost: "Could not connect to the server.",
        NSURLErrorNetworkConnectionLost: "The network connection was lost.",
        NSURLErrorNotConnectedToInternet: "The Internet connection appears to be offline.",
        NSURLErrorSecureConnectionFailed: "An SSL error has occurred and a secure connection to the server cannot be made.",
    ]

    /// Parley's own errors keep their text (it is English where it is stored). A system error gets
    /// CFNetwork's English sentence for a known URL code; any other one keeps Foundation's text under
    /// the English interface (as before), and otherwise reads as Foundation's generic English form,
    /// "The operation couldn’t be completed. (NSURLErrorDomain error -1011.)".
    public static func english(_ error: Error, interfaceIsEnglish: Bool = SystemErrorText.interfaceIsEnglish) -> String {
        if let own = error as? LocalizedError, let text = own.errorDescription { return text }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, let text = urlErrors[ns.code] { return text }
        if interfaceIsEnglish { return error.localizedDescription }
        return "The operation couldn’t be completed. (\(ns.domain) error \(ns.code).)"
    }

    /// The language Foundation describes errors in: the app's own interface language.
    public static var interfaceIsEnglish: Bool {
        Bundle.main.preferredLocalizations.first.map { $0 == "en" || $0.hasPrefix("en-") } ?? true
    }
}
