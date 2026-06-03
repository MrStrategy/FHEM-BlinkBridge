from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import signal
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock, Thread
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

from aiohttp import ClientSession
from blinkpy.auth import Auth, BlinkTwoFARequiredError, LoginError
from blinkpy.blinkpy import Blink

_LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class Config:
    data_file: Path
    image_dir: Path
    video_dir: Path
    http_host: str
    http_port: int
    poll_interval: int
    snapshot_delay: float
    username: str | None
    password: str | None
    hardware_id: str | None

    @classmethod
    def from_env(cls) -> "Config":
        data_file = Path(os.getenv("BLINK_DATA_FILE", "/data/blink_login.json"))
        return cls(
            data_file=data_file,
            image_dir=Path(os.getenv("IMAGE_DIR", str(data_file.parent / "images"))),
            video_dir=Path(
                os.getenv("VIDEO_DIR", os.getenv("IMAGE_DIR", str(data_file.parent / "images")))
            ),
            http_host=os.getenv("HTTP_HOST", "0.0.0.0"),
            http_port=int(os.getenv("HTTP_PORT", "8766")),
            poll_interval=int(os.getenv("POLL_INTERVAL", "60")),
            snapshot_delay=float(os.getenv("SNAPSHOT_DELAY", "2")),
            username=os.getenv("BLINK_USERNAME") or None,
            password=os.getenv("BLINK_PASSWORD") or None,
            hardware_id=os.getenv("BLINK_HARDWARE_ID") or None,
        )


class StateStore:
    def __init__(self) -> None:
        self._lock = Lock()
        self._state: dict[str, Any] = {
            "availability": "starting",
            "error": None,
            "timestamp": _utc_now(),
            "networks": {},
            "cameras": {},
        }

    def get(self) -> dict[str, Any]:
        with self._lock:
            return json.loads(json.dumps(self._state))

    def set(self, state: dict[str, Any]) -> None:
        with self._lock:
            self._state = state

    def update_error(self, availability: str, error: str) -> None:
        state = self.get()
        state["availability"] = availability
        state["error"] = error
        state["timestamp"] = _utc_now()
        self.set(state)


