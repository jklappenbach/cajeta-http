// cajeta-http bench competitor client: reqwest 0.13 (HTTP/1.1) on tokio multi-thread.
// usage: client get <url> <total> <conns> <keepalive>
use std::time::Instant;

const EXPECT: &[u8] = b"Hello, World!";

fn usage() -> ! {
    eprintln!("usage: client get <url> <total> <conns> <keepalive 0|1>");
    std::process::exit(2);
}

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 6 || a[1] != "get" {
        usage();
    }
    let url: reqwest::Url = a[2].parse().unwrap_or_else(|_| usage());
    let total: u64 = a[3].parse().unwrap_or_else(|_| usage());
    let conns: u64 = a[4].parse().unwrap_or_else(|_| usage());
    let keepalive = match a[5].as_str() {
        "1" => true,
        "0" => false,
        _ => usage(),
    };
    if conns == 0 {
        usage();
    }

    let mut b = reqwest::Client::builder()
        .http1_only()
        .no_proxy()
        .tcp_nodelay(true);
    b = if keepalive {
        b.pool_max_idle_per_host(conns as usize)
    } else {
        // No pooling: every request dials a fresh connection; also ask the server to close.
        b.pool_max_idle_per_host(0)
    };
    let client = b.build().unwrap_or_else(|e| {
        eprintln!("client build: {e}");
        std::process::exit(2)
    });

    let start = Instant::now();
    let mut tasks = Vec::with_capacity(conns as usize);
    for w in 0..conns {
        let n = total / conns + u64::from(w < total % conns);
        let client = client.clone();
        let url = url.clone();
        tasks.push(tokio::spawn(async move {
            let (mut done, mut err) = (0u64, 0u64);
            for _ in 0..n {
                let mut req = client.get(url.clone());
                if !keepalive {
                    req = req.header(reqwest::header::CONNECTION, "close");
                }
                let good = match req.send().await {
                    Ok(r) => {
                        let status = r.status();
                        match r.bytes().await {
                            Ok(body) => {
                                done += 1;
                                status == 200 && body.as_ref() == EXPECT
                            }
                            Err(_) => false,
                        }
                    }
                    Err(_) => false,
                };
                if !good {
                    err += 1;
                }
            }
            (done, err)
        }));
    }
    let (mut done, mut err) = (0u64, 0u64);
    for t in tasks {
        match t.await {
            Ok((d, e)) => {
                done += d;
                err += e;
            }
            Err(_) => err += 1,
        }
    }
    let elapsed = start.elapsed().as_nanos();
    // requests = responses fully received (any status); errors = anything not 200 + exact body, incl. transport errors.
    println!("{{\"requests\":{},\"errors\":{},\"elapsed_ns\":{}}}", done, err, elapsed);
}
