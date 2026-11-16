
use std::env;
use std::path::Path;
use std::process::Command;


fn main() {
	println!("cargo:rerun-if-changed=build.rs");
	println!("cargo:rerun-if-env-changed=GIT_HASH");
	println!("cargo:rerun-if-env-changed=BARK_VERSION");
	if env::var("GIT_HASH").is_err() || env::var("BARK_VERSION").is_err() {
		// HEAD alone does not change when committing on the same branch. Resolve
		// the shared refs directory through Git so linked worktrees also rebuild
		// their version metadata after a commit, checkout or tag change.
		for name in ["HEAD", "refs", "packed-refs"] {
			let output = Command::new("git").args(["rev-parse", "--git-path", name])
				.output().expect("Failed to locate Git version metadata");
			if output.status.success() {
				let path = String::from_utf8_lossy(&output.stdout);
				let path = path.trim();
				if Path::new(path).exists() {
					println!("cargo:rerun-if-changed={}", path);
				}
			}
		}
	}

	if env::var("GIT_HASH").is_err() {
		// Get the Git commit hash
		let output = Command::new("git").args(["rev-parse", "HEAD"]).output()
			.expect("Failed to execute 'git rev-parse HEAD' command");

		let git_hash = String::from_utf8_lossy(&output.stdout).trim().to_string();
		println!("cargo:rustc-env=GIT_HASH={}", git_hash);
	}

	// Determine version from git tag or dev
	if env::var("BARK_VERSION").is_err() {
		// Try to get tags pointing to current commit
		let output = Command::new("git")
			.args(["tag", "--points-at", "HEAD"])
			.output()
			.expect("Failed to execute 'git tag --points-at HEAD' command");

		let tags = String::from_utf8_lossy(&output.stdout);

		// Look for a tag matching bark-X.Y.Z pattern. Builds not made from
		// a release tag keep the crate version as a readable base but get
		// a -dev suffix.
		let version = tags.lines()
			.find(|line| line.starts_with("bark-"))
			.and_then(|tag| tag.strip_prefix("bark-"))
			.map(|v| v.to_string())
			.unwrap_or_else(|| {
				let base = env::var("CARGO_PKG_VERSION").expect("cargo sets CARGO_PKG_VERSION");
				format!("{}-dev", base)
			});

		println!("cargo:rustc-env=BARK_VERSION={}", version);
	}
}
