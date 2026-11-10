import AppKit
import Network
import ParleyCore
import WebKit

/// The WebKit side of Browse Web Page (`browse_url`). ParleyCore decides what may be opened and what
/// the model is told; this only shows the page and reads it, on the main thread.
///
/// One web view per call, in its own `WKWebsiteDataStore.nonPersistent()` store: no cookie, cache,
/// storage or history outlives the call, and none from the user's other web views comes in. All its
/// connections go through the call's loopback proxy (`proxyConfigurations`, failover off), and the
/// content rules block what WebKit would connect to without asking the proxy. The view is never in a
/// window. It is torn down before `load` returns, on every path: done, failed, timed out, cancelled
/// (Stop, Lock, a conversation closing), and at quit (`cancelAll`).
final class WebPageLoader: BuiltInPageLoader, @unchecked Sendable {
    /// Main thread only.
    @MainActor private var live: Set<PageVisit> = []
    /// Main thread only. Compiled once per launch, from a store in a temporary folder that is removed
    /// right away, so nothing of it stays on disk.
    @MainActor private var compiledRules: [String: WKContentRuleList] = [:]

    /// How many pages are open now. Tests check it goes back to 0.
    @MainActor var openPages: Int { live.count }
    /// The most recent web view, weakly: tests check it is really gone once a call ends.
    @MainActor weak var lastWebView: WKWebView?

    func load(_ request: BuiltInBrowseRequest) async -> BuiltInBrowseOutcome {
        let handle = VisitHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BuiltInBrowseOutcome, Never>) in
                Task { @MainActor [self] in
                    let visit = PageVisit(request: request) { [weak self] visit, outcome in
                        self?.live.remove(visit)
                        continuation.resume(returning: outcome)
                    }
                    self.live.insert(visit)
                    handle.attach(visit)
                    guard !handle.isCancelled else {
                        visit.finish(.cancelled)
                        return
                    }
                    guard let rules = await self.rules(request.contentRules) else {
                        visit.finish(.failed(.other))
                        return
                    }
                    visit.start(rules: rules)
                    self.lastWebView = visit.webViewForInspection
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// At quit: every page stops now. Their callers get `.cancelled`.
    @MainActor func cancelAll() {
        for visit in live { visit.finish(.cancelled) }
    }

    @MainActor private func rules(_ json: String) async -> WKContentRuleList? {
        if let compiled = compiledRules[json] { return compiled }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parley-rules-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let store = WKContentRuleListStore(url: folder) else { return nil }
        let list = try? await store.compileContentRuleList(forIdentifier: "browse", encodedContentRuleList: json)
        if let list { compiledRules[json] = list }
        return list
    }
}

/// Carries a cancel from any thread to the visit, which may not exist yet.
private final class VisitHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var visit: PageVisit?

    var isCancelled: Bool { lock.withLock { cancelled } }

    @MainActor func attach(_ visit: PageVisit) { lock.withLock { self.visit = visit } }

    func cancel() {
        lock.withLock { cancelled = true }
        Task { @MainActor in
            let visit = self.lock.withLock { self.visit }
            visit?.finish(.cancelled)
        }
    }
}

