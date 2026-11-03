//! Action identities are data. Implementations belong to the compiled shell.
use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};

pub const MAX_ACTIONS: usize = 256;
pub const MAX_CATALOG_BYTES: usize = 128 * 1024;
pub const LEGACY_LAUNCHER_ACTION: &str = "denial_launcher.openApplications";
/// The shell action that shows the color tuning editor.
pub const COLOR_TUNING_ACTION: &str = "denial_desktop.colorTuning";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionDescriptor {
    pub id: String,
    pub label: String,
    pub description: String,
    pub provider: String,
}

pub fn valid_id(id: &str) -> bool {
    id.len() <= 256
        && id.split_once('.').is_some_and(|(package, name)| {
            !package.is_empty()
                && !name.is_empty()
                && package != "native"
                && package
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
                && name
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'-'))
        })
}

#[derive(Default, Debug)]
pub struct ActionCatalog {
    pub generation: u64,
    pub actions: Vec<ActionDescriptor>,
    pub pending: VecDeque<(u64, String, Option<i64>)>,
}

impl ActionCatalog {
    pub fn decode(generation: u64, json: &str) -> Result<Self, &'static str> {
        if generation == 0 || json.len() > MAX_CATALOG_BYTES {
            return Err("invalid action catalog size or generation");
        }
        let actions: Vec<ActionDescriptor> =
            serde_json::from_str(json).map_err(|_| "invalid action descriptors")?;
        if actions.len() > MAX_ACTIONS {
            return Err("too many actions");
        }
        let mut ids = HashSet::new();
        for action in &actions {
            if !valid_id(&action.id)
                || !ids.insert(&action.id)
                || action.label.is_empty()
                || action.label.len() > 256
                || action.description.len() > 2048
                || action.provider.is_empty()
                || action.provider.len() > 256
                || [&action.label, &action.description, &action.provider]
                    .iter()
                    .any(|s| s.chars().any(char::is_control))
            {
                return Err("invalid or duplicate action descriptor");
            }
        }
        Ok(Self {
            generation,
            actions,
            pending: VecDeque::new(),
        })
    }

    pub fn contains(&self, id: &str) -> bool {
        self.actions.iter().any(|a| a.id == id)
    }
    pub fn queue(&mut self, id: String, monitor_id: Option<i64>) -> bool {
        if !self.contains(&id) || self.pending.len() >= MAX_ACTIONS {
            return false;
        }
        self.pending.push_back((self.generation, id, monitor_id));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn descriptor(id: &str) -> ActionDescriptor {
        ActionDescriptor {
            id: id.into(),
            label: "Example".into(),
            description: "".into(),
            provider: "Example plugin".into(),
        }
    }
    #[test]
    fn validates_catalog_atomically_and_rejects_collisions() {
        let a = descriptor("example.doSomething");
        assert!(
            ActionCatalog::decode(1, &serde_json::to_string(&vec![a.clone()]).unwrap()).is_ok()
        );
        assert!(
            ActionCatalog::decode(1, &serde_json::to_string(&vec![a.clone(), a]).unwrap()).is_err()
        );
        assert!(ActionCatalog::decode(0, "[]").is_err());
        assert!(!valid_id("native.lock"));
        assert!(!valid_id("missing_namespace"));
    }
    #[test]
    fn generation_replacement_drops_queued_invocations_and_disabled_actions() {
        let mut old = ActionCatalog::decode(
            1,
            &serde_json::to_string(&vec![descriptor("example.run")]).unwrap(),
        )
        .unwrap();
        assert!(old.queue("example.run".into(), Some(3)));
        assert!(!old.queue("missing.run".into(), None));
        let new = ActionCatalog::decode(2, "[]").unwrap();
        old = new;
        assert!(old.pending.is_empty());
        assert!(!old.queue("example.run".into(), None));
    }
}
