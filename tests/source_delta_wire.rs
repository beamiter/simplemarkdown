use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

struct Peer {
    child: Child,
    input: ChildStdin,
    output: Receiver<Value>,
}

impl Peer {
    fn new() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_simplemarkdown-daemon"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines().map_while(Result::ok) {
                if tx.send(serde_json::from_str(&line).unwrap()).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            input,
            output: rx,
        }
    }

    fn send(&mut self, request: &Value) {
        writeln!(self.input, "{request}").unwrap();
        self.input.flush().unwrap();
    }

    fn request(&mut self, request: Value) -> Value {
        let id = request["id"].clone();
        self.send(&request);
        let reply = self.output.recv_timeout(Duration::from_secs(30)).unwrap();
        assert_eq!(reply["id"], id, "unexpected reply: {reply}");
        reply
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn fixture() -> Vec<String> {
    let mut lines = vec!["# Fixture heading".to_owned()];
    for _ in 0..300 {
        lines.push(String::new());
        lines.push("unchanged concrete fixture text with UTF-8 界".repeat(4));
    }
    lines
}

#[test]
fn exact_source_splice_renders_identical_rows_and_indexes_and_misses_do_not_mutate() {
    let mut peer = Peer::new();
    let hello = peer.request(json!({"type":"ping","id":1}));
    assert_eq!(hello["protocol_version"], 4);
    assert_eq!(hello["capabilities"]["render_source_delta"], true);
    let mut new_source = fixture();
    let full = json!({"type":"render","id":2,"session":"view-a","lines":new_source,
        "width":54,"remember_source":true});
    let first = peer.request(full.clone());
    assert_eq!(first["type"], "render_result");
    assert_eq!(first["source_rev"], 2);

    let delta = json!({"type":"render_delta","id":5,"session":"view-a","width":54,
        "base":2,"from":300,"del":1,"insert":["replacement é"],"incremental":false});
    assert!(delta.to_string().len() * 100 < full.to_string().len());
    let mut wrong_scope = delta.clone();
    wrong_scope["session"] = "view-b".into();
    wrong_scope["id"] = 3.into();
    assert_eq!(peer.request(wrong_scope)["type"], "render_source_missing");

    let mut wrong_range = delta.clone();
    wrong_range["id"] = 4.into();
    wrong_range["from"] = 1_000_000.into();
    assert_eq!(peer.request(wrong_range)["type"], "render_source_missing");

    let patched = peer.request(delta.clone());
    assert_eq!(patched["type"], "render_result");
    assert_eq!(patched["source_rev"], 5);
    new_source[300] = "replacement é".into();
    let expected = peer.request(json!({"type":"render","id":6,"lines":new_source,"width":54}));
    assert_eq!(expected["type"], "render_result");
    assert!(
        expected.get("source_rev").is_none(),
        "legacy full reply stays unchanged"
    );
    for field in ["lines", "total", "src_sum", "toc", "links", "blocks"] {
        assert_eq!(patched[field], expected[field], "{field} differed");
    }

    peer.send(&json!({"type":"forget","session":"view-a"}));
    let mut retired = delta;
    retired["id"] = 7.into();
    retired["base"] = 5.into();
    assert_eq!(peer.request(retired)["type"], "render_source_missing");
}
