func markWatched(_ isWatched: Bool) {
    if overlayMarkWatched(isWatched, videoIds: { meta in (meta.videos ?? []).map(\.id) }) { return }
    // MarkAsWatched(false) did not clear the per-video watched state the episode
    // ticks read from, so "Mark Whole Series Unwatched" left every tick in place.
    // Clear each video explicitly (the same path single-episode unwatch uses) so
    // the ticks actually drop; watched stays the efficient aggregate action.
    if isWatched {
        dispatchMetaкуDetails(["action": "MarkAsWatched", "args": true])
        return
    }
    guard let videos = metaDetails?.meta?.videos, !videos.isEmpty else {
        dispatchMetaDetails(["action": "MarkAsWatched", "args": false]); return
    }
    for v in videos {
        var payload: [String: Any] = ["id": v.id]
        if let season = v.season { payload["season"] = season }
        if let episode = v.episode { payload["episode"] = episode }
        dispatchMetaDetails(["action": "MarkVideoAsWatched", "args": [payload, false]])
    }
}
