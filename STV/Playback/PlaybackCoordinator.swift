import AVFoundation
import AVKit
import MediaPlayer
import Combine
import UIKit

/// Drives the vertical episode feed: one playback core (MPVKit by default, AVPlayer as the
/// fallback — see `PlayerEngine`), per-episode prepared sources, neighbour preloading, resume and
/// local progress persistence.
@MainActor
final class PlaybackCoordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate, ObservableObject {
    /// `.remote`: upstream MP4 played by AVFoundation directly (proxy fallback).
    enum Source { case file(URL), stream(HLSPlayback, String), direct(URL), remote(URL, [String: String]) }

    private static func mp4AssetOptions(headers: [String: String] = [:]) -> [String: Any]? {
        var o: [String: Any] = [:]
        if #available(iOS 17.0, *) { o[AVURLAssetOverrideMIMETypeKey] = "video/mp4" }
        if !headers.isEmpty { o["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        return o.isEmpty ? nil : o
    }

    /// AVPlayerItem for a source. Progressive MP4s get an explicit out-of-band MIME type so AVFoundation
    /// never has to guess the container from an extensionless / query-string URL.
    static func makeItem(_ src: Source) -> AVPlayerItem? {
        switch src {
        case .file(let u): return AVPlayerItem(url: u)
        case .direct(let u):
            let mp4 = u.path.hasSuffix(".mp4") || u.path.hasPrefix("/tg/")
            return AVPlayerItem(asset: AVURLAsset(url: u, options: mp4 ? mp4AssetOptions() : nil))
        case .remote(let u, let headers):
            return AVPlayerItem(asset: AVURLAsset(url: u, options: mp4AssetOptions(headers: headers)))
        case .stream(let loader, let url):
            return loader.makeAsset(url: url).map { AVPlayerItem(asset: $0) }
        }
    }

    /// A loopback-proxied item that failed gets one retry straight from the CDN (fresh resolve → fresh token).
    static func canBypassProxy(_ src: Source?, stream: HGStream?) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STV_NO_FALLBACK"] == "1" { return false }
        #endif
        guard case .direct(let u)? = src, u.host == "127.0.0.1", let stream else { return false }
        return !stream.url.hasPrefix("tdfile://") && !stream.url.hasPrefix("file://") && LocalHLSProxy.token(of: stream.url) == nil
    }

    /// User-facing failure text with the AVFoundation code (so a device report pins the cause).
    static func failureText(_ e: Error?) -> String {
        guard let ns = e as NSError? else { return "播放失败，请重试" }
        let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " / \($0.code)" } ?? ""
        return "\(ns.localizedDescription)（\(ns.code)\(under)）"
    }

    static let rateSteps: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    let series: HGSeries
    @Published var detail: HGSeriesDetail?
    @Published private(set) var current: Int?
    @Published private(set) var readyIndex: Int?
    @Published private(set) var errors: [Int: String] = [:]
    /// Set when an episode failed on a Cloudflare interstitial (player shows 去验证).
    @Published private(set) var verifyTargets: [Int: VerifyTarget] = [:]
    @Published private(set) var streams: [Int: [HGStream]] = [:]
    @Published private(set) var chosen: [Int: HGStream] = [:]
    @Published var time: Double = 0
    @Published var duration: Double = 0
    /// Furthest playable position buffered by AVPlayer around the playhead (seconds).
    @Published private(set) var loadedUntil: Double = 0
    /// Buffered position for the progress bar: AVPlayer buffer or the byte pre-buffer, whichever is ahead.
    var bufferedUntil: Double { max(loadedUntil, prebuffer?.until ?? 0) }
    /// User intent survives buffering, episode replacement and system interruptions.
    private var wantsPlayback = true
    private var transportPaused = false
    var paused: Bool { !wantsPlayback || interrupted || transportPaused || current.flatMap { errors[$0] } != nil }
    /// Active playback rate (1.0 default). Locked rate persists after speed-gesture ends.
    @Published private(set) var playbackRate: Double = 1.0
    /// Non-nil when user locked a non-1x rate via speed gesture.
    @Published private(set) var lockedRate: Double? = nil
    @Published private(set) var pipPossible = false
    /// Design v3 chrome: rendered video size, tech strip, audio / subtitle options, auto-advance.
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var tech: PlayerTech?
    @Published private(set) var audioOptions: [MediaTrack] = []
    @Published private(set) var subtitleOptions: [MediaTrack] = []
    @Published private(set) var audioSelected: Int?
    @Published private(set) var subtitleSelected: Int?
    /// Host-drawn subtitle line (Aether loopback / software routes).
    @Published private(set) var subtitleText: String?
    /// Core playing the current episode (the view mounts its surface).
    @Published private(set) var engineKind: PlayerEngineKind = .avplayer
    @Published private(set) var muted = false
    @Published var autoNext: Bool = UserDefaults.standard.object(forKey: "stv.player.autoNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "stv.player.autoNext") }
    }
    let thumbnails = PlayerThumbnailer()
    /// Time under the finger while the progress bar is dragged (time row follows it).
    @Published var scrubPreview: Double?
    #if DEBUG
    /// Screenshot hook: frozen drag fraction (STV_SCRUB_DEMO), shared by whichever bar instance is on screen.
    @Published var scrubDemo: Double?
    #endif
    private var lastTech = Date.distantPast
    /// Long-video byte pre-buffer: bytes cached ahead of the playhead and the time the contiguous run reaches.
    @Published private(set) var prebuffer: (bytes: Int, until: Double, lowStorage: Bool)?
    private var prefetchTokens: [Int: String] = [:]
    /// Episodes whose proxied playback failed once → played straight from the CDN.
    private var bypassProxy: Set<Int> = []
    private var lastPrefetchPoll = Date.distantPast

