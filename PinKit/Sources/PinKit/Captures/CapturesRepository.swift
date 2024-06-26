import SwiftUI
import OSLog
import OrderedCollections

@Observable public class CapturesRepository {
    let logger = Logger()
    var api: HumaneCenterService
    var data: PageableMemoryContentEnvelope?
    var contentSet: OrderedSet<ContentEnvelope> = []
    var content: [ContentEnvelope] = []
    var isLoading: Bool = false
    var isFinished: Bool = false
    var hasMoreData: Bool = false
    var hasContent: Bool {
        !content.isEmpty
    }
    
    public init(api: HumaneCenterService = .live()) {
        self.api = api
    }
}

extension CapturesRepository {
    private func load(page: Int = 0, size: Int = 30, reload: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let data = try await api.captures(page, size)
            self.data = data
            withAnimation {
                if reload {
                    self.contentSet = OrderedSet(data.content)
                    self.content = self.contentSet.elements
                } else {
                    self.contentSet.append(contentsOf: data.content)
                    self.content = self.contentSet.elements
                }
            }
            self.hasMoreData = !((data.totalPages - 1) == page)
        } catch {
            logger.debug("\(error)")
        }
        isFinished = true
        isLoading = false
    }
    
    public func initial() async {
        guard !isFinished else { return }
        await load()
    }
    
    public func reload() async {
        await load(reload: true)
    }
    
    public func loadMore() async {
        guard let data, hasMoreData, !isLoading else { return }
        let nextPage = min(data.pageable.pageNumber + 1, data.totalPages)
        logger.debug("next page: \(nextPage)")
        await load(page: nextPage)
    }
    
    public func remove(content: ContentEnvelope) async {
        do {
            guard let i = self.content.firstIndex(where: { $0.uuid == content.uuid }) else {
                return
            }
            let capture = withAnimation {
                let _ = self.contentSet.remove(at: i)
                return self.content.remove(at: i)
            }
            try await api.delete(capture)
        } catch {
            logger.debug("\(error)")
        }
    }
    
    public func remove(offsets: IndexSet) async {
        do {
            for i in offsets {
                let capture = withAnimation {
                    let _ = self.contentSet.remove(at: i)
                    return content.remove(at: i)
                }
                try await api.delete(capture)
            }
        } catch {
            logger.debug("\(error)")
        }
    }
    
    public func toggleFavorite(content: ContentEnvelope) async {
        do {
            if content.favorite {
                try await api.unfavorite(content)
            } else {
                try await api.favorite(content)
            }
            guard let idx = self.content.firstIndex(where: { $0.uuid == content.uuid }) else {
                return
            }
            self.content[idx].favorite = !content.favorite
        } catch {
            logger.debug("\(error)")
        }
    }
    
    public func copyToClipboard(capture: ContentEnvelope) async {
        UIPasteboard.general.image = try? await image(for: capture)
    }
    
    public func save(capture: ContentEnvelope) async throws {
        if capture.get()?.video == nil {
            try await UIImageWriteToSavedPhotosAlbum(image(for: capture), nil, nil, nil)
        } else {
            try await saveVideo(capture: capture)
        }
    }
    
    public func search(query: String) async {
        isLoading = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard let searchIds = try await api.search(query.trimmingCharacters(in: .whitespacesAndNewlines), .captures).memories?.map(\.uuid) else {
                self.content = []
                self.contentSet = OrderedSet()
                throw CancellationError()
            }
            var fetchedResults: [ContentEnvelope] = await try searchIds.concurrentCompactMap { id in
                if let localContent = self.content.first(where: { $0.uuid == id }) {
                    return localContent
                } else {
                    try Task.checkCancellation()
                    do {
                        return try await api.memory(id)
                    } catch {
                        logger.debug("\(error)")
                        return nil
                    }
                }
            }
            withAnimation {
                self.contentSet = OrderedSet(fetchedResults)
                self.content = self.contentSet.elements
            }
        } catch is CancellationError {
            // noop
        } catch {
            logger.debug("\(error)")
        }
        isLoading = false
    }
    
    func saveVideo(capture: ContentEnvelope) async throws {
        guard let url = capture.videoDownloadUrl(), let accessToken = (UserDefaults(suiteName: "group.com.ericlewis.Pin-Pal") ?? .standard).string(forKey: Constants.ACCESS_TOKEN) else { return }
        let tempDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let targetURL = tempDirectoryURL.appendingPathComponent(capture.uuid.uuidString).appendingPathExtension("mp4")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        try FileManager.default.createFile(atPath: targetURL.path(), contents: data)
        UISaveVideoAtPathToSavedPhotosAlbum(targetURL.path(), nil, nil, nil)
    }
    
    func image(for capture: ContentEnvelope) async throws -> UIImage {
        guard let cap: CaptureEnvelope = capture.get() else { return UIImage() }
        var req = URLRequest(url: URL(string: "https://webapi.prod.humane.cloud/capture/memory/\(capture.uuid)/file/\(cap.closeupAsset?.fileUUID ?? cap.thumbnail.fileUUID)/download")!.appending(queryItems: [
            .init(name: "token", value: cap.closeupAsset?.accessToken ?? cap.thumbnail.accessToken),
            .init(name: "rawData", value: "false")
        ]))
        req.setValue("Bearer \(api.accessToken!)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let image = UIImage(data: data) else {
            fatalError()
        }
        return image
        UIImage()
    }
}
