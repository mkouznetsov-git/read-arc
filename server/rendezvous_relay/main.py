from __future__ import annotations

import asyncio
import json
import os
import secrets
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, DefaultDict, Dict, List

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect, status
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.websockets import WebSocketState

from relay_store import RelayStore

app = FastAPI(title="ReadArc Rendezvous Relay", version="0.4.0")

# The relay never stores books or decrypted metadata. It keeps online websocket
# rooms in RAM, caches the latest encrypted metadata snapshot in RAM, and since
# Sprint 27 persists a bounded offline queue of encrypted metadata envelopes.
_rooms: DefaultDict[str, Dict[WebSocket, str]] = defaultdict(dict)
_snapshot_cache: DefaultDict[str, Dict[str, str]] = defaultdict(dict)
_pairing_codes: Dict[str, dict] = {}

# Sprint 27: durable offline queue for encrypted metadata events.
# The relay stores only already encrypted envelopes and never sees plaintext
# library data. Binary file chunks are never persisted here.
_lock = asyncio.Lock()
MAX_MESSAGE_BYTES = 1024 * 1024 * 16  # text metadata/control frames
MAX_BINARY_MESSAGE_BYTES = 1024 * 1024 * 4  # encrypted binary file chunks
MAX_CACHED_SNAPSHOT_BYTES = 1024 * 1024  # metadata only; book chunks are never cached.
MAX_OFFLINE_EVENT_BYTES = MAX_CACHED_SNAPSHOT_BYTES
MAX_OFFLINE_EVENTS_PER_ACCOUNT = 1000
OFFLINE_QUEUE_TTL_SECONDS = int(os.environ.get("READARC_OFFLINE_QUEUE_TTL_SECONDS", str(30 * 24 * 60 * 60)))
READARC_RELAY_DATA_DIR = Path(os.environ.get("READARC_RELAY_DATA_DIR", "/data"))
OFFLINE_QUEUE_STORE = READARC_RELAY_DATA_DIR / "offline_queue.sqlite3"
PAIRING_TTL_SECONDS = 5 * 60
QUEUEABLE_METADATA_TYPES = {
    "library_snapshot",
}
MIN_PROTOCOL_VERSION = 2
CURRENT_PROTOCOL_VERSION = 3
_relay_store = RelayStore(
    OFFLINE_QUEUE_STORE,
    max_events=MAX_OFFLINE_EVENTS_PER_ACCOUNT,
    ttl_seconds=OFFLINE_QUEUE_TTL_SECONDS,
)


@app.on_event("startup")
async def _startup() -> None:
    _relay_store.initialize()


@app.get("/")
async def root() -> JSONResponse:
    return JSONResponse({
        "ok": True,
        "service": "ReadArc Rendezvous Relay",
        "version": app.version,
        "websocket": "/ws/{account_id}/{device_id}",
    })


@app.get("/health")
async def health() -> PlainTextResponse:
    # Public liveness probe: intentionally short and data-free.  The previous
    # endpoint exposed room/account/device counters, which is unnecessary for a
    # health check and noisy for curl/users.
    await _cleanup_expired_pairing_codes()
    return PlainTextResponse("ok\n", headers={"Cache-Control": "no-store"})


@app.get("/debug/state")
async def debug_state(request: Request) -> JSONResponse:
    token = os.environ.get("READARC_RELAY_DEBUG_TOKEN", "").strip()
    supplied = request.headers.get("X-ReadArc-Debug-Token", "").strip()
    if not token or not secrets.compare_digest(token, supplied):
        return JSONResponse({"ok": False, "message": "not found"}, status_code=404)
    await _cleanup_expired_pairing_codes()
    async with _lock:
        store_stats = _relay_store.account_stats()
        rooms = {
            account_id: {
                "devices": sorted(device_ids.values()),
                "cached_snapshots": len(_snapshot_cache.get(account_id, {})),
                "offline_queue_events": store_stats.get(account_id, {}).get("events", 0),
                "offline_queue_next_seq": store_stats.get(account_id, {}).get("next_seq", 0),
            }
            for account_id, device_ids in _rooms.items()
        }
        for account_id, stats in store_stats.items():
            rooms.setdefault(account_id, {
                "devices": [],
                "cached_snapshots": len(_snapshot_cache.get(account_id, {})),
                "offline_queue_events": stats["events"],
                "offline_queue_next_seq": stats["next_seq"],
            })
        active_pairing_codes = len(_pairing_codes)
    return JSONResponse({"ok": True, "rooms": rooms, "pairing_codes": active_pairing_codes})


