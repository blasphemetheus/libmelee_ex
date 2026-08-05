//! melee_enet NIF
//!
//! Rustler NIF wrapping `rusty_enet` (a pure-Rust ENet 1.3 port) for the
//! `Melee.Transport.EnetNif` transport. Dolphin's Slippi spectator server
//! speaks ENet on localhost; we act as a client with a single channel and
//! reliable packets (including fragment reassembly for > MTU payloads).
//!
//! The resource wraps an ENet `Host` (client or listening server — the
//! listen variant exists for loopback tests and future EnetBeam
//! cross-compat tests). All host access is serialized through a Mutex;
//! `host_service` releases the lock between poll iterations so sends and
//! destroys from other processes can interleave with a blocked service
//! call.

use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use rustler::{Binary, Encoder, Env, OwnedBinary, Resource, ResourceArc, Term};
use rusty_enet::{Event, Host, HostSettings, Packet};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        connected,
        disconnected,
        packet,
        remote,
        closed,
        not_connected,
        send_failed,
        lock_poisoned,
        invalid_address,
        io_error,
        no_available_peers,
        host_init_failed,
    }
}

/// NIF resource: an ENet host (client or server), or `None` once destroyed.
pub struct HostRes(Mutex<Option<Host<UdpSocket>>>);

#[rustler::resource_impl]
impl Resource for HostRes {}

/// Owned copy of a rusty_enet event (the crate's `Event` borrows the host).
enum Ev {
    Connected,
    Disconnected(u32),
    Packet(u8, Vec<u8>),
}

fn convert(ev: Event<'_, UdpSocket>) -> Ev {
    match ev {
        Event::Connect { .. } => Ev::Connected,
        Event::Disconnect { data, .. } => Ev::Disconnected(data),
        Event::Receive {
            channel_id, packet, ..
        } => Ev::Packet(channel_id, packet.data().to_vec()),
    }
}

fn encode_ev<'a>(env: Env<'a>, ev: &Ev) -> Term<'a> {
    match ev {
        Ev::Connected => atoms::connected().encode(env),
        // rusty_enet folds remote disconnects and timeouts into one
        // Disconnect event; we report both as :remote.
        Ev::Disconnected(_data) => (atoms::disconnected(), atoms::remote()).encode(env),
        Ev::Packet(channel, data) => {
            let mut bin = OwnedBinary::new(data.len()).expect("binary alloc failed");
            bin.as_mut_slice().copy_from_slice(data);
            (atoms::packet(), channel, Binary::from_owned(bin, env)).encode(env)
        }
    }
}

fn err<'a>(env: Env<'a>, reason: Term<'a>) -> Term<'a> {
    (atoms::error(), reason).encode(env)
}

fn make_host(socket: UdpSocket, peer_limit: usize) -> Result<Host<UdpSocket>, rustler::Atom> {
    socket
        .set_nonblocking(true)
        .map_err(|_| atoms::io_error())?;
    Host::new(
        socket,
        HostSettings {
            peer_limit,
            channel_limit: 1,
            ..Default::default()
        },
    )
    .map_err(|_| atoms::host_init_failed())
}

/// host_connect(address, port) -> {:ok, resource} | {:error, reason}
///
/// Creates a nonblocking UDP socket bound to an ephemeral port, builds a
/// 1-channel client host and initiates the ENet connect handshake to
/// `address:port`. Completion is observed via `host_service/2` events.
#[rustler::nif]
fn host_connect<'a>(env: Env<'a>, address: String, port: u16) -> Term<'a> {
    let resolved: Vec<SocketAddr> = match (address.as_str(), port).to_socket_addrs() {
        Ok(addrs) => addrs.collect(),
        Err(_) => return err(env, atoms::invalid_address().encode(env)),
    };
    let remote: SocketAddr = match resolved
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| resolved.first())
    {
        Some(addr) => *addr,
        None => return err(env, atoms::invalid_address().encode(env)),
    };

    let bind_addr = if remote.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
    let socket = match UdpSocket::bind(bind_addr) {
        Ok(s) => s,
        Err(_) => return err(env, atoms::io_error().encode(env)),
    };

    let mut host = match make_host(socket, 1) {
        Ok(h) => h,
        Err(reason) => return err(env, reason.encode(env)),
    };

    if host.connect(remote, 1, 0).is_err() {
        return err(env, atoms::no_available_peers().encode(env));
    }

    (
        atoms::ok(),
        ResourceArc::new(HostRes(Mutex::new(Some(host)))),
    )
        .encode(env)
}