class BlinkService:
    def __init__(self, config: Config, state_store: StateStore) -> None:
        self.config = config
        self.state_store = state_store
        self.session: ClientSession | None = None
        self.blink: Blink | None = None
        self._poll_task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        await self._connect()
        self._poll_task = asyncio.create_task(self._poll_loop())

    async def stop(self) -> None:
        if self._poll_task:
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass
        if self.session:
            await self.session.close()

    async def _connect(self) -> None:
        login_data = self._load_login_data()
        self.session = ClientSession()
        self.blink = Blink(session=self.session, refresh_rate=self.config.poll_interval)
        self.blink.auth = Auth(login_data, no_prompt=True, session=self.session)

        try:
            ok = await self.blink.start()
        except BlinkTwoFARequiredError:
            self.state_store.update_error("auth_required", "Blink two-factor code required")
            raise
        except Exception as exc:
            self.state_store.update_error("offline", str(exc))
            raise

        if not ok:
            self.state_store.update_error("offline", "Blink startup failed")
            raise LoginError("Blink startup failed")

        await self._save_login()
        self._publish_state()

    def _load_login_data(self) -> dict[str, Any]:
        data: dict[str, Any] = {}
        if self.config.data_file.exists():
            data = json.loads(self.config.data_file.read_text(encoding="utf-8"))

        if self.config.username:
            data["username"] = self.config.username
        if self.config.password:
            data["password"] = self.config.password
        if self.config.hardware_id:
            data["hardware_id"] = self.config.hardware_id

        if not data.get("hardware_id"):
            seed = data.get("username") or "fhem-blink-bridge"
            data["hardware_id"] = str(uuid.uuid5(uuid.NAMESPACE_DNS, seed)).upper()

        if not data.get("username"):
            raise RuntimeError("BLINK_USERNAME or token file username is required")

        return data

    async def _save_login(self) -> None:
        assert self.blink is not None
        self.config.data_file.parent.mkdir(parents=True, exist_ok=True)
        old_umask = os.umask(0o077)
        try:
            await self.blink.save(str(self.config.data_file))
        finally:
            os.umask(old_umask)

    async def _poll_loop(self) -> None:
        while True:
            await asyncio.sleep(self.config.poll_interval)
            try:
                await self.refresh()
            except Exception as exc:
                _LOGGER.exception("Blink refresh failed")
                self.state_store.update_error("offline", str(exc))

    async def refresh(self) -> dict[str, Any]:
        assert self.blink is not None
        await self.blink.refresh(force=True)
        await self._save_login()
        self._publish_state()
        return self.state_store.get()

    async def set_arm(self, value: bool, network: str | None = None) -> dict[str, Any]:
        assert self.blink is not None
        sync = self._find_sync(network)
        response = await sync.async_arm(value)
        await asyncio.sleep(1)
        state = await self.refresh()
        state["command"] = {"arm": value, "network": sync.name, "response": _jsonable(response)}
        return state

    async def get_image(self, camera: str, refresh: bool) -> tuple[bytes, Path]:
        assert self.blink is not None
        cam = self._find_camera(camera)
        if refresh:
            await cam.snap_picture()
            if self.config.snapshot_delay > 0:
                await asyncio.sleep(self.config.snapshot_delay)

        response = await cam.get_media()
        if response is None:
            raise RuntimeError(f"No thumbnail available for {cam.name}")
        if response.status != 200:
            raise RuntimeError(f"Thumbnail request failed for {cam.name}: HTTP {response.status}")

        data = await response.read()
        if not data:
            raise RuntimeError(f"Thumbnail response for {cam.name} was empty")

        self.config.image_dir.mkdir(parents=True, exist_ok=True)
        path = self.config.image_dir / f"{_safe_name(cam.name)}.jpg"
        path.write_bytes(data)
        return data, path

    async def get_latest_video(
        self, camera: str, since_hours: int = 24
    ) -> tuple[bytes, Path, dict[str, Any]]:
        assert self.blink is not None
        cam = self._find_camera(camera)
        since = (datetime.now(timezone.utc) - timedelta(hours=since_hours)).strftime(
            "%Y/%m/%d %H:%M:%S"
        )
        videos = await self.blink.get_videos_metadata(since=since, stop=4)
        matches = [
            item
            for item in videos
            if not item.get("deleted")
            and str(item.get("device_name", "")).casefold() == cam.name.casefold()
            and item.get("media")
        ]
        matches.sort(key=lambda item: str(item.get("created_at", "")), reverse=True)
        if not matches:
            raise RuntimeError(f"No video available for {cam.name} in the last {since_hours} hours")

        item = matches[0]
        response = await self.blink.do_http_get(item["media"])
        if response is None:
            raise RuntimeError(f"Video request failed for {cam.name}")
        if response.status != 200:
            raise RuntimeError(f"Video request failed for {cam.name}: HTTP {response.status}")

        data = await response.read()
        if not data:
            raise RuntimeError(f"Video response for {cam.name} was empty")

        self.config.video_dir.mkdir(parents=True, exist_ok=True)
        created = _safe_name(str(item.get("created_at") or _utc_now()))
        path = self.config.video_dir / f"{created}_{_safe_name(cam.name)}.mp4"
        path.write_bytes(data)
        return data, path, _video_summary(item)

    def _find_sync(self, network: str | None):
        assert self.blink is not None
        if not self.blink.sync:
            raise RuntimeError("No Blink networks available")
        if network:
            wanted = network.casefold()
            for name, sync in self.blink.sync.items():
                if name.casefold() == wanted or str(sync.network_id) == network:
                    return sync
            raise RuntimeError(f"Unknown Blink network: {network}")
        return next(iter(self.blink.sync.values()))

    def _find_camera(self, camera: str):
        assert self.blink is not None
        wanted = unquote(camera).casefold()
        for name, cam in self.blink.cameras.items():
            if name.casefold() == wanted or str(cam.camera_id) == camera:
                return cam
        raise RuntimeError(f"Unknown Blink camera: {camera}")

    def _publish_state(self) -> None:
        assert self.blink is not None
        networks: dict[str, Any] = {}
        for name, sync in sorted(self.blink.sync.items()):
            networks[name] = {
                "id": str(sync.network_id),
                "armed": sync.arm,
                "online": sync.online,
                "status": sync.status,
            }

        cameras: dict[str, Any] = {}
        for name, cam in sorted(self.blink.cameras.items()):
            attrs = cam.attributes
            cameras[name] = {
                "id": str(attrs.get("camera_id")),
                "serial": attrs.get("serial"),
                "type": attrs.get("type"),
                "network_id": str(attrs.get("network_id")),
                "sync_module": attrs.get("sync_module"),
                "motion_enabled": attrs.get("motion_enabled"),
                "motion_detected": attrs.get("motion_detected"),
                "battery": attrs.get("battery"),
                "battery_level": attrs.get("battery_level"),
                "battery_voltage": attrs.get("battery_voltage"),
                "wifi_strength": attrs.get("wifi_strength"),
                "temperature_c": attrs.get("temperature_c"),
                "last_record": _string_or_none(attrs.get("last_record")),
                "thumbnail": bool(attrs.get("thumbnail")),
            }

        self.state_store.set(
            {
                "availability": "online",
                "error": None,
                "timestamp": _utc_now(),
                "account_id": self.blink.account_id,
                "client_id": self.blink.client_id,
                "region_id": self.blink.auth.region_id,
                "host": self.blink.auth.host,
                "networks": networks,
                "cameras": cameras,
            }
        )


class BridgeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, server_address, handler_class, *, loop, state_store, service):
        super().__init__(server_address, handler_class)
        self.loop = loop
        self.state_store = state_store
        self.service = service


class Handler(BaseHTTPRequestHandler):
    server: BridgeHTTPServer

    def log_message(self, fmt: str, *args: Any) -> None:
        _LOGGER.info("HTTP %s - %s", self.address_string(), fmt % args)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query, keep_blank_values=False)

        try:
            if parsed.path == "/health":
                state = self.server.state_store.get()
                ok = state.get("availability") == "online"
                self._send_json(
                    HTTPStatus.OK if ok else HTTPStatus.SERVICE_UNAVAILABLE,
                    {"ok": ok, "availability": state.get("availability"), "error": state.get("error")},
                )
                return

            if parsed.path == "/state":
                self._send_json(HTTPStatus.OK, self.server.state_store.get())
                return

            if parsed.path == "/set":
                arm = _last(query, "arm")
                if arm is None:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Missing arm parameter"})
                    return
                payload = self._submit(self.server.service.set_arm(_bool_value(arm), _last(query, "network")))
                self._send_json(HTTPStatus.OK, payload)
                return

            if parsed.path in ("/thumbnail", "/snapshot"):
                camera = _last(query, "camera")
                if not camera:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Missing camera parameter"})
                    return
                refresh = parsed.path == "/snapshot"
                data, path = self._submit(self.server.service.get_image(camera, refresh))
                self._send_binary(HTTPStatus.OK, data, "image/jpeg", {"X-BlinkBridge-Path": str(path)})
                return

            if parsed.path == "/video":
                camera = _last(query, "camera")
                if not camera:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Missing camera parameter"})
                    return
                since_hours = int(_last(query, "since_hours") or "24")
                data, path, video = self._submit(
                    self.server.service.get_latest_video(camera, since_hours)
                )
                self._send_binary(
                    HTTPStatus.OK,
                    data,
                    "video/mp4",
                    {
                        "X-BlinkBridge-Path": str(path),
                        "X-BlinkBridge-Video": json.dumps(video, sort_keys=True),
                    },
                )
                return

            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})
        except Exception as exc:
            _LOGGER.exception("HTTP request failed")
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})

    def _submit(self, coro):
        future = asyncio.run_coroutine_threadsafe(coro, self.server.loop)
        return future.result(timeout=90)

    def _send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self._send_binary(status, body, "application/json; charset=utf-8")

    def _send_binary(
        self,
        status: HTTPStatus,
        body: bytes,
        content_type: str,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


class HTTPApi:
    def __init__(self, config: Config, loop, state_store: StateStore, service: BlinkService):
        self._server = BridgeHTTPServer(
            (config.http_host, config.http_port),
            Handler,
            loop=loop,
            state_store=state_store,
            service=service,
        )
        self._thread = Thread(target=self._server.serve_forever, daemon=True)

    def start(self) -> None:
        _LOGGER.info("Starting HTTP API on %s:%s", *self._server.server_address)
        self._thread.start()

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)


async def main() -> None:
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if os.getenv("LOG_LEVEL", "INFO").upper() != "DEBUG":
        logging.getLogger("blinkpy").setLevel(logging.WARNING)
    config = Config.from_env()
    state_store = StateStore()
    service = BlinkService(config, state_store)
    loop = asyncio.get_running_loop()
    api = HTTPApi(config, loop, state_store, service)
    stop_event = asyncio.Event()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    api.start()
    try:
        await service.start()
    except BlinkTwoFARequiredError:
        _LOGGER.error("Blink account needs a 2FA code. Run the setup login flow again.")
    except Exception:
        _LOGGER.exception("Blink startup failed")

    await stop_event.wait()
    api.stop()
    await service.stop()


def run() -> None:
    asyncio.run(main())


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _last(query: dict[str, list[str]], key: str) -> str | None:
    values = query.get(key)
    return values[-1] if values else None


def _bool_value(value: str) -> bool:
    normalized = value.lower()
    if normalized in {"1", "true", "yes", "on", "armed", "arm"}:
        return True
    if normalized in {"0", "false", "no", "off", "disarmed", "disarm"}:
        return False
    raise ValueError(f"Invalid boolean value: {value}")


def _safe_name(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return safe.strip("._") or f"camera_{int(time.time())}"


def _string_or_none(value: Any) -> str | None:
    return None if value is None else str(value)


def _jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    try:
        return json.loads(json.dumps(value))
    except TypeError:
        return str(value)


def _video_summary(item: dict[str, Any]) -> dict[str, Any]:
    keys = ("id", "created_at", "device_name", "network_name", "duration", "size")
    return {key: _jsonable(item.get(key)) for key in keys if key in item}
