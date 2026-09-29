//! Tokens: 32 random bytes, base64url without padding, kept in a type that never prints.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

use crate::InstanceError;

/// A credential. `Debug` and `Display` print `***`.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    pub fn new(value: String) -> Self {
        Self(value)
    }

    pub fn generate() -> Result<Self, InstanceError> {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes)
            .map_err(|e| InstanceError::io("getrandom", std::io::Error::other(e.to_string())))?;
        Ok(Self(URL_SAFE_NO_PAD.encode(bytes)))
    }

    /// The raw value, for the wire only.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// Compares in constant time.
    pub fn matches(&self, other: &str) -> bool {
        let (a, b) = (self.0.as_bytes(), other.as_bytes());
        if a.len() != b.len() {
            return false;
        }
        a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("***")
    }
}

impl std::fmt::Display for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("***")
    }
}

/// Writes the token to a temp file created 0600, then renames it into place.
pub fn write_token(path: &Path, token: &Secret) -> Result<(), InstanceError> {
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| InstanceError::io(format!("create {}", tmp.display()), e))?;
    f.write_all(token.expose().as_bytes())
        .map_err(|e| InstanceError::io(format!("write {}", tmp.display()), e))?;
    std::fs::rename(&tmp, path)
        .map_err(|e| InstanceError::io(format!("rename to {}", path.display()), e))
}

pub fn read_token(path: &Path) -> Result<Secret, InstanceError> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| InstanceError::io(format!("read {}", path.display()), e))?;
    Ok(Secret(text.trim().to_owned()))
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn tokens() {
        let a = Secret::generate().unwrap();
        let b = Secret::generate().unwrap();
        assert_eq!(a.expose().len(), 43);
        assert!(!a.matches(b.expose()));
        assert!(a.matches(a.expose()));
        assert_eq!(format!("{a} {a:?}"), "*** ***");
        let path = std::env::temp_dir().join(format!("mapo-token-test-{}", std::process::id()));
        write_token(&path, &a).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!((mode, read_token(&path).unwrap()), (0o600, a));
        std::fs::remove_file(&path).unwrap();
    }
}
