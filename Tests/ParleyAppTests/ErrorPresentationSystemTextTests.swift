import Foundation
import Testing
@testable import Parley
import ParleyCore

// Foundation's error text follows the interface language, so a stored error may hold CFNetwork's
// Chinese wording, or the generic "(NSURLErrorDomain error -1004.)" form without a description.
// ErrorPresentation recognizes all of them. (Under `swift test` the titles come out in English.)

@Test func chineseSystemNetworkErrorsAreRecognized() {
    let unreachable = [
        "无法连接服务器。",                       // -1004
        "未能找到使用指定主机名的服务器。",         // -1003
        "网络连接已中断。",                       // -1005
        "似乎已断开与互联网的连接。",               // -1009
        "此电脑似乎已断开互联网连接。",             // offline notice
    ]
    for text in unreachable {
        let p = ErrorPresentation.make(text, providerName: "LM Studio", baseURL: "http://localhost:1234/v1")
        #expect(p.title == "Can't reach LM Studio at localhost", "\(text)")
        #expect(p.suggestsSettings)
        #expect(p.detail?.contains(text) == true)
    }
    let timeout = ErrorPresentation.make("请求超时。", providerName: "LM Studio")
    #expect(timeout.title == "LM Studio took too long to respond")
    #expect(timeout.detail == "请求超时。")
}

@Test func genericURLErrorDescriptionsAreRecognizedByCode() {
    for text in ["未能完成操作。（NSURLErrorDomain错误-1004。）",
                 "The operation couldn’t be completed. (NSURLErrorDomain error -1004.)",
                 "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)"] {
        #expect(ErrorPresentation.make(text).title == "Can't reach the server", "\(text)")
    }
    #expect(ErrorPresentation.make("未能完成操作。（NSURLErrorDomain错误-1001。）").title == "The server took too long to respond")
    #expect(ErrorPresentation.urlErrorCode(in: "未能完成操作。（NSURLErrorDomain错误-1004。）") == -1004)
    #expect(ErrorPresentation.urlErrorCode(in: "(NSURLErrorDomain error -1001.)") == -1001)
    // Another code, or another domain, is not a connection problem.
    #expect(ErrorPresentation.make("The operation couldn’t be completed. (NSURLErrorDomain error -1011.)").title.hasPrefix("The operation"))
    #expect(ErrorPresentation.make("The operation couldn’t be completed. (NSCocoaErrorDomain error -1004.)").title.hasPrefix("The operation"))
}

@Test func storedSettingsErrorsKeepTheirEnglishText() {
    // Under the English bundle these read exactly as stored.
    let noModel = "No model selected. Pick a model at the top of the window or set a default model for LM Studio in Settings."
    #expect(ErrorPresentation.make(noModel).title == noModel)
    #expect(ErrorPresentation.make(noModel).suggestsSettings)
    let noProvider = "No API provider is configured. Add one in Settings."
    #expect(ErrorPresentation.make(noProvider).title == noProvider)
    #expect(ErrorPresentation.make("Invalid API base URL: ftp://x").title == "Invalid API base URL: ftp://x")
    #expect(ErrorPresentation.make("Keychain error (OSStatus -25300).").title == "Keychain error (OSStatus -25300).")
    #expect(ErrorPresentation.keychainStatus("Keychain error (OSStatus -25300).") == -25300)
}

@Test func sentencesJoinWithoutASpaceAfterChinesePunctuation() {
    #expect(ErrorPresentation.sentences("One.", nil, "Two.") == "One. Two.")
    #expect(ErrorPresentation.sentences("已收到的文本会保留。", "重试。") == "已收到的文本会保留。重试。")
    #expect(ErrorPresentation.sentences("", "Only.") == "Only.")
}