@app.post("/pairing/start")
async def start_pairing(request: Request) -> JSONResponse:
    payload = await request.json()
    account_id = str(payload.get("accountId") or "").strip()
    owner_device_id = str(payload.get("ownerDeviceId") or "").strip()
    owner_device_name = str(payload.get("ownerDeviceName") or "Устройство").strip()
    owner_device_public_key = str(payload.get("ownerDevicePublicKey") or "").strip()
    account_encryption_key = str(payload.get("accountEncryptionKey") or "").strip()
    relay_url = str(payload.get("relayUrl") or "").strip()
    request_id = str(payload.get("requestId") or "").strip()[:128]
    try:
        expires_seconds = int(payload.get("expiresSeconds") or PAIRING_TTL_SECONDS)
    except (TypeError, ValueError):
        expires_seconds = PAIRING_TTL_SECONDS
    expires_seconds = max(30, min(expires_seconds, PAIRING_TTL_SECONDS))

    if not account_id or not owner_device_id or not relay_url:
        return JSONResponse(
            {"ok": False, "message": "accountId, ownerDeviceId and relayUrl are required"},
            status_code=400,
        )

    now = time.time()
    async with _lock:
        expired = [code for code, record in _pairing_codes.items() if record.get("expiresAt", 0) < now]
        for expired_code in expired:
            _pairing_codes.pop(expired_code, None)

        # A mobile network can deliver the request but lose the response. A
        # retry with the same non-secret request id must return the same invite
        # instead of leaving an unknown live code and partial pairing state.
        if request_id:
            for existing_code, record in _pairing_codes.items():
                if (
                    record.get("requestId") == request_id
                    and record.get("accountId") == account_id
                    and record.get("ownerDeviceId") == owner_device_id
                ):
                    return JSONResponse({
                        "ok": True,
                        "code": existing_code,
                        "expiresAt": record["expiresAt"],
                        "expiresInSeconds": max(0, int(record["expiresAt"] - now)),
                        "relayUrl": record["relayUrl"],
                    })

        code = ""
        for _ in range(20):
            candidate = f"{secrets.randbelow(1_000_000):06d}"
            if candidate not in _pairing_codes:
                code = candidate
                break
        if not code:
            return JSONResponse({"ok": False, "message": "Pairing capacity is temporarily unavailable"}, status_code=503)

        expires_at = now + expires_seconds
        _pairing_codes[code] = {
            "accountId": account_id,
            "ownerDeviceId": owner_device_id,
            "ownerDeviceName": owner_device_name or "Устройство",
            "ownerDevicePublicKey": owner_device_public_key,
            "accountEncryptionKey": account_encryption_key,
            "relayUrl": relay_url,
            "createdAt": now,
            "expiresAt": expires_at,
            "claimedBy": None,
            "requestId": request_id,
        }

    return JSONResponse({
        "ok": True,
        "code": code,
        "expiresAt": expires_at,
        "expiresInSeconds": expires_seconds,
        "relayUrl": relay_url,
    })


