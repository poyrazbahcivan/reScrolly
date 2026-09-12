import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → heisoj" from Instagram, TikTok, Safari, or anything else with a link.
/// Reads the post right here in the share sheet and shows the recipe, then hands the
/// link to the app. The server keeps the result for half an hour, so the app opens it instantly.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.close = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.openApp = { [weak self] url in self?.openHostApp(url) ?? false }
        let host = UIHostingController(rootView: ShareCard(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.start(items: items) }
    }

    /// Extensions can't use UIApplication.shared. The application object is still
    /// in the responder chain, and it answers openURL:options:completionHandler:.
    private func openHostApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let appClass = NSClassFromString("UIApplication"), r.isKind(of: appClass), r.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(r.method(for: selector), to: OpenURL.self)
                open(r, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase { case reading, ready(ImportResult), failed(String) }

    @Published var phase: Phase = .reading
    @Published var link: URL?
    @Published var copiedInstead = false
    var close: () -> Void = {}
    var openApp: (URL) -> Bool = { _ in false }

    func start(items: [NSExtensionItem]) async {
        guard let url = await Self.findLink(in: items) else {
            phase = .failed("There's no link in what was shared. In Instagram, open the reel, tap Share, then choose heisoj.")
            return
        }
        link = url
        do { phase = .ready(try await ShareAPI.importRecipe(url: url)) }
        catch { phase = .failed(error.localizedDescription) }
    }

    /// Opens the app on the import screen. If iOS won't open it, the link goes on the clipboard instead.
    func handOff() {
        guard let link else { close(); return }
        let encoded = link.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let deep = URL(string: "onepercentchocolatemilk.heisoj://import?url=\(encoded)"), openApp(deep) {
            close()
        } else {
            UIPasteboard.general.url = link
            copiedInstead = true
        }
    }

    private static func findLink(in items: [NSExtensionItem]) async -> URL? {
        let providers = items.flatMap { $0.attachments ?? [] }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let u = item as? URL, u.scheme?.hasPrefix("http") == true { return u }
            if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil), u.scheme?.hasPrefix("http") == true { return u }
        }
        // TikTok and some apps share "caption https://…" as plain text.
        var texts = items.compactMap { $0.attributedContentText?.string }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { texts.append(s) }
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for t in texts {
            let match = detector?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))
            if let u = match?.url, u.scheme?.hasPrefix("http") == true { return u }
        }
        return nil
    }
}

enum ShareAPI {
    /// The same production server the app defaults to. The extension can't read the app's settings.
    static let server = URL(string: "https://hs.poyraz.us")!

    struct Failure: LocalizedError { let errorDescription: String? }

    static func importRecipe(url: URL) async throws -> ImportResult {
        var req = URLRequest(url: server.appendingPathComponent("recipes/import"))
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["source": "url", "url": url.absoluteString])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw Failure(errorDescription: "Can't reach heisoj right now. Check your connection and try again.") }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw Failure(errorDescription: detail ?? "Couldn't read that post.")
        }
        return try JSON.decoder.decode(ImportResult.self, from: data)
    }
}

struct ShareCard: View {
    @ObservedObject var model: ShareModel
    @State private var step = 0
    private let steps = ["Opening the post", "Reading the caption and the cover", "Matching ingredients to store prices"]

    var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch model.phase {
                        case .reading: reading
                        case .ready(let r): ready(r)
                        case .failed(let message): failed(message)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("heisoj")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.close() } } }
        }
    }

    private var source: String {
        let host = model.link?.host ?? ""
        return host.contains("instagram") ? "Instagram" : host.contains("tiktok") ? "TikTok" : host.replacingOccurrences(of: "www.", with: "")
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Reading the recipe", subtitle: source.isEmpty ? nil : "From \(source). Takes a few seconds.")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(Theme.line, lineWidth: 1.5).frame(width: 22, height: 22)
                            if i < step {
                                Circle().fill(Theme.accent).frame(width: 22, height: 22)
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            } else if i == step { ProgressView().controlSize(.small) }
                        }
                        Text(s).foregroundStyle(i <= step ? Theme.ink : Theme.ink3)
                    }
                }
            }
        }
        .task {
            for i in 1..<steps.count {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { step = i }
            }
        }
    }

    private func ready(_ r: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("From \(source)").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(r.recipe.name).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("\(r.recipe.meals) meals · \(Fmt.minutes(r.recipe.activeMinutes)) hands on · keeps \(r.recipe.keepsDays) days")
                    .font(.subheadline).foregroundStyle(Theme.ink2)
            }
            if let w = r.warning { InlineNotice(text: w, tone: .warn) }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(r.recipe.ingredients.count) ingredients").font(.headline).foregroundStyle(Theme.ink)
                    ForEach(r.recipe.ingredients.prefix(8)) { i in
                        HStack {
                            Text(i.name).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(Fmt.qty(i.qty, i.unit)).foregroundStyle(Theme.ink2).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    if r.recipe.ingredients.count > 8 {
                        Text("and \(r.recipe.ingredients.count - 8) more").font(.caption).foregroundStyle(Theme.ink3)
                    }
                }
            }
            if model.copiedInstead {
                InlineNotice(text: "Link copied. Open heisoj, go to Recipes, tap +, then Paste. It opens instantly.")
            }
            PrimaryButton(title: "Add to my week") { model.handOff() }
            TrustNote(text: "Opens heisoj to show what it costs and how it fits the week you already have.")
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(title: "Couldn't read that one")
            InlineNotice(text: message, tone: .warn)
            if model.link != nil {
                SecondaryButton(title: "Open in heisoj anyway", systemImage: "arrow.up.forward.app") { model.handOff() }
            }
            if model.copiedInstead {
                InlineNotice(text: "Link copied. Open heisoj, go to Recipes, tap +, then Paste.")
            }
        }
    }
}
