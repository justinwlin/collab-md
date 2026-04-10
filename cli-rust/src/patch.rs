use serde::{Deserialize, Serialize};
use similar::{ChangeTag, TextDiff};
use std::fmt;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PatchOp {
    pub op: OpType,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum OpType {
    Equal,
    Delete,
    Insert,
}

#[allow(dead_code)]
/// Compute a line-based diff between old and new text, returning a list of patch operations.
/// Consecutive operations of the same type are merged to minimize payload size.
pub fn compute_patch(old: &str, new: &str) -> Vec<PatchOp> {
    if old == new {
        return vec![];
    }

    let diff = TextDiff::from_lines(old, new);
    let mut ops: Vec<PatchOp> = Vec::new();

    for change in diff.iter_all_changes() {
        let tag = match change.tag() {
            ChangeTag::Equal => OpType::Equal,
            ChangeTag::Delete => OpType::Delete,
            ChangeTag::Insert => OpType::Insert,
        };
        let content = change.value().to_string();

        // Merge consecutive ops of the same type
        if let Some(last) = ops.last_mut() {
            if std::mem::discriminant(&last.op) == std::mem::discriminant(&tag) {
                last.content.push_str(&content);
                continue;
            }
        }

        ops.push(PatchOp {
            op: tag,
            content,
        });
    }

    ops
}

/// Apply a list of patch operations to the original text.
/// Returns the new text, or an error if the patch doesn't match.
pub fn apply_patch(original: &str, ops: &[PatchOp]) -> Result<String, PatchError> {
    if ops.is_empty() {
        return Ok(original.to_string());
    }

    let mut result = String::with_capacity(original.len());
    let original_bytes = original.as_bytes();
    let mut pos: usize = 0;

    for op in ops {
        match op.op {
            OpType::Equal => {
                let content = op.content.as_bytes();
                let end = pos + content.len();
                if end > original_bytes.len() {
                    return Err(PatchError::OutOfBounds);
                }
                if &original_bytes[pos..end] != content {
                    return Err(PatchError::Mismatch);
                }
                result.push_str(&op.content);
                pos = end;
            }
            OpType::Delete => {
                let content = op.content.as_bytes();
                let end = pos + content.len();
                if end > original_bytes.len() {
                    return Err(PatchError::OutOfBounds);
                }
                if &original_bytes[pos..end] != content {
                    return Err(PatchError::Mismatch);
                }
                // Skip deleted content
                pos = end;
            }
            OpType::Insert => {
                result.push_str(&op.content);
            }
        }
    }

    if pos != original_bytes.len() {
        return Err(PatchError::LeftoverContent);
    }

    Ok(result)
}

#[derive(Debug)]
pub enum PatchError {
    Mismatch,
    OutOfBounds,
    LeftoverContent,
}

impl fmt::Display for PatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PatchError::Mismatch => write!(f, "patch content does not match document"),
            PatchError::OutOfBounds => write!(f, "patch extends beyond document boundary"),
            PatchError::LeftoverContent => write!(f, "document has unprocessed content after patch"),
        }
    }
}

impl std::error::Error for PatchError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_roundtrip_basic() {
        let old = "line 1\nline 2\nline 3\n";
        let new = "line 1\nmodified line 2\nline 3\nnew line 4\n";
        let ops = compute_patch(old, new);
        let result = apply_patch(old, &ops).unwrap();
        assert_eq!(result, new);
    }

    #[test]
    fn test_empty_to_content() {
        let ops = compute_patch("", "hello world\n");
        let result = apply_patch("", &ops).unwrap();
        assert_eq!(result, "hello world\n");
    }

    #[test]
    fn test_content_to_empty() {
        let ops = compute_patch("hello world\n", "");
        let result = apply_patch("hello world\n", &ops).unwrap();
        assert_eq!(result, "");
    }

    #[test]
    fn test_no_change() {
        let ops = compute_patch("same\n", "same\n");
        assert!(ops.is_empty());
        let result = apply_patch("same\n", &ops).unwrap();
        assert_eq!(result, "same\n");
    }

    #[test]
    fn test_insert_at_beginning() {
        let old = "existing\n";
        let new = "new first line\nexisting\n";
        let ops = compute_patch(old, new);
        let result = apply_patch(old, &ops).unwrap();
        assert_eq!(result, new);
    }

    #[test]
    fn test_delete_from_end() {
        let old = "keep\nremove\n";
        let new = "keep\n";
        let ops = compute_patch(old, new);
        let result = apply_patch(old, &ops).unwrap();
        assert_eq!(result, new);
    }

    #[test]
    fn test_multiline_change() {
        let old = "# Title\n\nParagraph one.\n\nParagraph two.\n";
        let new = "# New Title\n\nParagraph one.\n\nModified paragraph two.\n\nParagraph three.\n";
        let ops = compute_patch(old, new);
        let result = apply_patch(old, &ops).unwrap();
        assert_eq!(result, new);
    }

    #[test]
    fn test_mismatch_error() {
        let ops = vec![PatchOp {
            op: OpType::Equal,
            content: "wrong content".to_string(),
        }];
        let result = apply_patch("actual content", &ops);
        assert!(result.is_err());
    }

    #[test]
    fn test_serialization_roundtrip() {
        let ops = compute_patch("old\n", "new\n");
        let json = serde_json::to_string(&ops).unwrap();
        let deserialized: Vec<PatchOp> = serde_json::from_str(&json).unwrap();
        assert_eq!(ops, deserialized);
    }
}
