class Stagenow < Formula
  desc "CLI and daemon to automate Stage Manager per space"
  homepage "https://github.com/GreyElaina/StageNow"
  url "https://github.com/GreyElaina/StageNow/archive/69416bbe92e118d18c6db264cb5b22ca23336c6c.tar.gz"
  version "0.0.0.20250929"
  sha256 "75b6722f6be1473a6039e864ee059a62df2d25d69c79e308681de4bffec5d7cb"
  head "https://github.com/GreyElaina/StageNow.git", branch: "master"

  depends_on xcode: ["14.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/StageNow"
    pkgshare.install "Resources/config.json"
    pkgshare.install "Resources/Raycast"
  end

  def caveats
    <<~EOS
      A sample configuration file is available at:
        #{opt_pkgshare}/config.json

      To install the daemon as a user launch agent, run:
        #{opt_bin}/StageNow --install-agent

      Raycast integration scripts are stored in:
        #{opt_pkgshare}/Raycast
      Symlink them into ~/.raycast/scripts if desired.
    EOS
  end

  service do
    run [opt_bin/"StageNow", "--daemon"]
    keep_alive true
    log_path var/"log/stagenow.log"
    error_log_path var/"log/stagenow.log"
  end

  test do
    output = shell_output("#{bin}/StageNow --help")
    assert_match "Stage Manager Controller", output
  end
end
