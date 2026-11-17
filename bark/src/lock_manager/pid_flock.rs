//! Named locks for a single-process-per-datadir deployment.
//!
//! # Safety scope
//!
//! Prevents concurrent access by callers within the **current OS
//! process**. Construction additionally **refuses to start a second
//! process** holding the same datadir: an exclusive OS-level lock is
//! acquired on `<datadir>/LOCK` (`flock(2)` on Unix, `LockFileEx` on
//! Windows). Windows reserves a byte beyond the PID so other handles can
//! still read the diagnostic PID. The OS releases that
//! lock when the process exits, even on SIGKILL or a crash.
//!
//! From that point on, all per-key locking is in-memory: by
//! construction, this is the only process touching `datadir`, so the
//! cross-process semantics of file-based per-key locking would be
//! redundant.
//!
//! # Platform support
//!
//! Linux, macOS, Android, Windows. Not available on `wasm32`.
//!
//! # When to use
//!
//! - You run a single-process-per-datadir deployment (CLIs, daemons).
//! - You want that constraint expressed as a type rather than as a
//!   separate setup step that callers might forget.

use std::fs::{self, File, TryLockError};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::Context;
#[cfg(windows)]
use std::os::windows::io::AsRawHandle;
#[cfg(windows)]
use windows_sys::Win32::{
	Foundation::ERROR_LOCK_VIOLATION,
	Storage::FileSystem::{LockFileEx, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY},
	System::IO::{OVERLAPPED, OVERLAPPED_0, OVERLAPPED_0_0},
};

use super::{LockGuard, LockManager, PidLockError};
use super::internal_memory::InternalMemoryLockManager;

/// File name used for the datadir-level PID lock.
pub const LOCK_FILE: &str = "LOCK";

#[cfg(not(windows))]
fn try_pid_lock(file: &File) -> Result<(), TryLockError> {
	file.try_lock()
}

#[cfg(windows)]
fn try_pid_lock(file: &File) -> Result<(), TryLockError> {
	// Windows byte-range locks deny reads through *other handles*, including
	// handles in this process. Locking the PID bytes would break daemon discovery.
	// This byte remains covered by legacy whole-file locks, preserving exclusion.
	let mut overlap = OVERLAPPED {
		Anonymous: OVERLAPPED_0 { Anonymous: OVERLAPPED_0_0 { Offset: u32::MAX, OffsetHigh: 0 } },
		..Default::default()
	};
	// The file is synchronous and FAIL_IMMEDIATELY forbids pending acquisition;
	// the OVERLAPPED buffer therefore need only live for this call. File drop
	// releases the lock through CloseHandle, including after process death.
	let locked = unsafe {
		LockFileEx(file.as_raw_handle(), LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
			0, 1, 0, &mut overlap)
	};
	if locked != 0 { return Ok(()); }
	let error = std::io::Error::last_os_error();
	if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
		Err(TryLockError::WouldBlock)
	} else {
		Err(TryLockError::Error(error))
	}
}

#[cfg(not(windows))]
fn open_lock_file(path: &Path) -> anyhow::Result<File> {
	File::options()
		.read(true)
		.write(true)
		.create(true)
		.truncate(false)
		.open(path)
		.with_context(|| format!("failed to open lock file {}", path.display()))
}

#[cfg(windows)]
fn open_lock_file(path: &Path) -> anyhow::Result<File> {
	bark_common::fs_perms::open_owner_only(path)
		.context("PID lock requires private user-owned storage")
}


pub struct FlockPidLockManager {
	// Holds the OS lock for the lifetime of the manager. Dropped on
	// drop of the manager — at which point the OS releases the lock.
	_pid_file: File,
	datadir: PathBuf,
	in_process: InternalMemoryLockManager,
}

impl FlockPidLockManager {
	/// Take the pid lock on `datadir` and construct a manager. Fails
	/// with [`PidLockError::AlreadyHeld`] if another process already
	/// holds the lock, or [`PidLockError::SetupFailed`] for any other
	/// I/O failure.
	pub fn new(datadir: impl Into<PathBuf>) -> Result<Self, PidLockError> {
		Self::new_with_lock_file(datadir, LOCK_FILE)
	}

	/// Like [`new`](Self::new), but locking a caller-chosen file name
	pub fn new_with_lock_file(
		datadir: impl Into<PathBuf>,
		lock_file: &str,
	) -> Result<Self, PidLockError> {
		let datadir = datadir.into();
		let setup = |source: anyhow::Error| PidLockError::SetupFailed {
			datadir: datadir.clone(),
			source,
		};

		fs::create_dir_all(&datadir)
			.with_context(|| format!("failed to create datadir {}", datadir.display()))
			.map_err(setup)?;

		let path = datadir.join(lock_file);
		let mut file = open_lock_file(&path).map_err(setup)?;

		match try_pid_lock(&file) {
			Ok(()) => {}
			Err(TryLockError::WouldBlock) => {
				let mut holder = String::new();
				let _ = file.read_to_string(&mut holder);
				let pid = holder.trim().parse::<u32>().ok();
				return Err(PidLockError::AlreadyHeld { datadir, pid });
			}
			Err(TryLockError::Error(e)) => {
				return Err(setup(anyhow::Error::from(e)
					.context(format!("failed to acquire pid lock at {}", path.display()))));
			}
		}

		// Stamp the holder PID for diagnostics. Truncate first to drop
		// any stale content left by a previous holder.
		file.set_len(0).context("failed to truncate pid lock").map_err(setup)?;
		write!(file, "{}", std::process::id())
			.context("failed to write pid lock").map_err(&setup)?;
		file.flush().context("failed to flush pid lock").map_err(setup)?;

		Ok(Self {
			_pid_file: file,
			datadir,
			in_process: InternalMemoryLockManager::new(),
		})
	}

