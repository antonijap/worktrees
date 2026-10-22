import Foundation

enum GitHub {
    /// A stored token means signed in. `gh auth token` reads it locally; `gh auth status` would
    /// go to the network to check it.
    static func signedIn() async -> Bool {
        let result = await Shell.run("gh", ["auth", "token", "--hostname", "github.com"])
        return result.ok && !result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The signed-in login, asked once. The author row stays quiet for the person's own PRs.
    @MainActor static var viewer: String?

    static func viewerLogin() async -> String? {
        let result = await Shell.run("gh", ["api", "user", "--jq", ".login"])
        let login = result.out.trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForDisplay
        return result.ok && !login.isEmpty ? login : nil
    }

    enum Lookup: Sendable {
        case found(PullRequest)
        case none
        /// gh failed (offline, rate limited, timed out). Keep whatever was shown before.
        case failed
    }

    /// Most recent PR per branch for one repo, in a single GraphQL call (aliased lookups, up
    /// to 20 branches each). Returns a lookup per branch asked for.
    static func pullRequests(slug: String, branches: [String]) async -> [String: Lookup] {
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Dictionary(uniqueKeysWithValues: branches.map { ($0, Lookup.failed) }) }
        var result: [String: Lookup] = [:]
        for start in stride(from: 0, to: branches.count, by: 20) {
            let chunk = Array(branches[start..<min(start + 20, branches.count)])
            let names = chunk.indices.map { "b\($0)" }
            let declarations = names.map { "$\($0): String!" }.joined(separator: ", ")
            let lookups = names.map {
                "\($0): pullRequests(headRefName: $\($0), first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } }"
            }.joined(separator: " ")
            let query = """
            query($owner: String!, $name: String!, \(declarations)) { repository(owner: $owner, name: $name) { \(lookups) } }
            fragment pr on PullRequest {
              number title state isDraft url headRefName baseRefName reviewDecision updatedAt mergeStateStatus mergeable
              author { login } labels(first: 20) { nodes { name } }
              latestReviews(first: 30) { nodes { author { login } state } }
              reviewRequests(first: 30) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name slug } ... on Mannequin { login } } } }
              commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename
                ... on CheckRun { name conclusion status detailsUrl checkSuite { workflowRun { workflow { name } } } }
                ... on StatusContext { context state targetUrl } } } } } } }
            }
            """
            var args = ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])"]
            for (name, branch) in zip(names, chunk) { args += ["-f", "\(name)=\(branch)"] }
            let call = await Shell.run("gh", args)
            guard call.ok, let data = try? JSONDecoder().decode(GraphQLResponse.self, from: Data(call.out.utf8)),
                  let repo = data.data?.repository
            else {
                for branch in chunk { result[branch] = .failed }
                continue
            }
            for (name, branch) in zip(names, chunk) {
                // An open PR wins over a newer closed one from a reused branch name.
                let nodes = repo[name]?.nodes.compactMap(\.value) ?? []
                let pick = nodes.first { $0.state == "OPEN" } ?? nodes.first
                result[branch] = pick.map { .found($0.pullRequest) } ?? Lookup.none
            }
        }
        return result
    }

    private struct GraphQLResponse: Decodable {
        struct Data: Decodable { let repository: [String: Connection]? }
        // One node that fails to decode drops out alone instead of failing the whole chunk.
        struct Lossy: Decodable {
            let value: GraphQLPullRequest?
            init(from decoder: Decoder) throws { value = try? GraphQLPullRequest(from: decoder) }
        }
        struct Connection: Decodable { let nodes: [Lossy] }
        let data: Data?
    }

    /// The GraphQL shape, turned into the same PullRequest the REST-style list produced.
    private struct GraphQLPullRequest: Decodable {
        struct Actor: Decodable { var login: String?; var name: String?; var slug: String? }
        struct Named: Decodable { let name: String? }
        struct Nodes<T: Decodable>: Decodable { let nodes: [T] }
        struct Review: Decodable { let author: Actor?; let state: String? }
        struct Request: Decodable { let requestedReviewer: Actor? }
        struct Context: Decodable {
            var name: String?; var conclusion: String?; var status: String?; var detailsUrl: String?
            var checkSuite: CheckSuite?
            var context: String?; var state: String?; var targetUrl: String?
            struct CheckSuite: Decodable { let workflowRun: WorkflowRun? }
            struct WorkflowRun: Decodable { let workflow: Named? }
        }
        struct Rollup: Decodable { let contexts: Nodes<Context>? }
        struct CommitNode: Decodable { let commit: CommitBody? }
        struct CommitBody: Decodable { let statusCheckRollup: Rollup? }

        let number: Int
        let title: String
        let state: String
        let isDraft: Bool?
        let url: String
        let headRefName: String
        let baseRefName: String?
        let reviewDecision: String?
        let updatedAt: String?
        let mergeStateStatus: String?
        let mergeable: String?
        let author: Actor?
        let labels: Nodes<Named>?
        let latestReviews: Nodes<Review>?
        let reviewRequests: Nodes<Request>?
        let commits: Nodes<CommitNode>?

        var pullRequest: PullRequest {
            let checks = commits?.nodes.first?.commit?.statusCheckRollup?.contexts?.nodes.map { c in
                PullRequest.CheckItem(
                    conclusion: c.conclusion, status: c.status, state: c.state,
                    name: c.name?.sanitizedForDisplay, detailsUrl: c.detailsUrl,
                    workflowName: c.checkSuite?.workflowRun?.workflow?.name?.sanitizedForDisplay,
                    context: c.context?.sanitizedForDisplay, targetUrl: c.targetUrl
                )
            }
            let authorLogin = author?.login?.sanitizedForDisplay
            return PullRequest(
                number: number, title: title.sanitizedForDisplay, state: state, isDraft: isDraft ?? false, url: url,
                headRefName: headRefName.sanitizedForDisplay, reviewDecision: reviewDecision,
                statusCheckRollup: checks,
                author: authorLogin, baseRefName: baseRefName?.sanitizedForDisplay,
                updatedAt: updatedAt.flatMap(PullRequest.date(from:)),
                labels: PullRequest.labelNames((labels?.nodes ?? []).map(\.name)),
                reviews: PullRequest.reviewList(
                    author: authorLogin,
                    latest: (latestReviews?.nodes ?? []).map { ($0.author?.login, $0.state) },
                    requested: (reviewRequests?.nodes ?? []).map { $0.requestedReviewer?.login ?? $0.requestedReviewer?.name ?? $0.requestedReviewer?.slug }
                ),
                mergeStateStatus: mergeStateStatus, mergeable: mergeable
            )
        }
    }

    /// The tail of a failed GitHub Actions run's log, a few meaningful lines, or nil when gh
    /// can't fetch it (not Actions, no permission, offline). Never shown as an error.
    /// `job` narrows the excerpt to one job's lines when the run had several failed jobs.
    static func failedLogExcerpt(slug: String, runID: String, job: String? = nil, lines: Int = 15) async -> [String]? {
        // Not queued behind a scan: the person is looking at this right now.
        let result = await Shell.run("gh", ["run", "view", runID, "--repo", slug, "--log-failed"], limited: false)
        guard result.ok else { return nil }
        var all: [(job: String, text: String)] = []
        for raw in result.out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            // Lines come as "job\tstep\t2024-01-01T00:00:00.000Z text". The text can hold tabs of its own.
            let fields = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            var line = fields[2]
            if let m = line.firstMatch(of: #/^\d{4}-\d\d-\d\dT[\d:.]+Z\s?/#) { line = line[m.range.upperBound...] }
            var text = String(line).replacing(#/\u{1B}\[[0-9;?]*[A-Za-z]/#, with: "")
                .sanitizedForDisplay
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep the annotated error, drop the folding and debug markers.
            if text.hasPrefix("##[error]") { text = String(text.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            else if text.hasPrefix("##[") || text.hasPrefix("[command]") { continue }
            if text.isEmpty { continue }
            if text.count > 300 { text = String(text.prefix(300)) + "…" }
            all.append((String(fields[0]), text))
        }
        var picked = all
        if let job, all.contains(where: { $0.job.contains(job) }) {
            picked = all.filter { $0.job.contains(job) }
        }
        guard !picked.isEmpty else { return nil }
        return picked.suffix(lines).map(\.text)
    }
}
