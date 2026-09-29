//! Attach sessions (PROTOCOL §8, PLAN T0.6): replay, then live output, input, resize and
//! keepalive in binary frames. More than one client may attach to a tab.

use mapo_protocol::frames::{Frame, FrameDecoder, encode_data};
use mapo_protocol::hello::AttachResult;
use mapo_protocol::rpc::Response;
use mapo_term::render::ReplayStrategy;
use mapo_term::tab::TabHandle;
use tokio::io::{AsyncReadExt, BufReader};
use tokio::net::unix::OwnedReadHalf;
use tokio::sync::broadcast::error::RecvError;

use super::Shared;
use super::conn::{AttachStart, Session, Tx, encode, live_tab};

fn send_replay(tx: &Tx, replay: &[u8]) -> bool {
    let mut out = Frame::ReplayBegin.encode();
    encode_data(false, replay, &mut out);
    Frame::ReplayEnd.encode_into(&mut out);
    tx.send(out).is_ok()
}

pub async fn run(
    shared: &Shared,
    session: &Session,
    start: AttachStart,
    reader: &mut BufReader<OwnedReadHalf>,
    tx: &Tx,
) {
    let p = &start.params;
    let (summary, handle) =
        match live_tab(shared, session, Some(p.tab.clone()), p.workspace.clone()).await {
            Ok(t) => t,
            Err(e) => {
                let _ = tx.send(encode(&Response::err(Some(start.id), e)));
                return;
            }
        };
    let strategy = ReplayStrategy::from_env();
    let begun = std::time::Instant::now();
    if strategy == ReplayStrategy::Grid {
        handle.resize(p.cols, p.rows, p.width_px, p.height_px).await;
    }
    let (replay, mut live) = handle.attach(strategy);
    let mut result = start.result;
    result.attach = Some(AttachResult {
        tab_id: summary.id.clone(),
        replay_bytes: replay.len() as u64,
    });
    let _ = tx.send(encode(&Response::ok(
        start.id,
        serde_json::to_value(&result).unwrap_or_default(),
    )));
    if !send_replay(tx, &replay) {
        handle.detach();
        return;
    }
    if strategy == ReplayStrategy::Raw {
        handle.resize(p.cols, p.rows, p.width_px, p.height_px).await;
    }
    let ms = begun.elapsed().as_millis() as u64;
    shared
        .last_attach_ms
        .store(ms.max(1), std::sync::atomic::Ordering::Relaxed);
    tracing::info!(tab = %summary.id, replay_bytes = replay.len(), ms, "attached");
    serve(shared, &handle, reader, tx, &mut live, strategy).await;
    handle.detach();
    tracing::info!(tab = %summary.id, "detached");
}

async fn serve(
    shared: &Shared,
    handle: &TabHandle,
    reader: &mut BufReader<OwnedReadHalf>,
    tx: &Tx,
    live: &mut tokio::sync::broadcast::Receiver<std::sync::Arc<[u8]>>,
    strategy: ReplayStrategy,
) {
    let mut decoder = FrameDecoder::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut stop = shared.shutdown.subscribe();
    let exit = handle.wait_exit();
    tokio::pin!(exit);
    loop {
        tokio::select! {
            out = live.recv() => match out {
                Ok(bytes) => {
                    let mut frames = Vec::with_capacity(bytes.len() + 5);
                    encode_data(false, &bytes, &mut frames);
                    if tx.send(frames).is_err() {
                        return;
                    }
                }
                Err(RecvError::Lagged(_)) => {
                    // Never drop bytes silently: resync the client with a fresh replay.
                    let (replay, rx) = handle.resync(strategy);
                    *live = rx;
                    if !send_replay(tx, &replay) {
                        return;
                    }
                }
                Err(RecvError::Closed) => return,
            },
            n = reader.read(&mut buf) => {
                let n = match n {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                decoder.push(&buf[..n]);
                loop {
                    match decoder.next_frame() {
                        Ok(Some(Frame::In(bytes))) => {
                            handle.write(&bytes).await;
                        }
                        Ok(Some(Frame::Resize { cols, rows, width_px, height_px })) => {
                            handle.resize(cols, rows, width_px, height_px).await;
                        }
                        Ok(Some(Frame::Ping)) => {
                            let _ = tx.send(Frame::Pong.encode());
                        }
                        Ok(Some(Frame::Detach)) => return,
                        Ok(Some(_)) => {}
                        Ok(None) => break,
                        Err(e) => {
                            tracing::warn!(error = %e, "bad attach frame");
                            return;
                        }
                    }
                }
            }
            code = &mut exit => {
                // Flush what the shell printed before it exited, then report the exit.
                while let Ok(bytes) = live.try_recv() {
                    let mut frames = Vec::new();
                    encode_data(false, &bytes, &mut frames);
                    let _ = tx.send(frames);
                }
                let _ = tx.send(Frame::Exit(code).encode());
                return;
            }
            _ = stop.changed() => {
                let _ = tx.send(Frame::Detach.encode());
                return;
            }
        }
    }
}
