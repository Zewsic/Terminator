import Foundation
import SwiftUI
import TerminatorCore

struct ContainerLogo: View {
    let imageName: String
    var baseImage: String? = nil
    var side: CGFloat = HostCardMetrics.iconSize
    @State private var logo: URL?

    var body: some View {
        Group {
            if let logo {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: imageName + "|" + (baseImage ?? "")) {
            if let direct = await DockerHubLogoLookup.shared.url(for: imageName) {
                logo = direct
            } else if let baseImage, baseImage.caseInsensitiveCompare(imageName) != .orderedSame {
                logo = await DockerHubLogoLookup.shared.url(for: baseImage)
            } else {
                logo = nil
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "shippingbox")
            .font(.system(size: 14, weight: .bold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

actor DockerHubLogoLookup {
    static let shared = DockerHubLogoLookup()

    private var found: [String: URL] = [:]
    private var missing: Set<String> = []
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var didLoadDisk = false

    func url(for image: String) async -> URL? {
        guard let id = DockerHubRepository.id(from: image) else { return nil }
        loadDiskIfNeeded()
        if let cached = found[id] { return cached }
        if missing.contains(id) { return nil }
        if let task = inFlight[id] { return await task.value }
        let task = Task { await self.fetch(id) }
        inFlight[id] = task
        let url = await task.value
        inFlight[id] = nil
        if let url {
            found[id] = url
            store(url, for: id)
        } else {
            missing.insert(id)
        }
        return url
    }

    private func fetch(_ id: String) async -> URL? {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        if let url = await search(query: name, match: id) { return url }
        guard name != id else { return nil }
        return await search(query: id, match: id)
    }

    private func search(query: String, match id: String) async -> URL? {
        var components = URLComponents(string: "https://hub.docker.com/api/search/v3/catalog/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "type", value: "image"),
            URLQueryItem(name: "from", value: "0"),
            URLQueryItem(name: "size", value: "25")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(CatalogSearch.self, from: data),
              let item = payload.results.first(where: { $0.id.lowercased() == id })
        else { return nil }
        return item.logoURL
    }

    private func loadDiskIfNeeded() {
        guard !didLoadDisk else { return }
        didLoadDisk = true
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        for (id, raw) in stored {
            if let url = URL(string: raw) { found[id] = url }
        }
    }

    private func store(_ url: URL, for id: String) {
        var stored = (try? Data(contentsOf: cacheURL)).flatMap {
            try? JSONDecoder().decode([String: String].self, from: $0)
        } ?? [:]
        stored[id] = url.absoluteString
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Terminator/docker-hub-logos.json")
    }
}

private struct CatalogSearch: Decodable {
    var results: [Item]

    struct Item: Decodable {
        var id: String
        var logo_url: Logo?

        var logoURL: URL? {
            guard let raw = logo_url?.small ?? logo_url?.large, let url = URL(string: raw), url.scheme == "https" else { return nil }
            let host = url.host?.lowercased() ?? ""
            guard host.contains("cloudfront.net") || url.path.contains("repo-logos") else { return nil }
            return url
        }
    }

    struct Logo: Decodable {
        var small: String?
        var large: String?
    }
}