@app.post("/pairing/claim")
async def claim_pairing(request: Request) -> JSONResponse:
    await _cleanup_expired_pairing_codes()
    payload = await request.json()
    code = _normalize_pairing_code(str(payload.get("code") or ""))
    new_device_id = str(payload.get("deviceId") or "").strip()
    new_device_name = str(payload.get("deviceName") or "Устройство").strip()
    new_device_public_key = str(payload.get("devicePublicKey") or "").strip()
    if not code or not new_device_id:
        return JSONResponse({"ok": False, "message": "code and deviceId are required"}, status_code=400)

    async with _lock:
        record = _pairing_codes.pop(code, None)
    if record is None:
        return JSONResponse({"ok": False, "message": "Pairing code is invalid or expired"}, status_code=404)
    if record["expiresAt"] < time.time():
        return JSONResponse({"ok": False, "message": "Pairing code expired"}, status_code=410)

    await _broadcast_system(record["accountId"], {
        "type": "pairing_claimed",
        "accountId": record["accountId"],
        "deviceId": "relay",
        "ownerDeviceId": record["ownerDeviceId"],
        "acceptedDeviceId": new_device_id,
        "acceptedDeviceName": new_device_name or "Устройство",
        "acceptedDevicePublicKey": new_device_public_key,
    })

    return JSONResponse({
        "ok": True,
        "accountId": record["accountId"],
        "relayUrl": record["relayUrl"],
        "ownerDeviceId": record["ownerDeviceId"],
        "ownerDeviceName": record["ownerDeviceName"],
        "ownerDevicePublicKey": record.get("ownerDevicePublicKey", ""),
        "accountEncryptionKey": record.get("accountEncryptionKey", ""),
        "acceptedDeviceId": new_device_id,
        "acceptedDevicePublicKey": new_device_public_key,
        "acceptedDeviceName": new_device_name or "Устройство",
    })


@app.websocket("/ws/{account_id}/{device_id}")
async def websocket_endpoint(websocket: WebSocket, account_id: str, device_id: str) -> None:
    await websocket.accept()
    async with _lock:
        _rooms[account_id][websocket] = device_id
        peer_ids = sorted(set(_rooms[account_id].values()) - {device_id})
        cached_messages = [
            raw
            for owner_device_id, raw in _snapshot_cache.get(account_id, {}).items()
            if owner_device_id != device_id
        ]
        queued_messages = _offline_queue_messages_for_device_locked(account_id, device_id)

    # First replay durable encrypted metadata events that arrived while this
    # device was offline. Clients ack relayQueueSeq after successful processing.
    for raw in queued_messages:
        await _send_text_safely(websocket, raw)

    # Tell the newcomer who is already online. The previous relay only notified
    # existing peers, so the newly joined device had to rely on its own outbound
    # request being delivered immediately after connect.
    await websocket.send_json({
        "type": "peer_list",
        "accountId": account_id,
        "deviceId": "relay",
        "peers": peer_ids,
    })

    # Replay the latest in-memory metadata snapshots. This is not file storage:
    # only compact library/progress/bookmark manifests are cached, and only until
    # the relay process restarts.
    for raw in cached_messages:
        await _send_text_safely(websocket, raw)

    await _broadcast_system(account_id, {
        "type": "peer_joined",
        "accountId": account_id,
        "deviceId": device_id,
    }, exclude=websocket)

    try:
        while True:
            incoming = await websocket.receive()
            if "text" in incoming and incoming["text"] is not None:
                message = incoming["text"]
                if len(message.encode("utf-8")) > MAX_MESSAGE_BYTES:
                    await websocket.close(
                        code=status.WS_1009_MESSAGE_TOO_BIG,
                        reason="Message too large. Use binary chunked file transfer.",
                    )
                    break

                try:
                    decoded = json.loads(message)
                except json.JSONDecodeError:
                    await websocket.send_json({"type": "error", "message": "Invalid JSON"})
                    continue

                if not isinstance(decoded, dict):
                    await websocket.send_json({"type": "error", "message": "Invalid message shape"})
                    continue

                message_type = decoded.get("type")
                envelope_account_id = decoded.get("accountId")
                envelope_device_id = decoded.get("deviceId") or device_id
                if envelope_account_id != account_id:
                    await websocket.send_json({
                        "type": "error",
                        "message": "Envelope accountId does not match websocket room",
                    })
                    continue

                protocol_version = decoded.get("protocolVersion", MIN_PROTOCOL_VERSION)
                if not _is_int_like(protocol_version) or not (
                    MIN_PROTOCOL_VERSION <= int(protocol_version) <= CURRENT_PROTOCOL_VERSION
                ):
                    await websocket.send_json({
                        "type": "error",
                        "code": "unsupported_protocol_version",
                        "message": (
                            f"Unsupported sync protocol version {protocol_version}; "
                            f"supported range is {MIN_PROTOCOL_VERSION}-{CURRENT_PROTOCOL_VERSION}"
                        ),
                        "supportedProtocolVersions": [MIN_PROTOCOL_VERSION, CURRENT_PROTOCOL_VERSION],
                    })
                    continue

                if message_type == "offline_queue_ack":
                    await _ack_offline_queue(account_id, device_id, decoded)
                    continue
                if message_type == "offline_queue_pull":
                    await _send_offline_queue_to_device(account_id, device_id, websocket)
                    continue

                raw_to_forward = message
                if _is_queueable_metadata_envelope(decoded):
                    raw_to_forward = await _append_offline_queue_message(account_id, decoded)

                if message_type == "library_snapshot":
                    await _cache_library_snapshot(account_id, str(envelope_device_id), raw_to_forward)
                elif message_type == "library_snapshot_requested":
                    await _send_cached_snapshots(
                        account_id=account_id,
                        target=websocket,
                        exclude_device_id=str(envelope_device_id),
                    )

                await _broadcast_raw(account_id, raw_to_forward, exclude=websocket)
                continue

            if "bytes" in incoming and incoming["bytes"] is not None:
                data = incoming["bytes"]
                if len(data) > MAX_BINARY_MESSAGE_BYTES:
                    await websocket.close(
                        code=status.WS_1009_MESSAGE_TOO_BIG,
                        reason="Binary chunk too large.",
                    )
                    break
                await _broadcast_binary(account_id, data, exclude=websocket)
                continue

            if incoming.get("type") == "websocket.disconnect":
                break
    except WebSocketDisconnect:
        pass
    finally:
        async with _lock:
            _rooms[account_id].pop(websocket, None)
            if not _rooms[account_id]:
                _rooms.pop(account_id, None)
        await _broadcast_system(account_id, {
            "type": "peer_left",
            "accountId": account_id,
            "deviceId": device_id,
        })


