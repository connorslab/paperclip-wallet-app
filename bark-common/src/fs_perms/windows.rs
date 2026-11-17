//! Native private ACLs. Secret bytes are written only after handle validation.
use std::ffi::c_void;
use std::fs::File;
use std::io::Write;
use std::os::windows::{ffi::OsStrExt, io::{AsRawHandle, FromRawHandle, OwnedHandle}};
use std::path::{Component, Path, PathBuf, Prefix};
use std::ptr::{addr_of, null, null_mut};

use anyhow::{Context, ensure};
use windows_sys::Win32::{
	Foundation::{GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE, LocalFree},
	Security::{Authorization::*, *},
	Storage::FileSystem::*,
	System::{SystemServices::ACCESS_ALLOWED_ACE_TYPE, Threading::{GetCurrentProcess, OpenProcessToken},
		WindowsProgramming::{DRIVE_FIXED, DRIVE_REMOVABLE, FILE_RENAME_FLAG_POSIX_SEMANTICS, FILE_RENAME_FLAG_REPLACE_IF_EXISTS}},
};

struct LocalMemory(*mut c_void);
impl Drop for LocalMemory {
	fn drop(&mut self) { unsafe { LocalFree(self.0); } }
}

fn check(result: i32) -> anyhow::Result<()> {
	if result == 0 { return Err(std::io::Error::last_os_error().into()); }
	Ok(())
}

fn wide(path: &Path) -> anyhow::Result<Vec<u16>> {
	let mut value: Vec<_> = path.as_os_str().encode_wide().collect();
	ensure!(!value.contains(&0), "path contains a null character");
	value.push(0);
	Ok(value)
}

fn sid_string(sid: PSID) -> anyhow::Result<String> {
	ensure!(!sid.is_null(), "missing storage owner");
	let mut text = null_mut();
	unsafe { check(ConvertSidToStringSidW(sid, &mut text))?; }
	let allocation = LocalMemory(text.cast());
	let mut len = 0;
	// ConvertSidToStringSidW returns a valid, null-terminated SID string.
	unsafe { while *text.add(len) != 0 { len += 1; } }
	let result = String::from_utf16(unsafe { std::slice::from_raw_parts(text, len) })?;
	drop(allocation);
	Ok(result)
}

fn current_user() -> anyhow::Result<String> {
	let mut token = null_mut();
	unsafe { check(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token))?; }
	let token = unsafe { OwnedHandle::from_raw_handle(token) };
	let mut size = 0;
	unsafe { GetTokenInformation(token.as_raw_handle(), TokenUser, null_mut(), 0, &mut size); }
	ensure!(size > 0 && size < 65536, "invalid Windows token size");
	// usize storage provides the alignment required by TOKEN_USER and its SID.
	let mut buffer = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
	unsafe {
		check(GetTokenInformation(token.as_raw_handle(), TokenUser, buffer.as_mut_ptr().cast(), size, &mut size))?;
		sid_string((*buffer.as_ptr().cast::<TOKEN_USER>()).User.Sid)
	}
}

fn descriptor() -> anyhow::Result<LocalMemory> {
	let user = current_user()?;
	let text: Vec<u16> = format!("O:{user}D:P(A;OICI;FA;;;{user})(A;OICI;FA;;;SY)").encode_utf16().chain([0]).collect();
	let mut value = null_mut();
	unsafe { check(ConvertStringSecurityDescriptorToSecurityDescriptorW(text.as_ptr(), SDDL_REVISION_1, &mut value, null_mut()))?; }
	Ok(LocalMemory(value))
}

fn open(path: &Path, access: u32, creation: u32, attributes: *const SECURITY_ATTRIBUTES) -> anyhow::Result<File> {
	let path = wide(path)?;
	let handle = unsafe { CreateFileW(path.as_ptr(), access, FILE_SHARE_READ | FILE_SHARE_WRITE,
		attributes, creation, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, null_mut()) };
	if handle == INVALID_HANDLE_VALUE { return Err(std::io::Error::last_os_error().into()); }
	Ok(unsafe { File::from_raw_handle(handle) })
}

