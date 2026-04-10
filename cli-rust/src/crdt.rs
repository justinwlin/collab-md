use similar::{ChangeTag, TextDiff};
use std::fmt;
use yrs::updates::decoder::Decode;
use yrs::{Doc, GetString, ReadTxn, StateVector, Text, Transact, Update};

/// Wrapper around a Yjs CRDT document for collaborative text editing.
/// Concurrent edits from multiple users merge automatically.
pub struct CrdtDoc {
    doc: Doc,
}

impl CrdtDoc {
    /// Initialize from plain text (no CRDT history).
    pub fn from_text(text: &str) -> Self {
        let doc = Doc::new();
        if !text.is_empty() {
            let text_ref = doc.get_or_insert_text("content");
            let mut txn = doc.transact_mut();
            text_ref.insert(&mut txn, 0, text);
        }
        CrdtDoc { doc }
    }

    /// Initialize from a list of binary CRDT updates (received from server).
    pub fn from_updates(updates: &[Vec<u8>]) -> Result<Self, CrdtError> {
        let doc = Doc::new();
        {
            let mut txn = doc.transact_mut();
            for update_bytes in updates {
                let update =
                    Update::decode_v1(update_bytes).map_err(|_| CrdtError::DecodeError)?;
                let _ = txn.apply_update(update);
            }
        }
        Ok(CrdtDoc { doc })
    }

    /// Get the current text content.
    pub fn get_text(&self) -> String {
        let text_ref = self.doc.get_or_insert_text("content");
        text_ref.get_string(&self.doc.transact())
    }

    /// Apply a local text change (diff between old and new), return the binary CRDT update.
    /// Uses character-level diff, batched into larger operations for yrs compatibility.
    pub fn apply_local_change(&self, old_text: &str, new_text: &str) -> Vec<u8> {
        let text_ref = self.doc.get_or_insert_text("content");
        let sv = self.doc.transact().state_vector();

        // Compute char diff and batch consecutive same-type ops into single operations
        let diff = TextDiff::from_chars(old_text, new_text);
        let mut ops: Vec<(ChangeTag, String)> = Vec::new();

        for change in diff.iter_all_changes() {
            let tag = change.tag();
            let val = change.value();
            if let Some(last) = ops.last_mut() {
                if last.0 == tag {
                    last.1.push_str(val);
                    continue;
                }
            }
            ops.push((tag, val.to_string()));
        }

        let mut txn = self.doc.transact_mut();
        let mut pos: u32 = 0;

        for (tag, content) in &ops {
            let char_count = content.chars().count() as u32;
            match tag {
                ChangeTag::Equal => pos += char_count,
                ChangeTag::Delete => {
                    text_ref.remove_range(&mut txn, pos, char_count);
                }
                ChangeTag::Insert => {
                    text_ref.insert(&mut txn, pos, content);
                    pos += char_count;
                }
            }
        }

        drop(txn);
        self.doc
            .transact()
            .encode_state_as_update_v1(&sv)
    }

    /// Apply a remote binary CRDT update, return the resulting text.
    pub fn apply_remote_update(&self, update_bytes: &[u8]) -> Result<String, CrdtError> {
        let update = Update::decode_v1(update_bytes).map_err(|_| CrdtError::DecodeError)?;
        self.doc
            .transact_mut()
            .apply_update(update)
            .map_err(|_| CrdtError::DecodeError)?;
        Ok(self.get_text())
    }

    /// Reset the document to plain text (when receiving a non-CRDT update like from REST API).
    pub fn reset_to_text(&self, text: &str) {
        let text_ref = self.doc.get_or_insert_text("content");
        let mut txn = self.doc.transact_mut();
        let current = text_ref.get_string(&txn);
        let current_len = current.chars().count() as u32;
        if current_len > 0 {
            text_ref.remove_range(&mut txn, 0, current_len);
        }
        if !text.is_empty() {
            text_ref.insert(&mut txn, 0, text);
        }
    }

    /// Encode the full document state as a binary blob.
    pub fn encode_state(&self) -> Vec<u8> {
        self.doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default())
    }
}

#[derive(Debug)]
pub enum CrdtError {
    DecodeError,
}

impl fmt::Display for CrdtError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CrdtError::DecodeError => write!(f, "failed to decode CRDT update"),
        }
    }
}