/// host_listen(port) -> {:ok, resource} | {:error, reason}
///
/// Test-support server host bound to 127.0.0.1:`port` (0 for an ephemeral
/// port — read it back with `host_port/1`). Accepts incoming ENet peers on
/// one channel; used by loopback tests and future EnetBeam cross-compat
/// tests.
#[rustler::nif]
fn host_listen<'a>(env: Env<'a>, port: u16) -> Term<'a> {
    let socket = match UdpSocket::bind(("127.0.0.1", port)) {
        Ok(s) => s,
        Err(_) => return err(env, atoms::io_error().encode(env)),
    };

    match make_host(socket, 16) {
        Ok(host) => (
            atoms::ok(),
            ResourceArc::new(HostRes(Mutex::new(Some(host)))),
        )
            .encode(env),
        Err(reason) => err(env, reason.encode(env)),
    }
}

/// host_port(resource) -> {:ok, port} | {:error, reason}
///
/// The local UDP port the host's socket is bound to (test support for
/// ephemeral `host_listen(0)`).
#[rustler::nif]
fn host_port<'a>(env: Env<'a>, res: ResourceArc<HostRes>) -> Term<'a> {
    let guard = match res.0.lock() {
        Ok(g) => g,
        Err(_) => return err(env, atoms::lock_poisoned().encode(env)),
    };
    match guard.as_ref() {
        None => err(env, atoms::closed().encode(env)),
        Some(host) => match host.socket().local_addr() {
            Ok(addr) => (atoms::ok(), addr.port()).encode(env),
            Err(_) => err(env, atoms::io_error().encode(env)),
        },
    }
}

/// host_service(resource, timeout_ms) -> {:ok, [event]} | {:error, reason}
///
/// Polls the host, draining all currently-available events. Returns as
/// soon as at least one event is available, or after `timeout_ms` elapses
/// with an empty list. Events:
///   :connected | {:disconnected, reason} | {:packet, channel, binary}
///
/// Dirty IO NIF — it blocks (1 ms poll loop), releasing the host lock
/// between iterations so concurrent sends/destroys are not starved.
#[rustler::nif(schedule = "DirtyIo")]
fn host_service<'a>(env: Env<'a>, res: ResourceArc<HostRes>, timeout_ms: u64) -> Term<'a> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut events: Vec<Ev> = Vec::new();

    loop {
        {
            let mut guard = match res.0.lock() {
                Ok(g) => g,
                Err(_) => return err(env, atoms::lock_poisoned().encode(env)),
            };
            let host = match guard.as_mut() {
                Some(h) => h,
                None => return err(env, atoms::closed().encode(env)),
            };
            loop {
                match host.service() {
                    Ok(Some(ev)) => events.push(convert(ev)),
                    Ok(None) => break,
                    Err(_) => return err(env, atoms::io_error().encode(env)),
                }
            }
        }

        if !events.is_empty() || Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(Duration::from_millis(1));
    }

    let terms: Vec<Term<'a>> = events.iter().map(|ev| encode_ev(env, ev)).collect();
    (atoms::ok(), terms).encode(env)
}

/// peer_send(resource, channel, data) -> :ok | {:error, reason}
///
/// Reliable send to the first connected peer (the sole peer for a client
/// host; the accepted peer for a test server host), followed by an
/// immediate flush so the packet hits the wire without waiting for the
/// next service call.
#[rustler::nif]
fn peer_send<'a>(env: Env<'a>, res: ResourceArc<HostRes>, channel: u8, data: Binary<'a>) -> Term<'a> {
    let mut guard = match res.0.lock() {
        Ok(g) => g,
        Err(_) => return err(env, atoms::lock_poisoned().encode(env)),
    };
    let host = match guard.as_mut() {
        Some(h) => h,
        None => return err(env, atoms::closed().encode(env)),
    };

    let packet = Packet::reliable(data.as_slice());
    let result = match host.connected_peers_mut().next() {
        None => Err(atoms::not_connected()),
        Some(peer) => peer.send(channel, &packet).map_err(|_| atoms::send_failed()),
    };

    match result {
        Ok(()) => {
            host.flush();
            atoms::ok().encode(env)
        }
        Err(reason) => err(env, reason.encode(env)),
    }
}

/// host_destroy(resource) -> :ok
///
/// Immediately disconnects any connected peers (notifying the remote
/// side), flushes, and drops the host, closing its socket. Idempotent.
#[rustler::nif]
fn host_destroy<'a>(env: Env<'a>, res: ResourceArc<HostRes>) -> Term<'a> {
    let mut guard = match res.0.lock() {
        Ok(g) => g,
        Err(_) => return atoms::ok().encode(env),
    };
    if let Some(mut host) = guard.take() {
        for peer in host.connected_peers_mut() {
            peer.disconnect_now(0);
        }
        host.flush();
    }
    atoms::ok().encode(env)
}

rustler::init!("Elixir.Melee.Transport.EnetNif.Native");