fn regular_handle(file: &File) -> anyhow::Result<()> {
	let mut info = BY_HANDLE_FILE_INFORMATION::default();
	unsafe { check(GetFileInformationByHandle(file.as_raw_handle(), &mut info))?; }
	ensure!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0, "linked storage is not supported");
	ensure!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0 || info.nNumberOfLinks == 1,
		"shared storage files are not supported");
	Ok(())
}

fn private_handle(file: &File) -> anyhow::Result<()> {
	regular_handle(file)?;
	let mut owner = null_mut();
	let mut acl = null_mut();
	let mut sd = null_mut();
	let status = unsafe { GetSecurityInfo(file.as_raw_handle(), SE_FILE_OBJECT,
		OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &mut owner, null_mut(), &mut acl, null_mut(), &mut sd) };
	if status != 0 { return Err(std::io::Error::from_raw_os_error(status as i32).into()); }
	let _allocation = LocalMemory(sd);
	let mut control = 0;
	let mut revision = 0;
	unsafe { check(GetSecurityDescriptorControl(sd, &mut control, &mut revision))?; }
	ensure!(control & SE_DACL_PROTECTED != 0, "storage ACL can inherit access from its parent");
	let user = current_user()?;
	ensure!(sid_string(owner)? == user, "storage is not owned by the current user");
	ensure!(!acl.is_null() && unsafe { (*acl).AceCount } > 0, "storage has no private ACL");
	let mut owner_access = false;
	for index in 0..unsafe { (*acl).AceCount } {
		let mut entry = null_mut();
		unsafe { check(GetAce(acl, index.into(), &mut entry))?; }
		let header = unsafe { &*entry.cast::<ACE_HEADER>() };
		ensure!(u32::from(header.AceType) == ACCESS_ALLOWED_ACE_TYPE, "unexpected storage ACL entry");
		let ace = entry.cast::<ACCESS_ALLOWED_ACE>();
		let sid = unsafe { sid_string(addr_of!((*ace).SidStart).cast_mut().cast())? };
		ensure!(sid == user || sid == "S-1-5-18", "storage grants access to another identity");
		owner_access |= sid == user && u32::from(header.AceFlags) & INHERIT_ONLY_ACE == 0;
	}
	ensure!(owner_access, "storage does not grant its owner access");
	Ok(())
}

fn guarded_path(path: &Path) -> anyhow::Result<(PathBuf, Vec<File>)> {
	ensure!(!path.components().any(|p| p == Component::ParentDir), "parent traversal is not supported");
	// Validate the caller's spelling before Windows absolute-path normalization
	// can remove trailing spaces or dots and turn it into a different file name.
	for part in path.components() {
		if let Component::Normal(part) = part {
			let text = part.to_string_lossy();
			ensure!(!text.contains(':') && !text.ends_with(['.', ' ']), "ambiguous storage path");
		}
	}
	let path = std::path::absolute(path)?;
	ensure!(matches!(path.components().next(), Some(Component::Prefix(p)) if matches!(p.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))),
		"private storage requires a local drive");
	let root = path.ancestors().last().context("missing local drive")?;
	let drive = unsafe { GetDriveTypeW(wide(root)?.as_ptr()) };
	ensure!(drive == DRIVE_FIXED || drive == DRIVE_REMOVABLE, "private storage requires a local disk");
	let mut handles = Vec::new();
	for parent in path.ancestors().skip(1).collect::<Vec<_>>().into_iter().rev() {
		// Metadata-only access does not enforce Windows sharing restrictions.
		let handle = open(parent, READ_CONTROL | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY, OPEN_EXISTING, null())?;
		regular_handle(&handle)?;
		handles.push(handle);
	}
	Ok((path, handles))
}

pub fn refuse_if_loose(path: &Path, _mode: u32) -> anyhow::Result<()> {
	let (path, _parents) = guarded_path(path)?;
	private_handle(&open(&path, READ_CONTROL | FILE_READ_ATTRIBUTES, OPEN_EXISTING, null())?)
		.context("storage must be private and owned by the current user")
}

