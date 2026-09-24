from __future__ import annotations

import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import websockets


RELAY_DIR = Path(__file__).resolve().parents[1]


class RealRelayHarnessTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        environment = os.environ.copy()
        environment["READARC_RELAY_DATA_DIR"] = self.temp.name
        self.process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(self.port),
                "--log-level",
                "warning",
            ],
            cwd=RELAY_DIR,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        await self._wait_until_ready()

    async def asyncTearDown(self) -> None:
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.temp.cleanup()

    async def _wait_until_ready(self) -> None:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                stdout, stderr = self.process.communicate()
                self.fail(f"relay exited early: {stdout.decode()} {stderr.decode()}")
            try:
                await asyncio.to_thread(
                    lambda: urllib.request.urlopen(
                        f"http://127.0.0.1:{self.port}/health", timeout=0.5
                    ).read()
                )
                return
            except Exception:
                await asyncio.sleep(0.05)
        self.fail("relay did not become ready")

    async def _connect(self, device_id: str):
        websocket = await websockets.connect(
            f"ws://127.0.0.1:{self.port}/ws/integration-account/{device_id}"
        )
        first = json.loads(await asyncio.wait_for(websocket.recv(), timeout=2))
        self.assertEqual("peer_list", first["type"])
        return websocket

    async def test_two_clients_exchange_durable_idempotent_metadata_and_binary(self) -> None:
        client_a = await self._connect("device-a")
        client_b = await self._connect("device-b")
        joined = json.loads(await asyncio.wait_for(client_a.recv(), timeout=2))
        self.assertEqual("peer_joined", joined["type"])

        operation = {
            "type": "library_snapshot",
            "accountId": "integration-account",
            "deviceId": "device-a",
            "createdAt": "2000-01-01T00:00:00Z",
            "protocolVersion": 3,
            "operationId": "progress-a-1",
            "payload": {"e2ee": {"ciphertext": "progress=67"}},
        }
        await client_a.send(json.dumps(operation))
        delivered = json.loads(await asyncio.wait_for(client_b.recv(), timeout=2))
        self.assertEqual("progress-a-1", delivered["operationId"])
        self.assertEqual(1, delivered["relayQueueSeq"])

        await client_a.send(json.dumps(operation))
        duplicate = json.loads(await asyncio.wait_for(client_b.recv(), timeout=2))
        self.assertEqual(delivered["relayQueueSeq"], duplicate["relayQueueSeq"])

        binary = b"readarc-binary-resume-chunk"
        await client_a.send(binary)
        self.assertEqual(binary, await asyncio.wait_for(client_b.recv(), timeout=2))

        await client_a.close()
        await client_b.close()

        client_c = await websockets.connect(
            f"ws://127.0.0.1:{self.port}/ws/integration-account/device-c"
        )
        replay = json.loads(await asyncio.wait_for(client_c.recv(), timeout=2))
        self.assertEqual("progress-a-1", replay["operationId"])
        peer_list = json.loads(await asyncio.wait_for(client_c.recv(), timeout=2))
        self.assertEqual("peer_list", peer_list["type"])
        await client_c.close()

    async def test_unsupported_protocol_gets_controlled_error(self) -> None:
        client = await self._connect("legacy-device")
        await client.send(
            json.dumps(
                {
                    "type": "library_snapshot",
                    "accountId": "integration-account",
                    "deviceId": "legacy-device",
                    "protocolVersion": 1,
                    "operationId": "legacy-op",
                    "payload": {"e2ee": {}},
                }
            )
        )
        error = json.loads(await asyncio.wait_for(client.recv(), timeout=2))
        self.assertEqual("unsupported_protocol_version", error["code"])
        self.assertEqual([2, 3], error["supportedProtocolVersions"])
        await client.close()

    async def test_pairing_start_retry_is_idempotent_and_claim_is_single_use(self) -> None:
        payload = {
            "accountId": "pairing-account",
            "ownerDeviceId": "android-fresh-install",
            "ownerDeviceName": "Android",
            "ownerDevicePublicKey": "public-android",
            "accountEncryptionKey": "secret-not-logged",
            "relayUrl": f"http://127.0.0.1:{self.port}",
            "expiresSeconds": 300,
            "requestId": "stable-request-id",
        }
        first = await self._post_json("/pairing/start", payload)
        retry = await self._post_json("/pairing/start", payload)
        self.assertEqual(first["code"], retry["code"])
        self.assertEqual(first["expiresAt"], retry["expiresAt"])

        claim = await self._post_json(
            "/pairing/claim",
            {
                "code": first["code"],
                "deviceId": "mac-fresh-install",
                "deviceName": "Mac",
                "devicePublicKey": "public-mac",
            },
        )
        self.assertTrue(claim["ok"])
        self.assertEqual("android-fresh-install", claim["ownerDeviceId"])
        with self.assertRaises(urllib.error.HTTPError) as duplicate_claim:
            await self._post_json(
                "/pairing/claim",
                {"code": first["code"], "deviceId": "second-mac"},
            )
        self.assertEqual(404, duplicate_claim.exception.code)

    async def _post_json(self, path: str, payload: dict) -> dict:
        def send() -> dict:
            request = urllib.request.Request(
                f"http://127.0.0.1:{self.port}{path}",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=2) as response:
                return json.loads(response.read())

        return await asyncio.to_thread(send)


if __name__ == "__main__":
    unittest.main()
