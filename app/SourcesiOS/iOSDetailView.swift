import SwiftUI

/// Torrents: ask the embedded server to start fetching peers before playback. No-op for direct/debrid
/// URLs (those carry a `url`, so no `/create` is needed). Port of the tvOS `prepareTorrent`, reusing
/// the shared `TorrentTrackers.sources` so the create carries the TCP/TLS trackers that reach a swarm
/// from a sandboxed app. File-private free function so both the movie list and the per-episode list
/// share one implementation. Returns the retry Task (or nil for a non-torrent / disabled prime) so the
/// caller can store and cancel it — the backoff loop outlives the view otherwise, leaking on every pick.
@discardableResult
private func prepareTorrentStream(_ stream: CoreStream) -> Task<Void, Never>? {
    guard !PlaybackSettings.torrentsDisabled else { return nil }
    guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
          let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return nil }
    let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
    let body: [String: Any] = ["torrent": ["infoHash": hash],
                               "peerSearch": ["sources": sources, "min": 40, "max": 150]]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    request.timeoutInterval = 5
    return Task {
        for attempt in 0..<5 {
            if Task.isCancelled { return }
            if (try? await URLSession.shared.data(for: request)) != nil { return }
            try? await Task.sleep(for: .seconds(Double(attempt + 1)))
        }
    }
}

/// Touch / Mac detail page. Loads meta through the shared engine, then presents the same cinematic
/// composition the tvOS `DetailView` uses — a full-bleed backdrop from `meta.background` with a dark
/// gradient scrim, the hero (logo or title, year · runtime · genres · rating, synopsis) over it, a
/// Play / Watch action, and the source list styled as surface cards. Series show a season selector and
/// an episode list; tapping an episode pushes its own per-episode source-list screen (`iOSEpisodeStreams`)
/// with the full ranked sources + Quality picker, mirroring the tvOS `CoreEpisodeStreams` flow.
struct iOSDetailView: View {
    let id: String
    let type: String
    let title: String
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore

    @State private var presentation: Presentation?
    @State private var preparing = false
    @State private var season = 1
    @State private var settleTimedOut = false
    @State private var torrentPrime: Task<Void, Never>?

    private enum Presentation: Identifiable {
        case player(PlayerLaunch)
        case trailerPlayer(url: URL, title: String)
        var id: String {
            switch self {
            case .player(let l): "player-\(l.id)"
            case .trailerPlayer(_, let t): "trailer-\(t)"
            }
        }
    }