    let av: AVPlayerEngine
    private(set) lazy var mpv: MPVPlayerEngine? = {
        do { return try MPVPlayerEngine() } catch {
            #if DEBUG
            NSLog("%@", "[STV] MPVKit unavailable: \(error)")
            #endif
            return nil
        }
    }()
    private(set) var engine: PlayerEngine
    /// Episodes MPVKit could not open → AVPlayer.
    private var mpvFailed: Set<Int> = []
    private var pipIdentity: ObjectIdentifier?
    private var timer: Timer?
    private var sharedCommandsRegistered = false
    /// Aspect fill (view toggle) applied to whichever core is mounted.
    var fill = false { didSet { engine.fill = fill } }
    /// Current playhead of the active core (danmaku clock).
    /// The core's clock only moves ~5×/s (Aether publishes at ~10 Hz), so drawing straight from it makes
    /// scrolling comments step. Between core ticks this extrapolates with wall time at the playback rate;
    /// a jump (seek, stall, new episode) re-anchors immediately, small drift is pulled in gently.
    var playhead: Double {
        let raw = engine.currentTime, now = CACurrentMediaTime()
        let rate = paused || readyIndex == nil ? 0 : min(playbackRate, engine.maxRate)
        guard let a = clockAnchor else { clockAnchor = (raw, now, raw); return raw }
        var est = a.time + (now - a.at) * rate
        if raw != a.raw {
            // New core sample: snap if far off, otherwise ease towards it so motion stays continuous.
            if abs(raw - est) > 0.35 { est = raw } else { est += (raw - est) * 0.25 }
            clockAnchor = (est, now, raw)
        } else if rate == 0 || est - raw > 0.6 {
            // Paused, or the core stopped advancing (buffering): hold at the core time.
            est = raw; clockAnchor = (raw, now, raw)
        }
        return est
    }
    private var clockAnchor: (time: Double, at: CFTimeInterval, raw: Double)?
    private var prepared: [Int: Source] = [:]
    private var tasks: [Int: Task<Source, Error>] = [:]
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSave = Date.distantPast
    private var activation = UUID()
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    @Published private(set) var waitingForMedia = false
    private var audioObservers: [NSObjectProtocol] = []
    @Published private(set) var pipActive = false
    @Published var pipError: String?
    private var restoringPiP = false
    private var backgrounded = false
    private var interrupted = false
    private var recoverInterruptedTransport = false
    private var audioSessionActive = false
    private var continuePiP = false
    private let suppliedEngine: PlayerEngine?
    private let sourceResolver: ((Int) async throws -> Source)?

    init(series: HGSeries, engine: PlayerEngine? = nil, resolve: ((Int) async throws -> Source)? = nil) {
        self.series = series
        self.suppliedEngine = engine
        self.sourceResolver = resolve
        let a = AVPlayerEngine()
        self.av = a
        self.engine = engine ?? a
        super.init()
    }