pub fn harden(path: &Path, _mode: u32) -> anyhow::Result<()> {
	let (path, _parents) = guarded_path(path)?;
	let file = open(&path, READ_CONTROL | WRITE_DAC | WRITE_OWNER | FILE_READ_ATTRIBUTES, OPEN_EXISTING, null())?;
	regular_handle(&file)?;
	let sd = descriptor()?;
	let mut owner = null_mut();
	let mut acl = null_mut();
	let mut present = 0;
	let mut defaulted = 0;
	unsafe {
		check(GetSecurityDescriptorOwner(sd.0, &mut owner, &mut defaulted))?;
		check(GetSecurityDescriptorDacl(sd.0, &mut present, &mut acl, &mut defaulted))?;
		ensure!(present != 0 && !acl.is_null(), "missing private ACL");
		let status = SetSecurityInfo(file.as_raw_handle(), SE_FILE_OBJECT,
			OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
			owner, null_mut(), acl, null());
		if status != 0 { return Err(std::io::Error::from_raw_os_error(status as i32).into()); }
	}
	private_handle(&file)
}

fn create(path: &Path) -> anyhow::Result<File> {
	let sd = descriptor()?;
	let attributes = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
		lpSecurityDescriptor: sd.0, bInheritHandle: 0 };
	let file = open(path, GENERIC_READ | GENERIC_WRITE | READ_CONTROL | DELETE, CREATE_NEW, &attributes)?;
	if let Err(error) = private_handle(&file) {
		drop(file);
		let _ = std::fs::remove_file(path);
		return Err(error);
	}
	Ok(file)
}

pub fn create_new_owner_only(path: &Path, contents: &[u8]) -> anyhow::Result<()> {
	let (path, _parents) = guarded_path(path)?;
	let mut file = create(&path)?;
	let result = file.write_all(contents).and_then(|_| file.sync_all());
	drop(file);
	if result.is_err() { let _ = std::fs::remove_file(&path); }
	result.context("failed to write private storage")
}

pub fn write_atomic_owner_only(path: &Path, contents: &[u8]) -> anyhow::Result<()> {
	let (path, _parents) = guarded_path(path)?;
	let parent = path.parent().context("missing storage parent")?;
	let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
	for attempt in 0..16 {
		let temporary = parent.join(format!(".paperclip-{}-{nanos}-{attempt}.tmp", std::process::id()));
		let mut file = match create(&temporary) {
			Ok(file) => file,
			Err(error) if error.downcast_ref::<std::io::Error>().is_some_and(|e| e.kind() == std::io::ErrorKind::AlreadyExists) => continue,
			Err(error) => return Err(error),
		};
		let result = (|| -> anyhow::Result<()> {
			file.write_all(contents)?;
			file.sync_all()?;
			rename_private_file(&file, &path)?;
			file.sync_all()?;
			Ok(())
		})();
		drop(file);
		if result.is_err() { let _ = std::fs::remove_file(&temporary); }
		return result;
	}
	anyhow::bail!("failed to reserve a private temporary file")
}