impl std::error::Error for CrdtError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_doc_is_empty() {
        let doc = CrdtDoc::new();
        assert_eq!(doc.get_text(), "");
    }

    #[test]
    fn test_from_text() {
        let doc = CrdtDoc::from_text("hello world");
        assert_eq!(doc.get_text(), "hello world");
    }

    #[test]
    fn test_local_change_and_get_text() {
        let doc = CrdtDoc::from_text("hello");
        doc.apply_local_change("hello", "hello world");
        assert_eq!(doc.get_text(), "hello world");
    }

    #[test]
    fn test_remote_update_roundtrip() {
        // doc1 creates the origin state
        let doc1 = CrdtDoc::from_text("hello");
        // doc2 initializes from doc1's state (shared CRDT history)
        let doc2 = CrdtDoc::from_updates(&[doc1.encode_state()]).unwrap();
        assert_eq!(doc2.get_text(), "hello");

        let update = doc1.apply_local_change("hello", "hello world");
        let result = doc2.apply_remote_update(&update).unwrap();
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_concurrent_edits_merge() {
        // Create shared origin
        let origin = CrdtDoc::from_text("hello world");
        let state = origin.encode_state();

        // Both init from same CRDT state
        let doc1 = CrdtDoc::from_updates(&[state.clone()]).unwrap();
        let doc2 = CrdtDoc::from_updates(&[state]).unwrap();

        // Alice inserts "beautiful " after "hello "
        let update1 = doc1.apply_local_change("hello world", "hello beautiful world");
        // Bob appends "!"
        let update2 = doc2.apply_local_change("hello world", "hello world!");

        // Each applies the other's update
        doc1.apply_remote_update(&update2).unwrap();
        doc2.apply_remote_update(&update1).unwrap();

        // Both converge to the same text with both edits
        let text1 = doc1.get_text();
        let text2 = doc2.get_text();
        assert_eq!(text1, text2, "CRDTs must converge");
        assert!(text1.contains("beautiful"), "Should contain Alice's edit");
        assert!(text1.contains("!"), "Should contain Bob's edit");
    }

    #[test]
    fn test_concurrent_edits_same_location() {
        let origin = CrdtDoc::from_text("hello");
        let state = origin.encode_state();

        let doc1 = CrdtDoc::from_updates(&[state.clone()]).unwrap();
        let doc2 = CrdtDoc::from_updates(&[state]).unwrap();

        // Both append different text at the end
        let update1 = doc1.apply_local_change("hello", "hello Alice");
        let update2 = doc2.apply_local_change("hello", "hello Bob");

        doc1.apply_remote_update(&update2).unwrap();
        doc2.apply_remote_update(&update1).unwrap();

        // Must converge (order may vary, but both edits present)
        let text1 = doc1.get_text();
        let text2 = doc2.get_text();
        assert_eq!(text1, text2, "CRDTs must converge");
        assert!(text1.contains("Alice"), "Should contain Alice's edit");
        assert!(text1.contains("Bob"), "Should contain Bob's edit");
    }

    #[test]
    fn test_from_updates() {
        let doc1 = CrdtDoc::from_text("start");
        let update1 = doc1.apply_local_change("start", "start middle");
        let update2 = doc1.apply_local_change("start middle", "start middle end");

        // New client initializes from accumulated updates
        let state = doc1.encode_state();
        let doc2 = CrdtDoc::from_updates(&[state]).unwrap();
        assert_eq!(doc2.get_text(), "start middle end");
    }

    #[test]
    fn test_reset_to_text() {
        let doc = CrdtDoc::from_text("original");
        doc.apply_local_change("original", "modified");
        assert_eq!(doc.get_text(), "modified");

        doc.reset_to_text("reset content");
        assert_eq!(doc.get_text(), "reset content");
    }

    #[test]
    fn test_empty_change_produces_small_update() {
        let doc = CrdtDoc::from_text("same");
        let update = doc.apply_local_change("same", "same");
        // Empty diff should produce a minimal update
        assert!(!update.is_empty()); // yrs always encodes something
    }

    #[test]
    fn test_unicode_in_inserts() {
        let doc1 = CrdtDoc::from_text("hello");
        let doc2 = CrdtDoc::from_updates(&[doc1.encode_state()]).unwrap();

        let update = doc1.apply_local_change("hello", "hello café ☕");
        let result = doc2.apply_remote_update(&update).unwrap();
        assert_eq!(result, "hello café ☕");
    }

    #[test]
    fn test_unicode_base_text() {
        // Verify unicode text can be stored and retrieved
        let doc = CrdtDoc::from_text("émoji: 🎉");
        assert_eq!(doc.get_text(), "émoji: 🎉");

        let doc2 = CrdtDoc::from_updates(&[doc.encode_state()]).unwrap();
        assert_eq!(doc2.get_text(), "émoji: 🎉");
    }
}