/// One page, from creating the web view to tearing it down.
@MainActor
private final class PageVisit: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Between samples of the text's length while waiting for it to settle.
    private static let sampleInterval: TimeInterval = 0.3
    /// Removes what WebRTC would reach without any proxy (STUN to any address, the LAN included).
    private static let noWebRTC = """
        (() => { for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCRtpTransceiver"]) {
            try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
        } })();
        """
    /// Runs in Parley's own content world, so the page cannot replace what it calls.
    private static let extract = """
        const root = document.body || document.documentElement;
        let text = root ? (root.innerText || "") : "";
        const cut = text.length > maxCharacters;
        if (cut) text = text.slice(0, maxCharacters);
        const links = [];
        if (wantsLinks) {
            const seen = new Set();
            for (const a of document.querySelectorAll("a[href]")) {
                if (links.length >= maxLinks) break;
                const href = a.href;
                if (!/^https?:/i.test(href) || seen.has(href)) continue;
                seen.add(href);
                const label = (a.innerText || a.textContent || "").replace(/\\s+/g, " ").trim();
                links.push([label.slice(0, 200), href.slice(0, 2000)]);
            }
        }
        return { url: location.href, title: String(document.title || ""), text: text, cut: cut, links: links };
        """
    private static let textLength = "(document.body || document.documentElement) ? (document.body || document.documentElement).innerText.length : 0"

    private let request: BuiltInBrowseRequest
    private var completion: ((PageVisit, BuiltInBrowseOutcome) -> Void)?
    private var webView: WKWebView?
    private var timers: [Timer] = []
    private var finishedLoading = false
    /// The text-length samples since the main frame last finished (or started) a load.
    private var samples: [Int] = []
    private var settleStarted = Date()
    private var settling = false
    private var readAttempts = 0
    /// The main frame shows the approved page (or one on its origin).
    private var committed = false
    private var reading = false

    init(request: BuiltInBrowseRequest, completion: @escaping (PageVisit, BuiltInBrowseOutcome) -> Void) {
        self.request = request
        self.completion = completion
    }

    var isDone: Bool { completion == nil }
    var webViewForInspection: WKWebView? { webView }

    func start(rules: WKContentRuleList) {
        guard !isDone, let port = NWEndpoint.Port(rawValue: request.proxyPort) else {
            finish(.failed(.other))
            return
        }
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: port))
        // Never straight to the site when the proxy says no.
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.preferences.isElementFullscreenEnabled = false
        Self.turnOffWebRTC(configuration.preferences)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        // An http address stays http: an upgrade would leave the origin the user approved.
        configuration.upgradeKnownHostsToHTTPS = false
        configuration.userContentController.add(rules)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.noWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 1600), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        schedule(after: request.loadTimeout) { visit in
            // Not done loading: read what is there, if anything of the page showed at all.
            if visit.committed { visit.read() } else { visit.finish(.failed(.timedOut)) }
        }
        // However the page behaves, the call ends: load, settle, and time to read it.
        schedule(after: request.loadTimeout + request.settleTimeout + 10) { visit in
            visit.finish(.failed(.timedOut))
        }

        var load = URLRequest(url: request.url)
        load.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(load)
    }

    /// Ends the visit: the caller gets `outcome`, once, and the web view is gone.
    func finish(_ outcome: BuiltInBrowseOutcome) {
        guard let completion else { return }
        self.completion = nil
        for timer in timers { timer.invalidate() }
        timers.removeAll()
        if let webView {
            // The rules and scripts stay on until the page is gone: removing them now would lift the
            // only guard on loopback while the page's timers can still run.
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        // The last reference: WebKit ends the page's process once no view holds it.
        webView = nil
        completion(self, outcome)
    }

    private func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor (PageVisit) -> Void) {
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDone else { return }
                work(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    /// WebRTC talks UDP and TCP straight from WebKit, past the proxy and the rules. There is no public
    /// switch, so this uses the preference WebKit's own settings use (`_setPeerConnectionEnabled:`),
    /// through key-value coding, and only if this WebKit has it. The document-start script stays as
    /// a second layer for a WebKit without it; it cannot reach a new frame's first empty document.
    static func turnOffWebRTC(_ preferences: WKPreferences) {
        if preferences.responds(to: NSSelectorFromString("_setPeerConnectionEnabled:")) {
            preferences.setValue(false, forKey: "peerConnectionEnabled")
        }
    }

    // MARK: Reading

    private func sample() {
        guard !isDone, !reading, let webView else { return }
        let waited = Date().timeIntervalSince(settleStarted)
        // Another load of the main frame is under way: nothing to count until it is done.
        if webView.isLoading, waited < request.settleTimeout {
            samples = []
            schedule(after: Self.sampleInterval) { visit in visit.sample() }
            return
        }
        webView.evaluateJavaScript(Self.textLength, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, !self.isDone, !self.reading else { return }
            self.samples.append((try? result.get()) as? Int ?? -1)
            if BuiltInBrowsePolicy.isSettled(self.samples) || Date().timeIntervalSince(self.settleStarted) >= self.request.settleTimeout {
                self.read()
            } else {
                self.schedule(after: Self.sampleInterval) { visit in visit.sample() }
            }
        }
    }

    private func read() {
        guard !isDone, !reading, let webView else { return }
        reading = true
        let arguments: [String: Any] = [
            "maxCharacters": request.maxCharacters,
            "maxLinks": request.maxLinks,
            "wantsLinks": request.wantsLinks,
        ]
        webView.callAsyncJavaScript(Self.extract, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, !self.isDone else { return }
            guard case .success(let value) = result, let page = Self.page(from: value, finishedLoading: self.finishedLoading) else {
                // A navigation replaced the document during the read: wait for the new one, twice at most.
                if self.readAttempts < 2, self.committed {
                    self.readAttempts += 1
                    self.reading = false
                    self.samples = []
                    self.schedule(after: Self.sampleInterval) { visit in visit.sample() }
                } else {
                    self.finish(.failed(.other))
                }
                return
            }
            self.finish(.page(page))
        }
    }

    private static func page(from value: Any, finishedLoading: Bool) -> BuiltInBrowsePage? {
        guard let object = value as? [String: Any], let url = object["url"] as? String else { return nil }
        let links = (object["links"] as? [[Any]] ?? []).compactMap { pair -> BuiltInBrowseLink? in
            guard pair.count == 2, let text = pair[0] as? String, let href = pair[1] as? String else { return nil }
            return BuiltInBrowseLink(text: text, url: href)
        }
        return BuiltInBrowsePage(finalURL: url, title: object["title"] as? String ?? "", text: object["text"] as? String ?? "",
                                 textWasCut: object["cut"] as? Bool ?? false, links: links, finishedLoading: finishedLoading)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel, preferences)
            // Only the address itself: a download link on a page that is up leaves the page as it is.
            if navigationAction.targetFrame?.isMainFrame != false, !committed { finish(.notAPage(mimeType: "a file to download")) }
            return
        }
        // No target frame: a new window, which is never opened.
        guard let frame = navigationAction.targetFrame else {
            decisionHandler(.cancel, preferences)
            return
        }
        switch BuiltInBrowsePolicy.navigation(to: navigationAction.request.url, isMainFrame: frame.isMainFrame, approved: request.url) {
        case .allow:
            decisionHandler(.allow, preferences)
        case .cancel:
            decisionHandler(.cancel, preferences)
        case .leave(let target):
            decisionHandler(.cancel, preferences)
            finish(.left(to: target))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // As `fetch_url`: a page outside 2xx is an error, not content.
        if navigationResponse.isForMainFrame, let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode,
           !(200..<300).contains(status) {
            decisionHandler(.cancel)
            finish(.httpError(status))
            return
        }
        let shows = BuiltInBrowsePolicy.showsAsPage(mimeType: navigationResponse.response.mimeType,
                                                    canShow: navigationResponse.canShowMIMEType)
        guard shows else {
            // `.cancel`, never `.download`: nothing is written anywhere.
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame, !committed { finish(.notAPage(mimeType: navigationResponse.response.mimeType ?? "")) }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel(nil)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel(nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
        // A page on the same origin replaced the one being watched (a script or meta refresh):
        // its text starts over.
        samples = []
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded()
    }

    /// Each finished main-frame load restarts the wait, so a stub that moves on to its real page
    /// is not what gets read. The watchdog bounds it all.
    private func loaded() {
        finishedLoading = true
        settleStarted = Date()
        samples = []
        guard !settling else { return }
        settling = true
        sample()
    }

    /// Before anything showed: the page failed. After: a later navigation (a script going to
    /// `mailto:`, a cancelled form) failed, and the page is still there to read.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !committed { failed(error) }
    }

    /// The page showed and then stopped loading: read what it has. A load that was only replaced
    /// by the next one (cancelled, or interrupted by a policy decision) is not an end.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard committed else { return failed(error) }
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == WKError.errorDomain, error.code == 102 { return }
        loaded()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failed(.crashed))
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The system checks certificates. A page asking for a password, or for a client certificate,
        // gets none.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.rejectProtectionSpace, nil)
        }
    }

    private func failed(_ error: Error) {
        guard !isDone else { return }
        let error = error as NSError
        // Stopped by `finish`, which has already answered.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        let failure: BuiltInBrowseFailure
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            failure = .notFound
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            failure = .timedOut
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate), (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            failure = .insecure
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            failure = .connection
        default:
            failure = .other
        }
        finish(.failed(failure))
    }

    // MARK: WKUIDelegate: no windows, no dialogs, no devices, no files

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        completionHandler(nil)
    }
}