fn rename_private_file(file: &File, destination: &Path) -> anyhow::Result<()> {
	let name = wide(destination)?;
	let bytes = std::mem::size_of::<FILE_RENAME_INFO>() + name.len() * 2;
	// The variable-sized Win32 structure contains a HANDLE and must be aligned.
	let mut storage = vec![0usize; bytes.div_ceil(std::mem::size_of::<usize>())];
	let info = storage.as_mut_ptr().cast::<FILE_RENAME_INFO>();
	unsafe {
		// Windows 10+ POSIX replacement keeps existing readers on the old file.
		// Rename the still-open private handle, never a reopened staging path.
		(*info).Anonymous.Flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS;
		(*info).FileNameLength = ((name.len() - 1) * 2).try_into()?;
		std::ptr::copy_nonoverlapping(name.as_ptr(), std::ptr::addr_of_mut!((*info).FileName).cast(), name.len());
		check(SetFileInformationByHandle(file.as_raw_handle(), FileRenameInfoEx, info.cast(), bytes.try_into()?))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn fresh_secret_is_private_before_reuse_and_never_overwritten() {
		let dir = tempfile::tempdir().unwrap();
		let path = dir.path().join("secret");
		create_new_owner_only(&path, b"synthetic first value").unwrap();
		refuse_if_loose(&path, 0o600).unwrap();
		assert!(create_new_owner_only(&path, b"replacement").is_err());
		assert_eq!(std::fs::read(&path).unwrap(), b"synthetic first value");
	}

	#[test]
	fn explicit_hardening_sets_private_owner_and_acl() {
		let dir = tempfile::tempdir().unwrap();
		let path = dir.path().join("file");
		std::fs::write(&path, b"synthetic").unwrap();
		harden(&path, 0o600).unwrap();
		refuse_if_loose(&path, 0o600).unwrap();
		harden(dir.path(), 0o700).unwrap();
		refuse_if_loose(dir.path(), 0o700).unwrap();
	}

	#[test]
	fn atomic_replace_keeps_old_reader_and_new_private_file() {
		let dir = tempfile::tempdir().unwrap();
		let path = dir.path().join("state");
		create_new_owner_only(&path, b"before").unwrap();
		let mut reader = File::open(&path).unwrap();
		write_atomic_owner_only(&path, b"after").unwrap();
		let mut old = Vec::new();
		std::io::Read::read_to_end(&mut reader, &mut old).unwrap();
		assert_eq!(old, b"before");
		assert_eq!(std::fs::read(&path).unwrap(), b"after");
		refuse_if_loose(&path, 0o600).unwrap();
		assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
	}

	#[test]
	fn failed_replacement_preserves_destination_and_removes_own_staging_file() {
		let dir = tempfile::tempdir().unwrap();
		let destination = dir.path().join("directory");
		std::fs::create_dir(&destination).unwrap();
		assert!(write_atomic_owner_only(&destination, b"synthetic").is_err());
		assert!(destination.is_dir());
		assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
	}

	#[test]
	fn unrestricted_acl_is_rejected_without_changing_it() {
		let dir = tempfile::tempdir().unwrap();
		let path = dir.path().join("file");
		create_new_owner_only(&path, b"synthetic").unwrap();
		let file = open(&path, READ_CONTROL | WRITE_DAC, OPEN_EXISTING, null()).unwrap();
		let status = unsafe { SetSecurityInfo(file.as_raw_handle(), SE_FILE_OBJECT,
			DACL_SECURITY_INFORMATION, null_mut(), null_mut(), null(), null()) };
		assert_eq!(status, 0);
		drop(file);
		assert!(refuse_if_loose(&path, 0o600).is_err());
		assert!(refuse_if_loose(&path, 0o600).is_err());
	}

	#[test]
	fn shared_file_cannot_be_adopted_or_hardened_through_an_alias() {
		let dir = tempfile::tempdir().unwrap();
		let path = dir.path().join("file");
		create_new_owner_only(&path, b"synthetic").unwrap();
		std::fs::hard_link(&path, dir.path().join("alias")).unwrap();
		assert!(refuse_if_loose(&path, 0o600).is_err());
		assert!(harden(&path, 0o600).is_err());
		assert_eq!(std::fs::read(&path).unwrap(), b"synthetic");
	}

	#[test]
	fn ancestor_handles_prevent_relocation_during_secret_operations() {
		let dir = tempfile::tempdir().unwrap();
		let folder = dir.path().join("private");
		std::fs::create_dir(&folder).unwrap();
		let (_, guards) = guarded_path(&folder.join("file")).unwrap();
		assert!(std::fs::rename(&folder, dir.path().join("moved")).is_err());
		drop(guards);
		std::fs::rename(&folder, dir.path().join("moved")).unwrap();
	}

	#[test]
	fn junction_ancestors_are_rejected_before_writing() {
		let dir = tempfile::tempdir().unwrap();
		let target = dir.path().join("target");
		let junction = dir.path().join("junction");
		std::fs::create_dir(&target).unwrap();
		assert!(std::process::Command::new("cmd").args(["/C", "mklink", "/J"])
			.arg(&junction).arg(&target).stdout(std::process::Stdio::null()).status().unwrap().success());
		assert!(create_new_owner_only(&junction.join("secret"), b"synthetic").is_err());
		assert!(!target.join("secret").exists());
		std::fs::remove_dir(junction).unwrap();
	}

	#[test]
	fn ambiguous_paths_are_rejected_without_creating_storage() {
		let dir = tempfile::tempdir().unwrap();
		for name in ["secret:stream", "secret.", "secret ", "..\\secret"] {
			let path = PathBuf::from(format!("{}\\{name}", dir.path().display()));
			assert!(create_new_owner_only(&path, b"synthetic").is_err(), "accepted {name}");
		}
		assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
	}
}