	pub fn datadir(&self) -> &Path {
		&self.datadir
	}
}

impl std::fmt::Debug for FlockPidLockManager {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.debug_struct("FlockPidLockManager").field("datadir", &self.datadir).finish()
	}
}

#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
impl LockManager for FlockPidLockManager {
	async fn try_lock(&self, key: &str) -> Option<Box<dyn LockGuard>> {
		self.in_process.try_lock(key).await
	}

	async fn lock(
		&self,
		key: &str,
		timeout: std::time::Duration,
	) -> anyhow::Result<Box<dyn LockGuard>> {
		self.in_process.lock(key, timeout).await
	}
}

#[cfg(test)]
mod test {
	use super::*;

	fn tmp_dir() -> tempfile::TempDir {
		// Clock resolution is not a uniqueness guarantee when tests run in parallel.
		tempfile::Builder::new().prefix("bark-pid-lock-test-").tempdir().unwrap()
	}

	#[tokio::test]
	async fn acquire_writes_holder_pid() {
		let directory = tmp_dir();
		let dir = directory.path();
		let mgr = FlockPidLockManager::new(&dir).unwrap();
		let contents = fs::read_to_string(dir.join(LOCK_FILE)).unwrap();
		assert_eq!(contents, std::process::id().to_string());
		drop(mgr);
		let _ = fs::remove_dir_all(&dir);
	}

	#[tokio::test]
	async fn second_acquire_in_same_process_is_refused() {
		let directory = tmp_dir();
		let dir = directory.path();
		let _held = FlockPidLockManager::new(&dir).unwrap();
		let err = FlockPidLockManager::new(&dir).unwrap_err();
		assert!(
			err.to_string().contains("another process is already using datadir"),
			"unexpected error: {}", err,
		);
		drop(_held);
		let _ = fs::remove_dir_all(&dir);
	}

	#[test]
	fn whole_file_probe_observes_owner_without_blocking_pid_reads() {
		let directory = tmp_dir();
		let dir = directory.path();
		let held = FlockPidLockManager::new(&dir).unwrap();
		let probe = File::open(dir.join(LOCK_FILE)).unwrap();
		assert!(matches!(probe.try_lock(), Err(TryLockError::WouldBlock)));
		assert_eq!(fs::read_to_string(dir.join(LOCK_FILE)).unwrap(), std::process::id().to_string());
		#[cfg(windows)]
		bark_common::fs_perms::refuse_if_loose(&dir.join(LOCK_FILE), 0o600).unwrap();
		drop(held);
		probe.try_lock().unwrap();
		drop(probe);
		fs::remove_dir_all(dir).unwrap();
	}

	#[test]
	fn legacy_whole_file_owner_prevents_pid_lock_acquisition() {
		let directory = tmp_dir();
		let dir = directory.path();
		fs::create_dir_all(&dir).unwrap();
		let legacy = open_lock_file(&dir.join(LOCK_FILE)).unwrap();
		legacy.try_lock().unwrap();
		assert!(matches!(FlockPidLockManager::new(&dir), Err(PidLockError::AlreadyHeld { .. })));
		drop(legacy);
		let owner = FlockPidLockManager::new(&dir).unwrap();
		drop(owner);
		fs::remove_dir_all(dir).unwrap();
	}

	#[tokio::test]
	async fn distinct_lock_files_dont_conflict() {
		let directory = tmp_dir();
		let dir = directory.path();
		let _default = FlockPidLockManager::new(&dir).unwrap();
		let _custom = FlockPidLockManager::new_with_lock_file(&dir, "other.lock").unwrap();
		let err = FlockPidLockManager::new_with_lock_file(&dir, "other.lock").unwrap_err();
		assert!(matches!(err, PidLockError::AlreadyHeld { .. }));
		let _ = fs::remove_dir_all(&dir);
	}

	#[tokio::test]
	async fn reacquire_after_drop_succeeds() {
		let directory = tmp_dir();
		let dir = directory.path();
		let first = FlockPidLockManager::new(&dir).unwrap();
		drop(first);
		let _second = FlockPidLockManager::new(&dir).unwrap();
		let _ = fs::remove_dir_all(&dir);
	}

	#[tokio::test]
	async fn per_key_locking_works_in_process() {
		let directory = tmp_dir();
		let dir = directory.path();
		let mgr = FlockPidLockManager::new(&dir).unwrap();

		let g = mgr.try_lock("foo").await;
		assert!(g.is_some());

		let busy = mgr.try_lock("foo").await;
		assert!(busy.is_none(), "same key should be blocked");

		let g2 = mgr.try_lock("bar").await;
		assert!(g2.is_some(), "different key should be free");

		let _ = fs::remove_dir_all(&dir);
	}

	#[tokio::test]
	async fn separate_wallets_do_not_share_named_locks() {
		let first_directory = tmp_dir();
		let second_directory = tmp_dir();
		let first_dir = first_directory.path();
		let second_dir = second_directory.path();
		let first = FlockPidLockManager::new(&first_dir).unwrap();
		let second = FlockPidLockManager::new(&second_dir).unwrap();
		let _first_guard = first.try_lock("same-operation").await.unwrap();
		let _second_guard = second.try_lock("same-operation").await.unwrap();
		assert!(first.try_lock("same-operation").await.is_none());
		assert!(second.try_lock("same-operation").await.is_none());
	}
}
