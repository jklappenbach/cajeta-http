// cajeta-http bench competitor: axum 0.8 on hyper 1 / tokio (multi-thread).
// Modes: h1 (plaintext/json/ws/sse), h2c (prior knowledge, h1 also accepted), tls (rustls, ALPN http/1.1).
use std::{net::SocketAddr, sync::Arc};

use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    http::{HeaderValue, Uri, header},
    response::{IntoResponse, Response},
    routing::get,
};
use hyper_util::{
    rt::{TokioExecutor, TokioIo},
    server::conn::auto::Builder,
    service::TowerToHyperService,
};
use serde::Serialize;
use tokio::net::TcpListener;

#[derive(Serialize)]
struct Msg {
    message: &'static str,
}

async fn plaintext() -> Response {
    let mut r = Response::new(Body::from(Bytes::from_static(b"Hello, World!")));
    r.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    r
}

async fn json() -> impl IntoResponse {
    // axum::Json serializes with serde_json per request and sets exactly `application/json`.
    Json(Msg { message: "Hello, World!" })
}

async fn sse(uri: Uri) -> Response {
    let n: u64 = uri
        .query()
        .and_then(|q| {
            q.split('&')
                .find_map(|kv| kv.strip_prefix("n="))
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(1000);
    // One body chunk (= one write/flush) per 100 events.
    let stream = futures_util::stream::unfold(0u64, move |start| async move {
        if start >= n {
            return None;
        }
        let end = (start + 100).min(n);
        let mut buf = String::with_capacity(((end - start) * 12) as usize);
        for i in start..end {
            buf.push_str("data: ");
            buf.push_str(itoa(i).as_str());
            buf.push_str("\n\n");
        }
        Some((Ok::<_, std::convert::Infallible>(Bytes::from(buf)), end))
    });
    let mut r = Response::new(Body::from_stream(stream));
    let h = r.headers_mut();
    h.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
    h.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    r
}

fn itoa(i: u64) -> String {
    i.to_string()
}

async fn ws(up: WebSocketUpgrade) -> Response {
    // tokio-tungstenite has no permessage-deflate: the extension is declined (not echoed in the 101).
    up.max_message_size(64 << 20)
        .max_frame_size(64 << 20)
        .on_upgrade(echo)
}

async fn echo(mut sock: WebSocket) {
    while let Some(Ok(msg)) = sock.recv().await {
        match msg {
            Message::Text(_) | Message::Binary(_) => {
                if sock.send(msg).await.is_err() {
                    return;
                }
            }
            // Ping/Pong/Close are handled by tungstenite: the pong / close reply is flushed on the next
            // recv(), which then yields None once the closing handshake is done.
            _ => {}
        }
    }
}

fn usage() -> ! {
    eprintln!("usage: server <h1|h2c|tls> <port> [<cert.pem> <key.pem>]");
    std::process::exit(2);
}

fn tls_acceptor(cert: &str, key: &str) -> tokio_rustls::TlsAcceptor {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_file_iter(cert)
        .unwrap_or_else(|e| panic!("cert {cert}: {e}"))
        .collect::<Result<_, _>>()
        .unwrap_or_else(|e| panic!("cert {cert}: {e}"));
    let key = PrivateKeyDer::from_pem_file(key).unwrap_or_else(|e| panic!("key {key}: {e}"));
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let mut cfg = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])
        .expect("tls versions")
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .expect("cert/key");
    cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
    tokio_rustls::TlsAcceptor::from(Arc::new(cfg))
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        usage();
    }
    let mode = args[1].as_str();
    let port: u16 = args[2].parse().unwrap_or_else(|_| usage());
    let tls = match mode {
        "h1" | "h2c" => None,
        "tls" => {
            if args.len() < 5 {
                usage();
            }
            Some(tls_acceptor(&args[3], &args[4]))
        }
        _ => usage(),
    };

    let mut app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json));
    if mode == "h1" {
        app = app.route("/ws", get(ws)).route("/sse", get(sse));
    }

    let mut builder = Builder::new(TokioExecutor::new());
    match mode {
        "h1" | "tls" => {
            builder = builder.http1_only();
        }
        _ => {
            // Serves both HTTP/1.1 and h2 prior knowledge on the same port.
            builder.http2().max_concurrent_streams(250);
        }
    }
    builder.http1().auto_date_header(false);
    let builder = Arc::new(builder);

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let listener = TcpListener::bind(addr).await.expect("bind");
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(s) => s,
            Err(_) => continue,
        };
        let _ = stream.set_nodelay(true);
        let svc = TowerToHyperService::new(app.clone());
        let builder = builder.clone();
        let tls = tls.clone();
        tokio::spawn(async move {
            match tls {
                None => {
                    let _ = builder
                        .serve_connection_with_upgrades(TokioIo::new(stream), svc)
                        .await;
                }
                Some(acc) => {
                    if let Ok(s) = acc.accept(stream).await {
                        let _ = builder.serve_connection(TokioIo::new(s), svc).await;
                    }
                }
            }
        });
    }
}