def _is_int_like(value: Any) -> bool:
    try:
        int(value)
        return True
    except (TypeError, ValueError):
        return False


def _is_queueable_metadata_envelope(decoded: dict) -> bool:
    message_type = decoded.get("type")
    if message_type not in QUEUEABLE_METADATA_TYPES:
        return False
    payload = decoded.get("payload")
    if not isinstance(payload, dict):
        return False
    # Only persist encrypted metadata. The relay must never persist plaintext manifests.
    if not isinstance(payload.get("e2ee"), dict):
        return False
    try:
        return len(json.dumps(decoded, ensure_ascii=False).encode("utf-8")) <= MAX_OFFLINE_EVENT_BYTES
    except Exception:
        return False


async def _append_offline_queue_message(account_id: str, decoded: dict) -> str:
    async with _lock:
        return _relay_store.append(account_id, decoded)


def _offline_queue_messages_for_device_locked(account_id: str, device_id: str) -> List[str]:
    return _relay_store.messages_for_device(account_id, device_id)


async def _send_offline_queue_to_device(account_id: str, device_id: str, target: WebSocket) -> None:
    async with _lock:
        messages = _offline_queue_messages_for_device_locked(account_id, device_id)
    for raw in messages:
        await _send_text_safely(target, raw, account_id=account_id)


async def _ack_offline_queue(account_id: str, device_id: str, decoded: dict) -> None:
    payload = decoded.get("payload") if isinstance(decoded.get("payload"), dict) else decoded
    cursor = payload.get("cursor") or payload.get("relayQueueSeq") or payload.get("seq")
    if not _is_int_like(cursor):
        return
    cursor_int = max(0, int(cursor))
    async with _lock:
        _relay_store.acknowledge(account_id, device_id, cursor_int)