    func start() {
        guard observer == nil else { return }
        #if DEBUG
        // UI tests: an interruption that never ends (STV_FAKE_INTERRUPT=<seconds after start>).
        if let s = ProcessInfo.processInfo.environment["STV_FAKE_INTERRUPT"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
                self?.engine.pause()
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            }
        }
        #endif
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                MainActor.assumeIsolated { self?.setPaused(true) }
            }
        })
        bindTransportRequests(engine)
        // One clock for both cores (AVPlayer periodic observers do not exist on Aether's software route).
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observer = t
        registerSharedCommands()
    }

    /// Lock-screen and headset commands for both playback engines.
    private func registerSharedCommands() {
        guard !sharedCommandsRegistered else { return }
        sharedCommandsRegistered = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget(self, action: #selector(remotePlay))
        c.pauseCommand.addTarget(self, action: #selector(remotePause))
        c.togglePlayPauseCommand.addTarget(self, action: #selector(remoteToggle))
    }

    private func publishNowPlaying() {
        guard let i = readyIndex, episodes.indices.contains(i) else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: detail?.title ?? series.title,
            MPMediaItemPropertyAlbumTitle: series.source.isLongVideo ? series.source.label : "第\(episodes[i].ep)集",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : playbackRate,
        ]
    }

    private func activateAudioSession() {
        guard !audioSessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            // Best-effort; playback still works without background continuity.
        }
    }

    func teardown() {
        activation = UUID()
        save(force: true)
        pip?.delegate = nil
        pipObservation = nil
        statusObservation = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        audioObservers.forEach(NotificationCenter.default.removeObserver)
        audioObservers.removeAll()
        if sharedCommandsRegistered {
            let c = MPRemoteCommandCenter.shared()
            [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand].forEach { $0.removeTarget(self) }
            sharedCommandsRegistered = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        if pip?.isPictureInPictureActive == true {
            pip?.stopPictureInPicture()
        }
        engine.onPlaybackRequested = nil
        suppliedEngine?.stop()
        av.stop()
        mpv?.stop()
        pip = nil
        pipIdentity = nil
        pipActive = false
        pipPossible = false
        timer?.invalidate(); timer = nil
        observer = nil
        readyIndex = nil
        current = nil
        backgrounded = false
        interrupted = false
        recoverInterruptedTransport = false
        continuePiP = false
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        prefetchTokens.values.forEach { LocalHLSProxy.shared.release($0) }
        prefetchTokens.removeAll()
        prebuffer = nil
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    var episodes: [HGEpisode] { detail?.episodes ?? [] }

    // MARK: PiP

    /// (Re)build the PiP controller when the active core's picture route changes.
    private func refreshPiP() {
        let id = engine.pipIdentity
        guard id != pipIdentity else { return }
        guard !pipActive else { return }                 // never swap under a live PiP window
        pipIdentity = id
        pipObservation = nil
        pip?.delegate = nil
        pip = nil
        pipPossible = false
        guard id != nil, AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = engine.makePiPController() else {
            cancelPiPHandover()
            return
        }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        pipObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor in
                guard self?.pip === controller else { return }
                self?.pipPossible = controller.isPictureInPicturePossible
                if let self, self.continuePiP, self.wantsPlayback, self.readyIndex != nil,
                   controller.isPictureInPicturePossible, self.backgrounded {
                    self.continuePiP = false
                    controller.startPictureInPicture()
                }
            }
        }
    }

    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            continuePiP = false
            restoringPiP = true
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    private func cancelPiPHandover() {
        guard continuePiP else { return }
        continuePiP = false
        engine.setPiPActive(false)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pip else { return }
        pipActive = true
        engine.setPiPActive(true)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pip else { return }
        pipActive = false
        engine.setPiPActive(false)
        continuePiP = false
        if !backgrounded { pipError = error.localizedDescription }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        restoringPiP = true
        completion(controller === pip && observer != nil)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pip else { return }
        pipActive = false
        // A software source or fallback can replace the PiP content during an episode load.
        // That stop belongs to the handover, not to the user pressing the close button.
        if continuePiP {
            // Keep the replacement renderer alive until its own PiP controller starts. Clearing
            // this flag here can tear down the newly loaded video while still backgrounded.
            if readyIndex != nil { refreshPiP() }
        } else {
            engine.setPiPActive(false)
            if !restoringPiP { setPaused(true) }
            else { resumeIfRequested() }
        }
        restoringPiP = false
    }

    func didEnterBackground() {
        backgrounded = true
        save(force: true)
    }

    func didBecomeActive() {
        guard backgrounded else { return }
        backgrounded = false
        audioSessionActive = false
        continuePiP = false
        if !pipActive { engine.setPiPActive(false) }
        if pip?.isPictureInPictureActive == true {
            restoringPiP = true
            pip?.stopPictureInPicture()
        }
        resumeIfRequested()
        // Engine foreground restoration may itself be asynchronous. Reconcile once afterwards,
        // re-reading intent so a pause pressed in the meantime always wins.
        let token = activation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.activation == token, !self.backgrounded else { return }
            self.resumeIfRequested()
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue {
            audioSessionActive = false
            interrupted = true
            recoverInterruptedTransport = false
            save(force: true)
        } else {
            interrupted = false
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { setPaused(true) }
            else if wantsPlayback, readyIndex != nil { play() }
        }
    }

    @objc private func remotePlay(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        setPaused(false)
        return .success
    }

    @objc private func remotePause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        setPaused(true)
        return .success
    }

    @objc private func remoteToggle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        togglePause()
        return .success
    }

    // MARK: Rate

    func applyRate(_ rate: Double) {
        let r = Self.nearestStep(rate)
        let clamped = min(r, engine.maxRate)
        playbackRate = clamped
        if wantsPlayback, !interrupted, readyIndex != nil { engine.setRate(clamped) }
    }

    func lockRate(_ rate: Double) {
        let r = Self.nearestStep(rate)
        lockedRate = r == 1.0 ? nil : r
        applyRate(r)
    }

    func unlockRate() {
        lockedRate = nil
        applyRate(1.0)
    }

    func restoreLockedOrNormal() {
        applyRate(lockedRate ?? 1.0)
    }

    static func nearestStep(_ rate: Double) -> Double {
        rateSteps.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
    }

    static func stepIndex(of rate: Double) -> Int {
        let r = nearestStep(rate)
        return rateSteps.firstIndex(of: r) ?? rateSteps.firstIndex(of: 1.0) ?? 0
    }

    static func formatRate(_ rate: Double) -> String {
        if rate == Double(Int(rate)) { return "\(Int(rate))x" }
        let s = String(format: "%.2f", rate)
        return s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) + "x"
    }

    // MARK: Activation

    func select(_ index: Int?) {
        guard let index, index != current, episodes.indices.contains(index) else { return }
        current = index
        wantsPlayback = true
        transportPaused = false
        activate(index)
    }

    /// Last frame of the episode being left, shown over the (cleared) video surface until the next one is
    /// ready, so switching never flashes black.
    @Published private(set) var heldFrame: (image: UIImage, index: Int)?
    /// The feed calls this once the swipe has settled on a ready episode.
    func releaseHeldFrame() { if heldFrame != nil { heldFrame = nil } }

    func activate(_ i: Int) {
        guard i == current, episodes.indices.contains(i), observer != nil else { return }
        save(force: true)
        let token = UUID()
        activation = token
        if let r = readyIndex, heldFrame == nil, let img = Self.snapshot(engine.surface) { heldFrame = (img, r) }
        readyIndex = nil
        if pipActive { continuePiP = true }
        // A source/renderer reload can deactivate the shared session independently of this flag.
        // The next play must acquire it again rather than trust the previous episode's value.
        audioSessionActive = false
        engine.pause()
        time = 0; loadedUntil = 0
        duration = Double(episodes[i].duration)
        for k in tasks.keys where k != i && k != i + 1 {
            tasks.removeValue(forKey: k)?.cancel()
        }
        for (k, tok) in prefetchTokens where k != i {
            // Only the playing episode pre-buffers; others drop their proxy route + cache.
            LocalHLSProxy.shared.release(tok); prefetchTokens[k] = nil; prepared[k] = nil
        }
        prebuffer = nil
        for k in prepared.keys where abs(k - i) > 1 {
            prepared[k] = nil
            streams[k] = nil
            chosen[k] = nil
        }
        errors[i] = nil
        verifyTargets[i] = nil
        let lease = backgrounded || pipActive ? PlaybackBackgroundLease() : nil
        Task { [self] in
            defer { lease?.end() }
            guard activation == token else { return }
            do {
                let src = try await prepare(i)
                #if DEBUG
                if let delay = ProcessInfo.processInfo.environment["STV_PLAYER_LOAD_DELAY"].flatMap(Double.init), delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                if ProcessInfo.processInfo.environment["STV_PLAYER_LOAD_ERROR"] == "1" { throw URLError(.cannotOpenFile) }
                #endif
                guard activation == token else { return }
                let next = chooseEngine(i, src)
                switchEngine(to: next)
                tech = nil; videoSize = .zero; audioOptions = []; subtitleOptions = []; audioSelected = nil; subtitleSelected = nil; subtitleText = nil
                thumbnails.attach(Self.thumbnailAsset(src, stream: chosen[i]))
                var start: Double?
                if let p = LibraryStore.shared.progress(for: series), p.episodeIndex == i, p.seconds > 3,
                   p.duration <= 0 || p.seconds < p.duration - 5 { start = p.seconds }
                let title = detail?.title ?? series.title
                next.onFailed = { [weak self, weak next] err in
                    guard let self, let next, self.activation == token, self.engine === next else { return }
                    self.playbackFailed(i, src: src, engine: next.kind, error: err)
                }
                next.onEnded = { [weak self, weak next] in
                    guard let self, let next, self.activation == token, self.engine === next, self.current == i else { return }
                    if self.wantsPlayback, i + 1 < self.episodes.count, self.autoNext { self.select(i + 1) } else { self.setPaused(true) }
                }
                do {
                    try await next.load(src, stream: chosen[i], start: start, title: title)
                } catch is CancellationError {
                    return
                } catch where next.kind == .mpv {
                    guard activation == token else { return }
                    playbackFailed(i, src: src, engine: .mpv, error: error)
                    return
                }
                guard activation == token else { return }
                #if DEBUG
                NSLog("%@", "[STV] item prepared engine=\(next.kind.short) src=\(String(describing: src).prefix(120))")
                #endif
                next.muted = muted
                readyIndex = i
                if continuePiP { engine.setPiPActive(true) }
                refreshPiP()
                if wantsPlayback, !interrupted { play() }
                if pipActive, engine.pipIdentity == pipIdentity { continuePiP = false }
                if episodes.indices.contains(i + 1) {
                    Task { [weak self] in
                        guard let self, self.activation == token else { return }
                        _ = try? await self.prepare(i + 1)
                    }
                }
                if series.source == .hongguo {
                    // Warm play URLs for the next few episodes (180 s cache) so swipes resolve instantly.
                    let next = episodes.indices.filter { $0 > i && $0 <= i + 3 }.map { episodes[$0].vid }
                    Task { await HongguoClient.shared.prefetch(vids: next) }
                }
                publishNowPlaying()
            } catch {
                guard activation == token else { return }
                errors[i] = error.localizedDescription
                verifyTargets[i] = error.verifyTarget
                cancelPiPHandover()
            }
        }
    }

    /// MPVKit unless the user chose the system player, the source needs AVPlayer (resource-loader AES,
    /// FairPlay), MPVKit could not be created, or it already failed on this episode.
    private func chooseEngine(_ i: Int, _ src: Source) -> PlayerEngine {
        if let suppliedEngine { return suppliedEngine }
        guard PlayerEngineSettings.preferred == .mpv, !mpvFailed.contains(i),
              let m = mpv, m.supports(src) else { return av }
        return m
    }

    private func switchEngine(to next: PlayerEngine) {
        if next !== engine {
            engine.onFailed = nil; engine.onEnded = nil
            engine.onPlaybackRequested = nil
            engine.stop()
            engine = next
        }
        engine.fill = fill
        bindTransportRequests(engine)
        if engineKind != next.kind { engineKind = next.kind }
    }

    /// Fallback ladder: MPVKit → AVPlayer on the same source → AVPlayer straight from the CDN
    /// (loopback-proxied MP4, fresh resolve) → error with the code.
    private func playbackFailed(_ i: Int, src: Source, engine kind: PlayerEngineKind, error: Error?) {
        readyIndex = nil
        if kind == .mpv {
            #if DEBUG
            NSLog("%@", "[STV] mpv fallback → AVPlayer: \(error?.localizedDescription ?? "-")")
            #endif
            mpvFailed.insert(i)
            activate(i)
            return
        }
        if Self.canBypassProxy(src, stream: chosen[i]), !bypassProxy.contains(i) {
            #if DEBUG
            NSLog("%@", "[STV] proxy fallback → direct CDN")
            #endif
            bypassProxy.insert(i)
            if let tok = prefetchTokens.removeValue(forKey: i) { LocalHLSProxy.shared.release(tok) }
            prepared[i] = nil
            chosen[i] = nil
            activate(i)
            return
        }
        prepared[i] = nil
        chosen[i] = nil
        errors[i] = Self.failureText(error)
        cancelPiPHandover()
    }

    /// What the video surface shows right now (Metal / sample-buffer layers included).
    static func snapshot(_ v: UIView) -> UIImage? {
        guard v.bounds.width > 0, v.bounds.height > 0, v.window != nil else { return nil }
        let f = UIGraphicsImageRendererFormat.preferred(); f.opaque = true
        return UIGraphicsImageRenderer(bounds: v.bounds, format: f).image { _ in
            _ = v.drawHierarchy(in: v.bounds, afterScreenUpdates: false)
        }
    }

    /// Scrub thumbnails come from a separate AVURLAsset (any core): files and progressive MP4s only.
    static func thumbnailAsset(_ src: Source, stream: HGStream?) -> AVAsset? {
        switch src {
        case .file(let u): return AVURLAsset(url: u)
        case .direct(let u):
            guard u.path.hasSuffix(".mp4") else { return nil }
            return AVURLAsset(url: u, options: mp4AssetOptions())
        case .remote(let u, let h):
            return AVURLAsset(url: u, options: mp4AssetOptions(headers: h))
        case .stream(let loader, let s):
            guard let u = URL(string: s), !MPVPlayerEngine.isPlaylist(u) else { return nil }
            return AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": loader.headers])
        }
    }

    private func prepare(_ i: Int) async throws -> Source {
        if let source = prepared[i] {
            if case .file(let url) = source, !FileManager.default.fileExists(atPath: url.path) {
                prepared[i] = nil
            } else { return source }
        }
        if let t = tasks[i] { return try await t.value }
        let ep = episodes[i]
        let series = self.series
        let want = chosen[i]
        let preferredId = SitePrefs.preferredStream[series.id]
        let bypass = bypassProxy.contains(i)
        let viaMPV = PlayerEngineSettings.preferred == .mpv && !mpvFailed.contains(i) && mpv != nil
        let task = Task<Source, Error> { [weak self] in
            if let resolve = self?.sourceResolver {
                let source = try await resolve(i)
                if case .direct(let url) = source, let token = LocalHLSProxy.token(of: url.absoluteString) {
                    guard !Task.isCancelled, let self else { LocalHLSProxy.shared.release(token); throw CancellationError() }
                    if let old = self.prefetchTokens[i], old != token { LocalHLSProxy.shared.release(old) }
                    self.prefetchTokens[i] = token
                }
                return source
            }
            var stream = want
            if stream == nil {
                let r = try await Catalog.resolve(series, ep)
                if let e = r.err, r.streams.isEmpty { throw ProviderError.upstream(e) }
                guard let best = r.streams.first(where: { $0.id == preferredId }) ?? r.streams.first else { throw ProviderError.upstream("没有可用的视频流") }
                try Task.checkCancellation()
                self?.streams[i] = r.streams
                self?.chosen[i] = best
                stream = best
            }
            guard let s = stream else { throw ProviderError.upstream("没有可用的视频流") }
            switch s.kind {
            case .mp4Cenc:
                // Already decrypted on disk → play the file. Otherwise stream-decrypt through the proxy; the
                // whole-file download + decrypt is only the fallback (not streamable, or streaming failed once).
                if let f = EpisodePlaybackLoader.cachedFile(vid: ep.vid, stream: s) { return .file(f) }
                if !bypass, let src = await self?.cencStream(s, index: i) { return src }
                return .file(try await EpisodePlaybackLoader.playableFile(vid: ep.vid, stream: s))
            case .mp4Clear where s.url.hasPrefix("tdfile://"):
                // TDLib video: plain progressive file from the loopback proxy, downloaded window by window.
                guard let ref = TDFileRef(s.url) else { throw ProviderError.invalid(s.url) }
                let source = try await TDLibService.shared.streamSource()
                guard let src = await self?.tdStream(ref, source: source, budget: BufferSettings.budget(for: series.source), index: i) else {
                    throw ProviderError.upstream("本地播放代理启动失败")
                }
                return src
            case .mp4Clear where s.url.hasPrefix("file://"):
                // Downloaded (offline) Telegram video.
                guard let u = URL(string: s.url) else { throw ProviderError.upstream("文件地址无效") }
                return .file(u)
            case .mp4Clear where bypass:
                guard let u = URL(string: s.url) else { throw ProviderError.invalid(s.url) }
                return .remote(u, s.headers)
            case .mp4Clear, .hls, .hlsAES:
                let budget = bypass ? 0 : BufferSettings.budget(for: series.source)
                if budget > 0, let proxied = await self?.prebuffered(s, budget: budget, index: i) { return proxied }
                if viaMPV, s.kind != .mp4Clear, s.key.isEmpty {
                    // Keep our playlist rewriting (ad-strip, headers, SupJav fake-PNG) via the loopback proxy.
                    if LocalHLSProxy.token(of: s.url) != nil, let u = URL(string: s.url) { return .direct(u) }
                    if let p = LocalHLSProxy.shared.playlistURL(s.url, headers: s.headers, strip: false, budget: 0),
                       let u = URL(string: p) { return .direct(u) }
                }
                return .stream(HLSPlayback(headers: s.headers, keyHex: s.key), s.url)
            }
        }
        tasks[i] = task
        defer { if tasks[i] == task { tasks[i] = nil } }
        let src = try await task.value
        guard tasks[i] == task, !task.isCancelled else { throw CancellationError() }
        prepared[i] = src
        return src
    }

    /// Long-video sources go through the loopback proxy so segments / MP4 ranges come from the byte
    /// pre-buffer. AES-128 streams with an out-of-band key keep the resource-loader path.
    private func prebuffered(_ s: HGStream, budget: Int, index i: Int) -> Source? {
        if let tok = LocalHLSProxy.token(of: s.url) {           // SupJav: already proxied
            LocalHLSProxy.shared.enablePrefetch(tok, budget: budget)
            prefetchTokens[i] = tok
            return nil
        }
        let proxied: String?
        switch s.kind {
        case .hls: proxied = LocalHLSProxy.shared.playlistURL(s.url, headers: s.headers, strip: false, budget: budget)
        case .hlsAES where s.key.isEmpty: proxied = LocalHLSProxy.shared.playlistURL(s.url, headers: s.headers, strip: false, budget: budget)
        case .mp4Clear: proxied = LocalHLSProxy.shared.mp4URL(s.url, headers: s.headers, budget: budget)
        default: proxied = nil
        }
        guard let proxied, let u = URL(string: proxied), let tok = LocalHLSProxy.token(of: proxied) else { return nil }
        prefetchTokens[i] = tok
        return .direct(u)
    }

    /// 红果 CENC MP4 served decrypted by the loopback proxy while it downloads (nil: not streamable).
    private func cencStream(_ s: HGStream, index i: Int) async -> Source? {
        guard let proxied = LocalHLSProxy.shared.cencMP4URL(s.url, headers: s.headers, key: s.key, budget: Self.cencBudget),
              let u = URL(string: proxied), let tok = LocalHLSProxy.token(of: proxied) else { return nil }
        do {
            try await LocalHLSProxy.shared.prepareCENC(proxied)
        } catch {
            #if DEBUG
            NSLog("%@", "[STV] cenc stream unavailable → full download: \(error.localizedDescription)")
            #endif
            LocalHLSProxy.shared.release(tok)
            return nil
        }
        if let old = prefetchTokens[i], old != tok { LocalHLSProxy.shared.release(old) }
        prefetchTokens[i] = tok
        return .direct(u)
    }

    /// Read-ahead for a streamed 红果 episode (a 1080p episode is roughly 5–40 MB).
    static let cencBudget = 64 * 1_048_576

    private func tdStream(_ ref: TDFileRef, source: TDFileStreamSource, budget: Int, index i: Int) -> Source? {
        guard let proxied = LocalHLSProxy.shared.tdURL(ref, budget: budget, source: source),
              let u = URL(string: proxied), let tok = LocalHLSProxy.token(of: proxied) else { return nil }
        prefetchTokens[i] = tok
        return .direct(u)
    }

    func choose(_ s: HGStream, for i: Int) {
        guard chosen[i] != s else { return }
        if let tok = prefetchTokens.removeValue(forKey: i) { LocalHLSProxy.shared.release(tok) }
        tasks.removeValue(forKey: i)?.cancel()
        chosen[i] = s; prepared[i] = nil
        if current == i { activate(i) }
    }

    // MARK: Controls

    func togglePause() {
        // Interrupted: playback is already stopped whatever the button shows, so this tap means ▶.
        let failed = current.flatMap { errors[$0] } != nil
        setPaused(failed || interrupted || (readyIndex != nil && engine.isPaused && !engine.isWaiting) ? false : wantsPlayback)
    }

    private func setPaused(_ value: Bool) {
        let wasInterrupted = interrupted
        if !value {
            interrupted = false
            if wasInterrupted { recoverInterruptedTransport = true; audioSessionActive = false }
        } else { recoverInterruptedTransport = false }
        wantsPlayback = !value
        transportPaused = value
        if value { continuePiP = false }
        if value {
            engine.pause()
            save(force: true)
        } else if readyIndex != nil {
            // An explicit play wins over a stale interruption: iOS does not promise an `.ended` (another app's
            // audio, PiP interrupted by another app), and waiting for it left ▶ dead until the player was reopened.
            if duration > 0, engine.currentTime >= duration - 0.15, engine.kind == .avplayer { seek(fraction: 0) }
            play()
        } else if let current, errors[current] != nil {
            activate(current)
        }
        publishNowPlaying()
    }

    private func play() {
        activateAudioSession()
        let rate = min(playbackRate, engine.maxRate)
        let recover = recoverInterruptedTransport
        recoverInterruptedTransport = false
        engine.play(rate: rate)
    }

    private func bindTransportRequests(_ target: PlayerEngine) {
        target.onPlaybackRequested = { [weak self, weak target] playing in
            guard let self, let target, self.engine === target, !self.restoringPiP, self.readyIndex != nil else { return }
            self.setPaused(!playing)
        }
    }

    private func resumeIfRequested() {
        guard wantsPlayback, !interrupted, readyIndex != nil, engine.isPaused else { return }
        play()
    }

    func setMuted(_ on: Bool) {
        muted = on
        engine.muted = on
    }

    /// ±10 s buttons / double tap.
    func seek(by seconds: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(duration - 0.5, engine.currentTime + seconds))
        seek(fraction: t / duration)
    }

    private func refreshMediaOptions() {
        let a = engine.audioTracks, st = engine.subtitleTracks
        if a != audioOptions { audioOptions = a }
        if st != subtitleOptions { subtitleOptions = st }
        if engine.selectedAudio != audioSelected { audioSelected = engine.selectedAudio }
        if engine.selectedSubtitle != subtitleSelected { subtitleSelected = engine.selectedSubtitle }
    }

    /// Track ids are `MediaTrack.id`; nil subtitle = off.
    func selectAudio(_ id: Int) { engine.selectAudio(id); audioSelected = id }
    func selectSubtitle(_ id: Int?) { engine.selectSubtitle(id); subtitleSelected = id }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        let target = duration * fraction
        time = target
        Task { await engine.seek(to: target) }
        updatePrefetch(at: target, force: true)
    }

    /// Follow the playhead (seek restarts prefetch from the new position) and refresh the HUD figure.
    private func updatePrefetch(at t: Double, force: Bool = false) {
        guard let i = readyIndex, let tok = prefetchTokens[i] else { return }
        guard force || Date().timeIntervalSince(lastPrefetchPoll) > 1 else { return }
        lastPrefetchPoll = Date()
        if let td = LocalHLSProxy.shared.tdSession(tok) {
            // TDLib stream: seek moves the download window; the buffer layer = bytes TDLib has from here on.
            let d = duration, frac = d > 0 ? t / d : 0
            Task { [weak self] in
                if force { await td.seek(fraction: frac) }
                guard let b = await td.buffered(from: frac), d > 0 else { return }
                await MainActor.run {
                    guard let self, self.readyIndex == i, self.prefetchTokens[i] == tok else { return }
                    self.prebuffer = (b.bytes, min(d, b.until * d), false)
                }
            }
            return
        }
        // MP4 units are chunk indices; map playback time to a chunk by fraction of the duration.
        let pos: Double
        if chosen[i]?.kind.isProgressiveMP4 == true, duration > 0, let st = LocalHLSProxy.shared.status(tok), st.total >= 0 {
            pos = (t / duration) * Double(LocalHLSProxy.shared.mp4Chunks(tok))
        } else { pos = t }
        LocalHLSProxy.shared.setPosition(tok, pos)
        if let st = LocalHLSProxy.shared.status(tok) {
            let until = chosen[i]?.kind.isProgressiveMP4 == true
                ? min(duration, st.until / Double(max(1, LocalHLSProxy.shared.mp4Chunks(tok))) * duration) : st.until
            prebuffer = (st.bytes, until, st.lowStorage)
        }
    }

    private func tick() {
        guard readyIndex != nil else { return }
        let t = engine.currentTime
        guard t.isFinite else { return }
        time = t
        let waiting = engine.isWaiting
        let stopped = engine.isPaused && !waiting
        if stopped != transportPaused { transportPaused = stopped }
        if waiting != waitingForMedia { waitingForMedia = waiting }
        let d = engine.duration
        if d.isFinite, d > 0, abs(d - duration) > 0.01 { duration = d }
        let s = engine.presentationSize
        if s.width > 0, s != videoSize { videoSize = s }
        let sub = engine.subtitleText
        if sub != subtitleText { subtitleText = sub }
        loadedUntil = engine.bufferedUntil
        if Date().timeIntervalSince(lastTech) > 2, let i = readyIndex {
            lastTech = Date()
            let stream = chosen[i]
            let eng = engine
            let token = activation
            Task { [weak self] in
                let t = await eng.tech(stream: stream)
                guard let self, self.engine === eng, self.activation == token else { return }
                if t != self.tech { self.tech = t }
                self.refreshMediaOptions()
                self.refreshPiP()
                self.publishNowPlaying()
            }
        }
        updatePrefetch(at: t)
        save(force: false)
    }

    private func save(force: Bool) {
        guard sourceResolver == nil else { return }
        guard let i = readyIndex, episodes.indices.contains(i) else { return }
        guard force || Date().timeIntervalSince(lastSave) > 4 else { return }
        let seconds = force ? engine.currentTime : time
        guard seconds.isFinite, seconds > 0 else { return }
        lastSave = Date()
        // Deep links / season switches may carry a bare series; fill title & cover from the loaded detail.
        var rec = series
        if let d = detail {
            if rec.title.isEmpty { rec.title = d.title }
            if rec.cover.isEmpty { rec.cover = d.cover }
            if rec.episodeCount == 0 { rec.episodeCount = max(d.totalEps, d.episodes.count) }
        }
        LibraryStore.shared.record(rec, index: i, ep: episodes[i].ep, seconds: seconds, duration: duration)
    }
}