    struct PlayerLaunch: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let headers: [String: String]?
        let resume: Double
        let meta: PlaybackMeta
        var qualityText: String? = nil
        var isTorrent: Bool = false
    }

    private var backdropHeight: CGFloat {
        #if os(macOS)
        return 560
        #else
        return 320
        #endif
    }

    var body: some View {
        // GeometryReader + explicit width on the VStack: a vertical ScrollView in SwiftUI does NOT
        // reliably bound the cross-axis width of its content. `.frame(maxWidth: .infinity)` on the
        // VStack sizes it to the parent's PROPOSAL, but if that proposal is unbounded (which it can be
        // inside a ScrollView), the VStack falls back to its children's ideal width — and the hero's
        // wide logo / meta row / synopsis then push the whole column wider than the screen, shifting
        // the entire detail page to a negative x and clipping the leading edge (the "MAYDAY title cut
        // off" report). Pinning the VStack to `geo.size.width` forces a hard viewport width so no
        // child can stretch the layout coordinate space.
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if LiveTypes.contains(type) {
                            livePage
                        } else {
                            hero { withAnimation { proxy.scrollTo(Self.sourcesAnchor, anchor: .top) } }
                            if type == "series" {
                                episodeList
                            } else {
                                sourceSection.id(Self.sourcesAnchor)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                    // Hard width pin (not `maxWidth: .infinity`): forces the column to exactly the
                    // viewport width so no child can push it wider than the screen.
                    .frame(width: geo.size.width, alignment: .leading)
                }
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(meta?.name ?? title)
        .inlineNavigationTitle()
        .onAppear {
            if core.metaDetails?.meta?.id != id {
                if type == "series" {
                    core.loadMeta(type: type, id: id)
                } else {
                    core.loadMeta(type: type, id: id, streamType: type, streamId: id)
                }
            }
        }
        .onDisappear { core.unloadMeta(); torrentPrime?.cancel() }
        .task {
            try? await Task.sleep(for: .seconds(12))
            settleTimedOut = true
        }
        .platformFullScreenPlayerCover(item: $presentation) { item in
            switch item {
            case .player(let launch):
                PlayerScreen(
                    url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                    recordMeta: launch.meta, recordQualityText: launch.qualityText, recordIsTorrent: launch.isTorrent,
                    onProgress: { pos, dur in Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                    onSeek: { pos, dur in Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                    onClose: { presentation = nil }
                )
                .ignoresSafeArea()
            case .trailerPlayer(let url, let title):
                PlayerScreen(url: url, title: title, headers: nil, resumeSeconds: 0,
                             recordMeta: nil, onClose: { presentation = nil })
                    .ignoresSafeArea()
            }
        }
    }

    private func playTrailer() {
        guard let m = meta, let req = TrailerRequest.from(meta: m) else { return }
        if let direct = req.directURL {
            presentation = .trailerPlayer(url: direct, title: "\(m.name) — Trailer")
        } else if let watch = req.watchURL {
            TrailerOpener.open(watch)
        }
    }

    @ViewBuilder private var trailerButton: some View {
        if let m = meta, TrailerRequest.from(meta: m) != nil {
            Button { playTrailer() } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    // MARK: Hero

    private static let sourcesAnchor = "iOSDetailSources"

    private func hero(scrollToSources: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                titleOrLogo
                metaRow
                if type == "movie" {
                    watchNow(scrollToSources: scrollToSources)
                } else {
                    seriesHeroActions
                }
                if let overview = meta?.description, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backdrop: some View {
        AsyncImage(url: URL(string: meta?.background ?? meta?.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface1
            }
        }
        .frame(height: backdropHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .overlay(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.55),
                .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.85),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .center)
        )
    }

    @ViewBuilder private var titleOrLogo: some View {
        if let logo = meta?.logo, let url = URL(string: logo), !logo.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 110, alignment: .leading)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                default:
                    heroTitle
                }
            }
        } else {
            heroTitle
        }
    }

    private var heroTitle: some View {
        Text(meta?.name ?? title)
            .font(Theme.Typography.hero).tracking(-1)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(3).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    private var metaRow: some View {
        let m = meta
        return HStack(spacing: Theme.Space.md) {
            if let imdb = m?.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            if let r = m?.releaseInfo { Text(r) }
            if let rt = m?.runtime { Text(rt) }
            let genres = m?.genres ?? []
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Series hero

    private var watchedSet: Set<String> {
        guard let m = meta else { return [] }
        return profiles.activeUsesEngineHistory
            ? (core.metaDetails?.watchedIds ?? [])
            : profiles.watchedVideoIds(forMeta: m.id)
    }

    @ViewBuilder private var seriesHeroActions: some View {
        let primary = meta?.videos.flatMap { seriesPrimaryEpisode($0) }
        let primaryProgress = primary.map { episodeProgress($0.video) } ?? 0
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.sm) {
                if let m = meta, let primary {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        NavigationLink {
                            iOSEpisodeStreams(meta: m, video: primary.video, season: primary.video.season ?? 1)
                        } label: {
                            Label(primaryEpisodeLabel(primary.video, isResume: primary.isResume),
                                  systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryActionStyle())
                        if primary.isResume, primaryProgress > 0.01 {
                            iOSProgressStripe(value: primaryProgress)
                                .frame(width: 160)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                trailerButton
                iOSLibraryChip()
                Spacer(minLength: 0)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    private func seriesPrimaryEpisode(_ videos: [CoreVideo]) -> (video: CoreVideo, isResume: Bool)? {
        guard let m = meta else { return nil }
        let sorted = sortedEpisodes(videos)
        let watched = watchedSet
        let resume: (videoId: String?, timeOffsetMs: Double) = {
            guard profiles.activeUsesEngineHistory else {
                let entry = profiles.watch[m.id]
                return (entry?.videoId, Double(entry?.timeOffsetMs ?? 0))
            }
            let state = core.metaDetails?.libraryItem?.state
            return (state?.videoId, state?.timeOffset ?? 0)
        }()
        if resume.timeOffsetMs > 0,
           let videoId = resume.videoId,
           let video = sorted.first(where: { $0.id == videoId }),
           !watched.contains(video.id) {
            return (video, true)
        }
        if let next = sorted.first(where: { !watched.contains($0.id) }) {
            return (next, false)
        }
        return sorted.first.map { ($0, false) }
    }

    private func primaryEpisodeLabel(_ video: CoreVideo, isResume: Bool) -> String {
        let prefix = isResume ? "Resume" : "Play"
        guard let season = video.season else { return "\(prefix) Episode \(video.episodeNumber)" }
        return "\(prefix) S\(season) E\(video.episodeNumber)"
    }

    private func sortedEpisodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.sorted {
            let leftSeason = $0.season ?? 0
            let rightSeason = $1.season ?? 0
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            let leftEpisode = $0.episode ?? 0
            let rightEpisode = $1.episode ?? 0
            if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
            return $0.id < $1.id
        }
    }

    private var firstUnwatchedSeason: Int? {
        guard let videos = meta?.videos else { return nil }
        let watched = watchedSet
        return sortedEpisodes(videos).first { !watched.contains($0.id) }?.season
    }

    private func episodeProgress(_ v: CoreVideo) -> Double {
        guard let m = meta else { return 0 }
        guard profiles.activeUsesEngineHistory else {
            guard let entry = profiles.watch[m.id], entry.videoId == v.id else { return 0 }
            return entry.progress
        }
        guard let item = core.metaDetails?.libraryItem,
              item.state.videoId == v.id,
              item.state.duration > 0 else { return 0 }
        return min(max(item.state.timeOffset / item.state.duration, 0), 1)
    }

    // MARK: Movie — Watch Now + sources

    @ViewBuilder private func watchNow(scrollToSources: @escaping () -> Void) -> some View {
        let groups = StreamRanking.rankedGroups(displayGroups(core.streamGroups()))
        let sourceTotal = groups.reduce(0) { $0 + $1.streams.count }
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Button {
                    Task { await playMovie() }
                } label: {
                    HStack(spacing: Theme.Space.sm) {
                        if preparing { ProgressView().tint(Theme.Palette.onAccent) }
                        else { Image(systemName: "play.fill") }
                        Text(movieLabel)
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(!movieReady || preparing)
                .opacity(movieReady || preparing ? 1 : 0.55)

                qualityMenu(groups)
            }
            HStack(spacing: Theme.Space.sm) {
                Button { scrollToSources() } label: {
                    Label(sourceTotal > 0 ? "Sources · \(sourceTotal)" : "Sources",
                          systemImage: "list.bullet")
                }
                .buttonStyle(ChipButtonStyle())

                trailerButton
                iOSLibraryChip()
                Spacer(minLength: 0)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    @ViewBuilder private func qualityMenu(_ groups: [CoreStreamSourceGroup]) -> some View {
        let tiers = StreamRanking.tiers(groups)
        if !tiers.isEmpty {
            Menu {
                ForEach(tiers, id: \.self) { tier in
                    Menu(tier) {
                        ForEach(StreamRanking.variantOptions(groups, tier: tier), id: \.label) { option in
                            if let url = option.stream.playableURL {
                                Button(option.label) { Task { await playStream(option.stream, url: url) } }
                            }
                        }
                    }
                }
            } label: {
                Label("Quality", systemImage: "chevron.up.chevron.down")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    @ViewBuilder private var sourceSection: some View {
        iOSSourceList(
            groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups())),
            progress: core.streamLoadProgress(),
            states: core.streamAddonStates(),
            settleTimedOut: settleTimedOut,
            continuity: rememberedQuality,
            play: { stream, url in Task { await playStream(stream, url: url) } }
        )
        .padding(.horizontal, Theme.Space.md)
    }

    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard PlaybackSettings.directLinksOnly else { return groups }
        return groups.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    private var rememberedQuality: String? {
        guard let m = meta else { return nil }
        return LastStreamStore.entry(for: m.id, profileID: ProfileStore.shared.activeID)?.qualityText
    }

    private var movieBest: CoreStream? {
        StreamRanking.best(displayGroups(core.streamGroups()), continuity: rememberedQuality)
    }

    private var movieReady: Bool { meta != nil && movieBest != nil }

    private var movieLabel: String {
        if preparing { return "Finding the best source…" }
        guard movieReady, let s = movieBest else { return settleTimedOut ? "No sources found" : "Loading sources…" }
        return "Watch  ·  \(StreamRanking.qualityLabel(s))"
    }

    private func playMovie() async {
        guard !preparing, let m = meta, let stream = movieBest,
              let url = stream.playableURL else { return }
        preparing = true; defer { preparing = false }
        primePlayback(stream)
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        presentation = .player(PlayerLaunch(url: url, title: m.name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent))
    }

    private func playStream(_ stream: CoreStream, url: URL) async {
        guard !preparing, let m = meta else { return }
        preparing = true; defer { preparing = false }
        primePlayback(stream)
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: "movie",
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        presentation = .player(PlayerLaunch(url: url, title: m.name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent))
    }

    // MARK: Live

    @ViewBuilder private var livePage: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(alignment: .center, spacing: Theme.Space.sm) {
                    titleOrLogo
                    liveBadge
                }
                metaRow
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        epgStrip
        liveSourceSection
    }

    @ViewBuilder private var epgStrip: some View {
        if let m = meta {
            if let schedule = EPGSchedule(meta: m) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    if let now = schedule.now {
                        epgRow(eyebrow: "NOW",
                               title: now.episodeTitle,
                               detail: schedule.next?.releasedDate.map { "until \(Self.epgTime.string(from: $0))" })
                    }
                    if let next = schedule.next {
                        epgRow(eyebrow: "NEXT",
                               title: next.episodeTitle,
                               detail: next.releasedDate.map { Self.epgTime.string(from: $0) })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.md)
            } else if let d = m.description, !d.isEmpty {
                Text(d)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }

    private func epgRow(eyebrow: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text(eyebrow)
                .font(Theme.Typography.eyebrow).tracking(1.5)
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private static let epgTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var liveBadge: some View {
        Text("LIVE")
            .font(Theme.Typography.eyebrow).tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.Palette.danger, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    @ViewBuilder private var liveSourceSection: some View {
        iOSSourceList(
            groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups())),
            progress: core.streamLoadProgress(),
            states: core.streamAddonStates(),
            settleTimedOut: settleTimedOut,
            play: { stream, url in Task { await playLiveStream(stream, url: url) } }
        )
        .padding(.horizontal, Theme.Space.md)
    }

    private func playLiveStream(_ stream: CoreStream, url: URL) async {
        guard !preparing, let m = meta else { return }
        preparing = true; defer { preparing = false }
        primePlayback(stream)
        let pm = PlaybackMeta(libraryId: m.id, videoId: m.id, type: type,
                              name: m.name, poster: m.poster, season: nil, episode: nil)
        presentation = .player(PlayerLaunch(url: url, title: m.name, headers: stream.requestHeaders,
                                            resume: 0, meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent))
    }

    // MARK: Series — season selector + episode cards

    @ViewBuilder private var episodeList: some View {
        if let videos = meta?.videos, !videos.isEmpty {
            let seasons = Array(Set(videos.compactMap { $0.season })).sorted()
            let watched = watchedSet
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                iOSRailHeader(eyebrow: "\(episodes(videos).count) episode\(episodes(videos).count == 1 ? "" : "s")",
                              title: "Episodes")

                if !seasons.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Space.sm) {
                            ForEach(seasons, id: \.self) { s in
                                Button { season = s } label: { Text(seasonLabel(s)) }
                                    .buttonStyle(ChipButtonStyle(selected: season == s))
                                    .contextMenu { seasonWatchedMenu(s) }
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }

                VStack(spacing: Theme.Space.sm) {
                    ForEach(episodes(videos), id: \.id) { v in
                        episodeRow(v, isWatched: watched.contains(v.id), progress: episodeProgress(v))
                    }
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .onAppear {
                let preferred = firstUnwatchedSeason ?? seasons.first { $0 > 0 } ?? seasons.first ?? 1
                if seasons.contains(preferred) { season = preferred }
                else if !seasons.contains(season) { season = seasons.first { $0 > 0 } ?? seasons.first ?? 1 }
            }
        }
    }

    @ViewBuilder private func seasonWatchedMenu(_ s: Int) -> some View {
        Button { core.markSeasonWatched(s, true) } label: {
            Label("Mark \(seasonLabel(s)) Watched", systemImage: "checkmark.circle")
        }
        Button { core.markSeasonWatched(s, false) } label: {
            Label("Mark \(seasonLabel(s)) Unwatched", systemImage: "arrow.uturn.backward")
        }
        Button { core.markWatched(true) } label: {
            Label("Mark Whole Series Watched", systemImage: "checkmark.circle.fill")
        }
        Button { core.markWatched(false) } label: {
            Label("Mark Whole Series Unwatched", systemImage: "circle")
        }
    }

    @ViewBuilder private func episodeRow(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        if let m = meta {
            NavigationLink {
                iOSEpisodeStreams(meta: m, video: v, season: v.season ?? season)
            } label: {
                episodeRowLabel(v, isWatched: isWatched, progress: progress)
            }
            .buttonStyle(RowFocusStyle())
            .accessibilityValue(isWatched ? "Watched" : "")
            .contextMenu {
                Button(isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                    core.markVideoWatched(v, !isWatched)
                }
            }
        } else {
            episodeRowLabel(v, isWatched: isWatched, progress: progress)
        }
    }

    private func episodeRowLabel(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            episodeThumbnail(v, isWatched: isWatched, progress: progress)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote).foregroundStyle(Theme.Palette.accent)
                            .accessibilityHidden(true)
                    }
                    Text("\(v.episodeNumber). \(v.episodeTitle)")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(isWatched ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                        .lineLimit(2)
                }
                if let aired = v.released, aired.count >= 10 {
                    Text(String(aired.prefix(10)))
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
                }
                if let overview = v.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .opacity(isWatched ? 0.55 : 1)
    }

    private func episodeThumbnail(_ v: CoreVideo, isWatched: Bool, progress: Double) -> some View {
        AsyncImage(url: URL(string: v.thumbnail ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default:
                Theme.Palette.surface2.overlay(
                    Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: 132, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isWatched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(Theme.Palette.accent).padding(5).shadow(radius: 3)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if !isWatched, progress > 0.01 {
                iOSProgressStripe(value: progress).padding(4)
            }
        }
    }

    private func episodes(_ videos: [CoreVideo]) -> [CoreVideo] {
        videos.filter { ($0.season ?? 1) == season }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private func seasonLabel(_ s: Int) -> String { s == 0 ? "Specials" : "Season \(s)" }

    // MARK: Shared

    private func primePlayback(_ stream: CoreStream) {
        core.loadEnginePlayer(for: stream)
        torrentPrime?.cancel()
        torrentPrime = prepareTorrentStream(stream)
    }

    private func resume(_ pm: PlaybackMeta) async -> Double {
        if let engine = core.engineResumeSeconds(for: pm) { return engine }
        return await account.resumeOffset(for: pm)
    }

    private var meta: CoreMetaItem? {
        let m = core.metaDetails?.meta
        return m?.id == id ? m : nil
    }
}

// MARK: - Per-episode source list (mirrors tvOS CoreEpisodeStreams)

struct iOSEpisodeStreams: View {
    let meta: CoreMetaItem
    let video: CoreVideo
    let season: Int
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager

    @State private var player: iOSDetailView.PlayerLaunch?
    @State private var preparing = false
    @State private var settleTimedOut = false
    @State private var torrentPrime: Task<Void, Never>?

    private var backdropHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    hero
                    iOSSourceList(
                        groups: StreamRanking.rankedGroups(displayGroups(core.streamGroups(forStreamId: video.id))),
                        progress: core.streamLoadProgress(forStreamId: video.id),
                        states: core.streamAddonStates(forStreamId: video.id),
                        settleTimedOut: settleTimedOut,
                        continuity: rememberedQuality,
                        play: { stream, url in Task { await play(stream, url: url) } }
                    )
                    .padding(.horizontal, Theme.Space.md)
                }
                .padding(.bottom, Theme.Space.xl)
                .frame(width: geo.size.width, alignment: .leading)
            }
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(video.episodeTitle)
        .inlineNavigationTitle()
        .onAppear {
            let hasThisEpisodeStreams = core.metaDetails?.streams.contains { $0.request.path.id == video.id } ?? false
            if core.metaDetails?.meta?.id != meta.id || !hasThisEpisodeStreams {
                core.loadMeta(type: "series", id: meta.id, streamType: "series", streamId: video.id)
            }
        }
        .onDisappear { torrentPrime?.cancel() }
        .task {
            try? await Task.sleep(for: .seconds(12))
            settleTimedOut = true
        }
        .platformFullScreenPlayerCover(item: $player) { launch in
            PlayerScreen(
                url: launch.url, title: launch.title, headers: launch.headers, resumeSeconds: launch.resume,
                recordMeta: launch.meta, recordQualityText: launch.qualityText, recordIsTorrent: launch.isTorrent,
                onProgress: { pos, dur in Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onSeek: { pos, dur in Task { [weak account] in await account?.saveProgress(for: launch.meta, positionSeconds: pos, durationSeconds: dur) } },
                onClose: { player = nil }
            )
            .ignoresSafeArea()
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(meta.name.uppercased())
                    .font(Theme.Typography.eyebrow).tracking(1.5)
                    .foregroundStyle(Theme.Palette.accent)
                Text(video.episodeTitle)
                    .font(Theme.Typography.hero).tracking(-1)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(3).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                metaRow
                if let overview = video.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backdrop: some View {
        AsyncImage(url: URL(string: video.thumbnail ?? meta.background ?? meta.poster ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.surface1
            }
        }
        .frame(height: backdropHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .overlay(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.55),
                .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.85),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .center)
        )
    }

    private var metaRow: some View {
        HStack(spacing: Theme.Space.md) {
            Text("S\(season) · E\(video.episode ?? 0)")
            if let released = video.released, released.count >= 10 { Text(String(released.prefix(10))) }
            if let rt = meta.runtime { Text(rt) }
            if let imdb = meta.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            let genres = meta.genres
            if !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func play(_ stream: CoreStream, url: URL) async {
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        core.loadEnginePlayer(for: stream)
        torrentPrime?.cancel()
        torrentPrime = prepareTorrentStream(stream)
        let name = "\(meta.name)  ·  S\(video.season ?? season)E\(video.episodeNumber)"
        let pm = PlaybackMeta(libraryId: meta.id, videoId: video.id, type: "series",
                              name: meta.name, poster: video.thumbnail ?? meta.poster,
                              season: video.season, episode: video.episode)
        player = iOSDetailView.PlayerLaunch(url: url, title: name, headers: stream.requestHeaders,
                                            resume: await resume(pm), meta: pm,
                                            qualityText: StreamRanking.signature(stream), isTorrent: stream.isTorrent)
    }

    private func resume(_ pm: PlaybackMeta) async -> Double {
        if let engine = core.engineResumeSeconds(for: pm) { return engine }
        return await account.resumeOffset(for: pm)
    }

    private func displayGroups(_ groups: [CoreStreamSourceGroup]) -> [CoreStreamSourceGroup] {
        guard PlaybackSettings.directLinksOnly else { return groups }
        return groups.compactMap { group in
            let streams = group.streams.filter { !$0.isTorrent }
            guard !streams.isEmpty else { return nil }
            return CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: streams)
        }
    }

    private var rememberedQuality: String? {
        LastStreamStore.entry(for: meta.id, profileID: ProfileStore.shared.activeID)?.qualityText
    }
}

// MARK: - iOS / macOS presentation helpers

private struct iOSRailHeader: View {
    let eyebrow: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow.uppercased())
                .font(Theme.Typography.eyebrow).tracking(1.5)
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct iOSProgressStripe: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.55))
                Capsule().fill(Theme.Palette.accent)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

struct iOSSourceList: View {
    let groups: [CoreStreamSourceGroup]
    let progress: (loaded: Int, total: Int)
    var states: [CoreBridge.StreamAddonState] = []
    var settleTimedOut = false
    var continuity: String? = nil
    let play: (CoreStream, URL) -> Void

    @State private var sourceFilter: String? = nil
    @State private var showAllSources = false
    @State private var collapsed: Set<String> = []
    @State private var qualityTier: String? = nil

    private var streamCount: Int { groups.reduce(0) { $0 + $1.streams.count } }
    private var loading: Bool { !settleTimedOut && (progress.total == 0 || progress.loaded < progress.total) }
    private var visibleGroups: [CoreStreamSourceGroup] {
        groups.filter { sourceFilter == nil || $0.addon == sourceFilter }
    }

    @ViewBuilder private var emptyState: some View {
        let errored = states.filter { $0.error != nil }
        let answeredEmpty = states.filter { $0.error == nil && !$0.loading }
        if !errored.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSEmptyRow(text: "\(errored.count) add-on\(errored.count == 1 ? "" : "s") couldn't be reached for this title:")
                ForEach(errored) { s in addonReasonRow(s.name, s.error ?? "error") }
            }
        } else if !answeredEmpty.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSEmptyRow(text: "Your stream add-ons returned no sources for this title:")
                ForEach(answeredEmpty) { s in
                    addonReasonRow(s.name, s.ready > 0 ? "\(s.ready) found, hidden by your filters" : "no results")
                }
                Text("If this title should have sources, the add-on may be offline or its config expired. Try another stream add-on.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.md)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSEmptyRow(text: "No stream add-ons responded for this title.")
                Text("Check Add-ons for one that lists \"Streams\" (not just Catalogs or Metadata). If you recently force-quit the app, reopen it so your add-ons reload, or re-add a stream add-on.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }

    private func addonReasonRow(_ name: String, _ reason: String) -> some View {
        Text("\(name): \(reason)")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.md)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            iOSRailHeader(eyebrow: eyebrow, title: "Sources")

            if groups.isEmpty {
                if loading {
                    iOSLoadingRow(text: progress.total > 0
                                  ? "Finding sources…  \(progress.loaded)/\(progress.total)"
                                  : "Finding sources…")
                } else {
                    emptyState
                }
