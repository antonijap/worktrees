# Homebrew cask for Worktrees. scripts/release.sh writes a filled-in copy to build/worktrees.rb
# for each release; it goes in the tap repo (antonijap/homebrew-tap) as Casks/worktrees.rb.
cask "worktrees" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/antonijap/worktrees/releases/download/v#{version}/Worktrees-#{version}.zip"
  name "Worktrees"
  desc "Shows every git worktree with its pull request, checks and changes"
  homepage "https://github.com/antonijap/worktrees"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Worktrees.app"

  zap trash: [
    "~/Library/Preferences/me.apek.worktrees.plist",
    "~/Library/Saved Application State/me.apek.worktrees.savedState",
  ]
end
