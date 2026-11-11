import Foundation
import Testing
@testable import ParleyCore

// Foundation describes its errors in the interface language. What Parley saves or sends to the
// model must stay English whatever that language is.

@Test func systemErrorsAreDescribedInFixedEnglish() {
    // Foundation's Chinese text for -1004, as the Chinese interface gets it from CFNetwork.
    let chinese = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                          userInfo: [NSLocalizedDescriptionKey: "无法连接服务器。"])
    for english in [true, false] {
        #expect(SystemErrorText.english(chinese, interfaceIsEnglish: english) == "Could not connect to the server.")
    }
    #expect(SystemErrorText.english(URLError(.timedOut), interfaceIsEnglish: false) == "The request timed out.")
    #expect(SystemErrorText.english(URLError(.notConnectedToInternet), interfaceIsEnglish: false)
            == "The Internet connection appears to be offline.")

    // Another code: Foundation's generic English form under the Chinese interface, which
    // ErrorPresentation and Parley Reader read by its code.
    let other = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                        userInfo: [NSLocalizedDescriptionKey: "服务器响应错误。"])
    #expect(SystemErrorText.english(other, interfaceIsEnglish: false)
            == "The operation couldn’t be completed. (NSURLErrorDomain error -1011.)")
    let posix = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "没有这样的文件或目录"])
    #expect(SystemErrorText.english(posix, interfaceIsEnglish: false) == "The operation couldn’t be completed. (NSPOSIXErrorDomain error 2.)")
    // Under the English interface Foundation's own text is kept, as before.
    #expect(SystemErrorText.english(NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "No such file or directory"]),
                                    interfaceIsEnglish: true) == "No such file or directory")

    // Parley's own errors keep their (English) text.
    #expect(SystemErrorText.english(MCPError.streamEnded, interfaceIsEnglish: false) == "The connection closed before the server answered.")
    #expect(SystemErrorText.english(ParleyError.api("x"), interfaceIsEnglish: false) == "API error: x")
}

@Test func aBrokenStreamIsStoredInEnglish() {
    let text = StreamInterruption.message(underlying: SystemErrorText.english(URLError(.networkConnectionLost), interfaceIsEnglish: false),
                                          viaCloudflare: false)
    #expect(text == "The connection closed before the reply finished: The network connection was lost.")
}
