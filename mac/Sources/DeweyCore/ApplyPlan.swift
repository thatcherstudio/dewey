import Foundation
import Observation

/// The Apply screen before anything moves: the options, and a dry run that lists every row that
/// will move and every row refused. Move then runs the same plan with the options the preview showed.
@MainActor @Observable
public final class ApplyPlan {
    public let root: String
    public var cli: DeweyCLI
    /// Also move rows still marked review (`--include-review`). Changing it needs a new preview.
    public var includeReview = false
    /// Remove folders the moves leave empty (`--prune-empty`). Doesn't change what moves.
    public var pruneEmpty = false
    public private(set) var preview: ApplyPreview?
    /// The `includeReview` the preview was made with.
    public private(set) var previewIncludesReview = false
    public private(set) var loading = false
    public private(set) var error: DeweyError?

    @ObservationIgnored private var generation = 0

    public init(cli: DeweyCLI, root: String) {
        self.cli = cli
        self.root = root
    }

    /// The preview doesn't match the options any more (it is being remade).
    public var isStale: Bool { preview != nil && previewIncludesReview != includeReview }

    /// Ready to move: a current preview with something in it.
    public var canMove: Bool { !loading && !isStale && (preview?.selected.isEmpty == false) }

    /// The plan has been applied: its rows have moved and none is left. Nothing to offer but History.
    public var hasMoved: Bool { !isStale && (preview?.hasMoved ?? false) }

    /// Dry run of the latest plan with the current options. A newer call wins over an older one
    /// still running (the toggle flipped twice).
    public func refresh() async {
        generation += 1
        let mine = generation
        let review = includeReview
        loading = true
        defer { if mine == generation { loading = false } }
        var args = ["apply", root, "--dry-run"]
        if review { args.append("--include-review") }
        do {
            let p = try await cli.run(args, as: ApplyPreview.self)
            guard mine == generation else { return }
            preview = p
            previewIncludesReview = review
            error = nil
        } catch {
            guard mine == generation else { return }
            preview = nil
            self.error = error as? DeweyError ?? .launch(error.localizedDescription)
        }
    }

    /// `dewey apply` for the plan the preview showed, with the options it was made with. `--expect-sha`
    /// holds dewey to the rows on screen: if the plan's CSV was saved again since (Numbers, Review in
    /// another window) or a setting changed where a row goes, it moves nothing and says `stale`.
    public func moveArguments() -> [String]? {
        guard let preview, canMove else { return nil }
        var args = ["apply", root, "--plan", String(preview.planId)]
        if previewIncludesReview { args.append("--include-review") }
        if pruneEmpty { args.append("--prune-empty") }
        if let sha = preview.selectionSha256 { args += ["--expect-sha", sha] }
        return args
    }
}