def _normalize_pairing_code(code: str) -> str:
    return "".join(ch for ch in code if ch.isdigit())


async def _cleanup_expired_pairing_codes() -> None:
    now = time.time()
    async with _lock:
        expired = [code for code, record in _pairing_codes.items() if record.get("expiresAt", 0) < now]
        for code in expired:
            _pairing_codes.pop(code, None)


async def _cache_library_snapshot(account_id: str, device_id: str, message: str) -> None:
    if len(message.encode("utf-8")) > MAX_CACHED_SNAPSHOT_BYTES:
        return
    async with _lock:
        _snapshot_cache[account_id][device_id] = message


async def _send_cached_snapshots(
    *,
    account_id: str,
    target: WebSocket,
    exclude_device_id: str,
) -> None:
    async with _lock:
        cached_messages = [
            raw
            for owner_device_id, raw in _snapshot_cache.get(account_id, {}).items()
            if owner_device_id != exclude_device_id
        ]
    for raw in cached_messages:
        await _send_text_safely(target, raw)


async def _broadcast_raw(account_id: str, message: str, exclude: WebSocket | None = None) -> None:
    async with _lock:
        peers = list(_rooms.get(account_id, {}).keys())
    for peer in peers:
        if peer is exclude:
            continue
        await _send_text_safely(peer, message, account_id=account_id)



async def _broadcast_binary(account_id: str, message: bytes, exclude: WebSocket | None = None) -> None:
    async with _lock:
        peers = list(_rooms.get(account_id, {}).keys())
    for peer in peers:
        if peer is exclude:
            continue
        await _send_bytes_safely(peer, message, account_id=account_id)


async def _broadcast_system(account_id: str, payload: dict, exclude: WebSocket | None = None) -> None:
    await _broadcast_raw(account_id, json.dumps(payload), exclude=exclude)


async def _send_text_safely(
    peer: WebSocket,
    message: str,
    account_id: str | None = None,
) -> None:
    # Disconnects are expected during reconnects, mobile app backgrounding and
    # Tailscale/Funnel network changes. Do not let a stale peer make the relay
    # print a full ASGI traceback while broadcasting peer_left/snapshot events.
    try:
        if peer.client_state == WebSocketState.DISCONNECTED:
            raise WebSocketDisconnect(code=1005)
        await peer.send_text(message)
    except Exception as exc:  # Starlette/uvicorn/websockets use different disconnect exceptions.
        name = exc.__class__.__name__
        module = exc.__class__.__module__
        is_disconnect = (
            isinstance(exc, (RuntimeError, WebSocketDisconnect))
            or name in {
                'ClientDisconnected',
                'ConnectionClosed',
                'ConnectionClosedOK',
                'ConnectionClosedError',
            }
            or 'websockets.' in module
        )
        if not is_disconnect:
            raise
        if account_id is not None:
            async with _lock:
                room = _rooms.get(account_id)
                if room is not None:
                    room.pop(peer, None)


async def _send_bytes_safely(peer: WebSocket, message: bytes, account_id: str | None = None) -> None:
    try:
        if peer.client_state == WebSocketState.DISCONNECTED:
            raise WebSocketDisconnect(code=1005)
        await peer.send_bytes(message)
    except Exception as exc:
        name = exc.__class__.__name__
        module = exc.__class__.__module__
        is_disconnect = (
            isinstance(exc, (RuntimeError, WebSocketDisconnect))
            or name in {
                'ClientDisconnected',
                'ConnectionClosed',
                'ConnectionClosedOK',
                'ConnectionClosedError',
            }
            or 'websockets.' in module
        )
        if not is_disconnect:
            raise
        if account_id is not None:
            async with _lock:
                room = _rooms.get(account_id)
                if room is not None:
                    room.pop(peer, None)
