import PhotosUI
import SwiftUI
import Vision

/// Three ways in. Link, photo, or typed. Every path ends at the same preview,
/// where the name and serving count are editable before saving.
struct RecipeImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .link
    @State private var url = ""
    @State private var text = ""
    @State private var hint = ""
    @State private var photos: [UIImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: ImportResult?
    @State private var raw: Data?
    @State private var name = ""
    @State private var meals = 2
    @State private var pin = true
    @State private var fit: RecipeFit?
    @State private var fitLoading = false

    /// Pages of one recipe. Matches the server's limit.
    private static let maxPhotos = 4

    enum Mode: String, CaseIterable, Identifiable { case link = "Link", photo = "Photo", type = "Type"; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            Screen {
                if let r = result {
                    preview(r)
                } else {
                    entry
                }
            }
            .navigationTitle(result == nil ? "Add a recipe" : "Check it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { state.pendingImportURL = nil; dismiss() } }
                if result != nil { ToolbarItem(placement: .topBarLeading) { Button("Back") { result = nil } } }
            }
            .onAppear(perform: takePendingURL)
            .onChange(of: state.pendingImportURL) { _, _ in takePendingURL() }
            .onChange(of: photoItems) { _, items in Task { await addPicked(items) } }
            .sheet(isPresented: $showCamera) {
                CameraPicker { img in if photos.count < Self.maxPhotos { photos.append(img) } }.ignoresSafeArea()
            }
        }
    }

    private func takePendingURL() {
        guard let u = state.pendingImportURL else { return }
        url = u; mode = .link; result = nil; state.pendingImportURL = nil
        // Shared from Instagram: the share sheet already read it, so this comes straight back from the server.
        if !busy { Task { await submit() } }
    }

    // MARK: entry

    private var entry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                switch mode {
                case .link: linkEntry
                case .photo: photoEntry
                case .type:
                    VStack(alignment: .leading, spacing: 10) {
                        StepHeader(title: "Type it", subtitle: "A dish name, a rough ingredient list, or a full recipe. We'll fill in what's missing.")
                        InputField(placeholder: "Name, e.g. Nana's shakshuka", text: $hint)
                        TextEditor(text: $text).frame(minHeight: 180).padding(8)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line, lineWidth: 1))
                        Text("Example: 4 eggs, 400 g crushed tomatoes, 1 tbsp harissa, 2 slices bread").font(.caption).foregroundStyle(Theme.ink3)
                    }
                }
                if let e = error { InlineNotice(text: e, tone: .warn) }
                PrimaryButton(title: "Read the recipe", isLoading: busy, enabled: canSubmit) { Task { await submit() } }
                if busy { Text("Reading. This can take up to half a minute.").font(.caption).foregroundStyle(Theme.ink2) }
                TrustNote(text: trustText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var linkEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(title: "Paste a link", subtitle: "An Instagram post or reel, a TikTok, or any recipe site. In Instagram, tap Share, then Copy link.")
            InputField(placeholder: "https://…", text: $url, keyboard: .URL)
            PasteButton(payloadType: String.self) { strings in
                guard let s = strings.first else { return }
                Task { @MainActor in url = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .buttonBorderShape(.capsule)
            .tint(Theme.accent)
            .labelStyle(.titleAndIcon)
            Text("From Instagram we read the caption and the cover image. If the recipe is only spoken in the video, type the dish name instead.")
                .font(.caption).foregroundStyle(Theme.ink3)
        }
    }

    private var photoEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Take a photo", subtitle: "A cookbook page, a recipe card, a screenshot. If it runs over more than one page, add each page.")
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 96, height: 128)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
                                .overlay(alignment: .topTrailing) {
                                    Button { if i < photos.count { photos.remove(at: i) } } label: {
                                        Image(systemName: "xmark.circle.fill").font(.title3)
                                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                                    }
                                    .padding(4)
                                    .accessibilityLabel("Remove page \(i + 1)")
                                }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                SecondaryButton(title: photos.isEmpty ? "Camera" : "Add a page", systemImage: "camera") { showCamera = true }
                PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, Self.maxPhotos - photos.count), matching: .images) {
                    HStack(spacing: 8) { Image(systemName: "photo"); Text("Photos").font(.body.weight(.medium)) }
                        .frame(maxWidth: .infinity).frame(height: 52).foregroundStyle(Theme.ink)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
                }
            }
            .disabled(photos.count >= Self.maxPhotos)
            .opacity(photos.count >= Self.maxPhotos ? 0.5 : 1)
            if !photos.isEmpty {
                Text("\(photos.count) of \(Self.maxPhotos) pages").font(.caption).foregroundStyle(Theme.ink3)
            }
        }
    }

    private var trustText: String {
        switch mode {
        case .link: return "The link is read on the server. Nothing is saved until you tap Save."
        case .photo: return "Photos are sent to the server only to be read, and aren't stored. Nothing is saved until you tap Save."
        case .type: return "The text is sent to the server to be structured. Nothing is saved until you tap Save."
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .link: return url.lowercased().contains("http")
        case .photo: return !photos.isEmpty
        case .type: return !(text + hint).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let (r, data): (ImportResult, Data)
            switch mode {
            case .link:
                (r, data) = try await APIClient.shared.importRecipe(source: "url", url: url.trimmingCharacters(in: .whitespacesAndNewlines))
            case .photo:
                let prepared = await Self.prepare(photos)
                guard !prepared.jpegs.isEmpty else { error = "Couldn't use those photos. Try taking them again."; return }
                (r, data) = try await APIClient.shared.importRecipe(source: "image", text: prepared.text, images: prepared.jpegs)
            case .type:
                (r, data) = try await APIClient.shared.importRecipe(source: "text", text: text, hint: hint)
            }
            fit = nil; result = r; raw = data; name = r.recipe.name; meals = max(1, r.recipe.meals)
        } catch { self.error = error.localizedDescription }
    }

    // MARK: photo

    private func addPicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items where photos.count < Self.maxPhotos {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { photos.append(img) }
        }
        photoItems = []
    }

    /// Downscaled JPEGs for the server to read, plus text recognised on the phone,
    /// which the server only falls back to if the photo reader is unavailable.
    nonisolated private static func prepare(_ images: [UIImage]) async -> (jpegs: [Data], text: String) {
        await Task.detached(priority: .userInitiated) {
            var jpegs: [Data] = []
            var pages: [String] = []
            for image in images {
                let small = downscaled(image, maxSide: 1600)
                if let d = small.jpegData(compressionQuality: 0.75) { jpegs.append(d) }
                if let cg = small.cgImage { pages.append(recognizeText(cg)) }
            }
            return (jpegs, pages.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }.value
    }

    /// Redraws upright (camera photos carry their rotation as metadata) and at most `maxSide` px.
    nonisolated private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    nonisolated private static func recognizeText(_ cg: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: preview

    private func preview(_ r: ImportResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let w = r.warning { InlineNotice(text: w, tone: .warn) }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        FieldLabel(text: "Name")
                        InputField(placeholder: "Recipe name", text: $name)
                        Stepper("Makes \(meals) \(meals == 1 ? "meal" : "meals")", value: $meals, in: 1...12).font(.subheadline)
                        Text("\(Fmt.minutes(activeMinutes(r))) hands on · \(Fmt.minutes(totalMinutes(r))) total · keeps \(r.recipe.keepsDays) days")
                            .font(.caption).foregroundStyle(Theme.ink2)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: meals)
                        if meals != r.recipe.meals {
                            Text("Scaled from \(r.recipe.meals). Every amount and the cooking time change with it.")
                                .font(.caption).foregroundStyle(Theme.ink3)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ingredients").font(.headline).foregroundStyle(Theme.ink)
                        ForEach(r.recipe.ingredients) { i in
                            HStack {
                                Text(i.name).foregroundStyle(Theme.ink)
                                if i.matched == false {
                                    Text("new").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                                }
                                Spacer()
                                Text(Fmt.qty(scale(r) == 1 ? i.qty : RecipeScale.qty(i.qty, unit: i.unit, scale(r)), i.unit))
                                    .foregroundStyle(Theme.ink2).monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.snappy, value: meals)
                            }
                            .font(.subheadline)
                        }
                        if !r.customIngredients.isEmpty {
                            Text("\"New\" items aren't in the price catalog yet, so their cost is estimated.").font(.caption).foregroundStyle(Theme.ink3).padding(.top, 4)
                        }
                    }
                }
                fitSection
                if !r.recipe.steps.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Steps").font(.headline).foregroundStyle(Theme.ink)
                            ForEach(Array(r.recipe.steps.enumerated()), id: \.offset) { i, s in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink3).frame(width: 18)
                                    Text(s).font(.subheadline).foregroundStyle(Theme.ink)
                                }
                            }
                        }
                    }
                }
                Card {
                    Toggle(isOn: $pin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Put it in this week").foregroundStyle(Theme.ink)
                            Text("Pins it and rebuilds the week around it.").font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                    .tint(Theme.accent)
                }
                if let e = error { InlineNotice(text: e, tone: .warn) }
                PrimaryButton(title: pin ? "Save and plan my week" : "Save to my recipes", isLoading: busy, enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task {
                        busy = true; error = nil
                        do {
                            if let raw { try await state.saveRecipe(raw: raw, name: name, meals: meals, pin: pin) }
                            dismiss()
                            if pin { await state.replan() }
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task(id: "\(r.recipe.id)-\(meals)") { await loadFit() }
    }

    // MARK: scaling

    private func scale(_ r: ImportResult) -> Double { Double(meals) / Double(max(1, r.recipe.meals)) }
    private func activeMinutes(_ r: ImportResult) -> Int {
        meals == r.recipe.meals ? r.recipe.activeMinutes : RecipeScale.active(r.recipe.activeMinutes, scale(r))
    }
    private func totalMinutes(_ r: ImportResult) -> Int {
        meals == r.recipe.meals ? r.recipe.totalMinutes : RecipeScale.total(active: r.recipe.activeMinutes, total: r.recipe.totalMinutes, scale(r))
    }

    // MARK: fit

    private func loadFit() async {
        guard let raw else { return }
        fitLoading = true
        defer { fitLoading = false }
        try? await Task.sleep(nanoseconds: 350_000_000)   // let the stepper settle
        guard !Task.isCancelled else { return }
        if let f = try? await APIClient.shared.fit(raw: raw, name: name, meals: meals, plan: state.makeRequest()) { fit = f }
    }

    @ViewBuilder private var fitSection: some View {
        if let f = fit {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("In your week").font(.headline).foregroundStyle(Theme.ink)
                        Spacer()
                        if fitLoading { ProgressView().controlSize(.small) }
                    }
                    if f.included {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.signedMoney(f.costDelta)).font(.system(size: 30, weight: .semibold).monospacedDigit())
                                .foregroundStyle(f.costDelta <= 0 ? Theme.accent : Theme.ink)
                                .contentTransition(.numericText())
                            Text(f.costDelta <= 0 ? "on the shopping trip. Cheaper than what it replaces." : "on the shopping trip").font(.subheadline).foregroundStyle(Theme.ink2)
                        }
                        Text("\(Fmt.money(f.after.totalCost)) of \(Fmt.money0(state.profile.budget)) · \(f.after.mealsPlanned) of \(f.after.mealsRequired) meals covered")
                            .font(.subheadline).foregroundStyle(Theme.ink)
                        if f.after.mealsPlanned < f.before.mealsPlanned {
                            InlineNotice(text: "Inside your \(Fmt.money0(state.profile.budget)) budget this covers \(f.before.mealsPlanned - f.after.mealsPlanned) fewer meals than your current week. Raise the budget, or make it a treat week.", tone: .warn)
                        }
                        if !f.reused.isEmpty {
                            Label("Shares \(Self.list(f.reused)) with what you're already buying, so no extra packs.", systemImage: "arrow.triangle.branch")
                                .font(.subheadline).foregroundStyle(Theme.accent)
                        }
                        if !f.newItems.isEmpty {
                            Text("New on the list: " + f.newItems.prefix(4).map { "\($0.name) \(Fmt.money($0.cost))" }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(Theme.ink2)
                        }
                        if !f.replaced.isEmpty {
                            Text("Takes the place of \(Self.list(Array(f.replaced.prefix(3))))" + (f.replaced.count > 3 ? " and \(f.replaced.count - 3) more." : "."))
                                .font(.caption).foregroundStyle(Theme.ink2)
                        }
                    } else {
                        Text(f.reason ?? "It doesn't fit this week's limits.").font(.subheadline).foregroundStyle(Theme.warn)
                        Text("Saved recipes still count for later weeks.").font(.caption).foregroundStyle(Theme.ink2)
                    }
                }
            }
        } else if fitLoading {
            Card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Working out what it does to your week…").font(.subheadline).foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    private static func signedMoney(_ v: Double) -> String {
        abs(v) < 0.005 ? "$0.00" : (v > 0 ? "+" : "−") + Fmt.money(abs(v))
    }

    private static func list(_ names: [String]) -> String {
        let n = names.map { $0.lowercased() }
        return n.count <= 1 ? (n.first ?? "") : n.dropLast().joined(separator: ", ") + " and " + n.last!
    }
}

/// Minimal camera wrapper. Returns the captured image.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
