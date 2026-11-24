//! Bounded, exact-revision input caching. Rendering still parses the whole
//! reconstructed document and uses the normal preview and source-map logic.

pub(super) const CACHE_ENTRIES: usize = 4;
const MAX_LINES: usize = 32_768;
const MAX_BYTES: usize = 2 * 1024 * 1024;
const MAX_INSERT_LINES: usize = 256;
const MAX_INSERT_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub(super) struct Snapshot {
    revision: u64,
    lines: Vec<String>,
    bytes: usize,
}

fn bounded_bytes(lines: &[String], max_lines: usize, max_bytes: usize) -> Option<usize> {
    if lines.len() > max_lines {
        return None;
    }
    let mut bytes = 0usize;
    for line in lines {
        bytes = bytes.checked_add(line.len())?.checked_add(1)?;
        if bytes > max_bytes {
            return None;
        }
    }
    Some(bytes)
}

impl Snapshot {
    pub(super) fn retain(revision: u64, lines: Vec<String>) -> Option<Self> {
        let bytes = bounded_bytes(&lines, MAX_LINES, MAX_BYTES)?;
        (revision != 0).then_some(Self {
            revision,
            lines,
            bytes,
        })
    }

    pub(super) fn revision(&self) -> u64 {
        self.revision
    }

    pub(super) fn lines(&self) -> &[String] {
        &self.lines
    }

    pub(super) fn splice(
        &self,
        revision: u64,
        base: u64,
        from: usize,
        del: usize,
        insert: Vec<String>,
    ) -> Option<Self> {
        if base != self.revision || revision <= base {
            return None;
        }
        let end = from.checked_add(del)?;
        let old = self.lines.get(from..end)?;
        let bytes_added = bounded_bytes(&insert, MAX_INSERT_LINES, MAX_INSERT_BYTES)?;
        let bytes_removed = bounded_bytes(old, MAX_LINES, MAX_BYTES)?;
        let len = self
            .lines
            .len()
            .checked_sub(del)?
            .checked_add(insert.len())?;
        let bytes = self
            .bytes
            .checked_sub(bytes_removed)?
            .checked_add(bytes_added)?;
        if len > MAX_LINES || bytes > MAX_BYTES {
            return None;
        }
        let mut lines = Vec::with_capacity(len);
        lines.extend_from_slice(&self.lines[..from]);
        lines.extend(insert);
        lines.extend_from_slice(&self.lines[end..]);
        Some(Self {
            revision,
            lines,
            bytes,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconstructs_one_line_exactly_without_mutating_its_base() {
        let before = vec!["# exact title".into(), "old 界".into(), "z".into()];
        let retained = Snapshot::retain(7, before.clone()).unwrap();
        let expected = vec!["# exact title".into(), "é replaced".into(), "z".into()];
        let rebuilt = retained
            .splice(8, 7, 1, 1, vec!["é replaced".into()])
            .unwrap();
        let whole = Snapshot::retain(8, expected).unwrap();
        assert_eq!(rebuilt.lines(), whole.lines());
        assert_eq!(rebuilt.lines().join("\n"), whole.lines().join("\n"));
        assert_eq!(retained.lines(), before);
        assert_eq!(rebuilt.revision(), 8);
        assert_eq!(CACHE_ENTRIES, 4);
    }

    #[test]
    fn bad_revision_range_and_splice_budget_do_not_poison_the_base() {
        let retained = Snapshot::retain(7, vec!["x".into()]).unwrap();
        for (id, base, from, del, insert) in [
            (8, 6, 0, 1, vec![]),
            (7, 7, 0, 1, vec![]),
            (6, 7, 0, 1, vec![]),
            (8, 7, 2, 0, vec![]),
            (8, 7, 0, 2, vec![]),
            (8, 7, usize::MAX, 1, vec![]),
            (8, 7, 0, 1, vec![String::new(); MAX_INSERT_LINES + 1]),
            (8, 7, 0, 1, vec!["x".repeat(MAX_INSERT_BYTES)]),
        ] {
            assert!(retained.splice(id, base, from, del, insert).is_none());
        }
        assert_eq!(retained.lines(), &["x"]);
        assert!(retained.splice(8, 7, 1, 0, vec!["y".into()]).is_some());
    }

    #[test]
    fn even_small_splices_may_not_grow_a_snapshot_past_the_total_cap() {
        let retained = Snapshot::retain(1, vec!["a".repeat(MAX_BYTES - 1)]).unwrap();
        assert!(retained.splice(2, 1, 1, 0, vec!["z".into()]).is_none());
        assert!(Snapshot::retain(1, vec!["a".repeat(MAX_BYTES)]).is_none());
        let retained = Snapshot::retain(1, vec![String::new(); MAX_LINES]).unwrap();
        assert!(retained.splice(2, 1, 0, 0, vec![String::new()]).is_none());
        assert!(Snapshot::retain(0, vec![]).is_none());
    }

    #[test]
    fn inserts_at_start_and_end_and_handles_pure_removal() {
        let s = Snapshot::retain(1, vec!["middle".into()]).unwrap();
        let s = s.splice(2, 1, 0, 0, vec!["first".into()]).unwrap();
        let s = s.splice(3, 2, 2, 0, vec!["last".into()]).unwrap();
        let s = s.splice(4, 3, 1, 1, vec![]).unwrap();
        assert_eq!(s.lines(), &["first", "last"]);
        let s = s.splice(5, 4, 2, 0, vec![]).unwrap();
        assert_eq!(s.lines(), &["first", "last"]);
    }
}
