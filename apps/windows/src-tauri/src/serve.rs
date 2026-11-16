// --selftest only: serves the three mock career sites (App/Resources/SelfTest, the Mac's own pages) on 127.0.0.1.
// The pages are compiled in, so the server can't read any file: a request for anything else is a 404.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

const PAGES: [(&str, &str); 3] = [
    ("workday.html", include_str!("../../../../App/Resources/SelfTest/workday.html")),
    ("simple.html", include_str!("../../../../App/Resources/SelfTest/simple.html")),
    ("honeypot.html", include_str!("../../../../App/Resources/SelfTest/honeypot.html")),
];

/// The page for a request line's target ("/simple.html?x=1"), if it is one of the three.
pub fn page(target: &str) -> Option<&'static str> {
    let name = target.split(['?', '#']).next()?.strip_prefix('/')?;
    PAGES.iter().find(|(n, _)| *n == name).map(|(_, body)| *body)
}

/// Starts the server on a free port and returns its base URL.
pub fn start() -> std::io::Result<String> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let base = format!("http://{}", listener.local_addr()?);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() { std::thread::spawn(move || handle(stream)); }
    });
    Ok(base)
}

fn handle(mut s: TcpStream) {
    let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
    let mut buf = [0u8; 8192];
    let mut len = 0;
    while len < buf.len() {
        match s.read(&mut buf[len..]) {
            Ok(0) | Err(_) => break,
            Ok(n) => { len += n; if buf[..len].windows(4).any(|w| w == b"\r\n\r\n") { break; } }
        }
    }
    let head = String::from_utf8_lossy(&buf[..len]);
    let target = head.lines().next().and_then(|l| l.split(' ').nth(1)).unwrap_or("");
    let rsp = match page(target) {
        Some(body) => format!("HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}", body.len()),
        None => "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_string(),
    };
    let _ = s.write_all(rsp.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_three_pages() {
        assert!(page("/simple.html").unwrap().contains("<form"));
        assert!(page("/workday.html?step=2").is_some());
        for bad in ["/", "", "simple.html", "/../simple.html", "/SelfTest/simple.html", "/..%2Fsimple.html", "/Cargo.toml", "/simple.html/"] {
            assert!(page(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn serves_over_http() {
        let base = start().unwrap();
        let get = |path: &str| {
            let mut s = TcpStream::connect(base.trim_start_matches("http://")).unwrap();
            write!(s, "GET {path} HTTP/1.1\r\nhost: x\r\n\r\n").unwrap();
            let mut out = String::new();
            s.read_to_string(&mut out).unwrap();
            out
        };
        assert!(get("/honeypot.html").starts_with("HTTP/1.1 200"));
        assert!(get("/../../etc/passwd").starts_with("HTTP/1.1 404"));
    }
}
