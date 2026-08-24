#!/usr/bin/env python3

"""Backend for the Omarchy Fire TV Remote plugin."""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import os
import re
import shlex
import socket
import sys
import time
from pathlib import Path
from typing import Any

from adb_shell.adb_device import AdbDeviceTcp
from adb_shell.auth.keygen import keygen
from adb_shell.auth.sign_pythonrsa import PythonRSASigner
from adb_shell.exceptions import (
    AdbConnectionError,
    AdbTimeoutError,
    DeviceAuthError,
)

# Android keyevent codes used by Fire TV Stick remotes.
KEYEVENTS = {
    "up": 19,
    "down": 20,
    "left": 21,
    "right": 22,
    "select": 23,
    "back": 4,
    "home": 3,
    "menu": 82,
    "play-pause": 85,
    "previous": 88,
    "next": 87,
    "volume-down": 25,
    "volume-up": 24,
    "wake": 224,
    "sleep": 223,
}

# Fire TV package names exposed by the UI (and CLI app-* actions).
APP_PACKAGES: dict[str, list[str]] = {
    "netflix": ["com.netflix.ninja"],
    "prime": ["com.amazon.avod"],
    "disney": ["com.disney.disneyplus"],
}

DEFAULT_ADB_PORT = 5555
CONNECT_TIMEOUT_S = 5.0
AUTH_TIMEOUT_S = 30.0
SHELL_TIMEOUT_S = 5.0
AVAHI_OUTPUT_LIMIT_BYTES = 256 * 1024


def emit(event: str, **values: Any) -> None:
    print(json.dumps({"event": event, **values}, separators=(",", ":")), flush=True)


def normalize_host(host: str, default_port: int = DEFAULT_ADB_PORT) -> tuple[str, int]:
    raw = host.strip()
    if not raw:
        raise ValueError("host is empty")

    if raw.startswith("["):
        # IPv6 literal form [addr]:port
        match = re.fullmatch(r"\[([^\]]+)\](?::(\d+))?", raw)
        if not match:
            raise ValueError(f"invalid host: {host}")
        address = match.group(1)
        port = int(match.group(2) or default_port)
        return address, port

    if raw.count(":") == 1 and not raw.endswith(":"):
        address, port_text = raw.rsplit(":", 1)
        if port_text.isdigit():
            return address, int(port_text)

    return raw, default_port


def host_key(address: str, port: int) -> str:
    return f"{address}:{port}"


def decode_avahi_value(value: str) -> str:
    """Decode avahi-browse's decimal ``\\DDD`` name escapes."""
    return re.sub(
        r"\\([0-9]{3})",
        lambda match: chr(int(match.group(1), 10)),
        value,
    )


def parse_avahi_records(output: str, service: str) -> list[dict[str, str]]:
    """Parse IPv4 records from ``avahi-browse -rtpk`` output."""
    hosts: list[dict[str, str]] = []
    seen: set[str] = set()

    for raw_line in output.splitlines():
        fields = raw_line.split(";")
        if (
            len(fields) < 9
            or fields[0] != "="
            or fields[2] != "IPv4"
            or fields[4] != service
        ):
            continue

        try:
            address = str(ipaddress.IPv4Address(fields[7]))
        except ipaddress.AddressValueError:
            continue
        try:
            advertised_port = int(fields[8])
        except ValueError:
            advertised_port = DEFAULT_ADB_PORT
        adb_port = advertised_port if service == "_adb._tcp" else DEFAULT_ADB_PORT
        identifier = host_key(address, adb_port)
        if identifier in seen:
            continue

        name = decode_avahi_value(fields[3])
        if len(fields) > 9:
            try:
                txt_records = shlex.split(";".join(fields[9:]))
            except ValueError:
                txt_records = []
            for record in txt_records:
                if record.startswith("n=") and record[2:].strip():
                    name = decode_avahi_value(record[2:].strip())
                    break

        seen.add(identifier)
        hosts.append(
            {
                "name": name,
                "host": identifier,
                "address": address,
                "port": str(adb_port),
            }
        )

    return hosts


class RemoteSession:
    def __init__(self, host: str, name: str) -> None:
        self.default_host = host
        self.default_name = name
        self.host = host
        self.name = name
        self.identifier = ""
        self.address = ""
        self.port = DEFAULT_ADB_PORT
        self.connected = False
        self.device: AdbDeviceTcp | None = None
        self.signer: PythonRSASigner | None = None
        self.discovered: dict[str, dict[str, Any]] = {}

        data_home = Path(
            os.environ.get(
                "XDG_DATA_HOME",
                str(Path.home() / ".local" / "share"),
            )
        )
        self.data_path = data_home / "io.github.ypmrg.fire-tv-remote"
        self.adbkey_path = self.data_path / "adbkey"

        state_home = Path(
            os.environ.get(
                "XDG_STATE_HOME",
                str(Path.home() / ".local" / "state"),
            )
        )
        self.state_path = state_home / "fire-tv-remote" / "devices.json"
        self.state: dict[str, Any] = {"selected": "", "devices": {}}

    def load_state(self) -> None:
        try:
            loaded = json.loads(self.state_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and isinstance(loaded.get("devices"), dict):
                self.state = loaded
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            pass

        selected = str(self.state.get("selected", ""))
        device = self.state.get("devices", {}).get(selected, {})
        if isinstance(device, dict) and device:
            self.host = str(device.get("host") or self.host)
            self.name = str(device.get("name") or self.name)
            self.identifier = selected
            self.address = str(device.get("address") or "")
            try:
                self.port = int(device.get("port") or DEFAULT_ADB_PORT)
            except (TypeError, ValueError):
                self.port = DEFAULT_ADB_PORT

    def save_state(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(self.state, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        os.replace(temporary, self.state_path)

    def ensure_keys(self) -> PythonRSASigner:
        if self.signer is not None:
            return self.signer

        self.data_path.mkdir(parents=True, exist_ok=True)
        private_path = self.adbkey_path
        public_path = Path(str(private_path) + ".pub")
        if not private_path.exists() or not public_path.exists():
            keygen(str(private_path))
            private_path.chmod(0o600)
            if public_path.exists():
                public_path.chmod(0o600)

        private_key = private_path.read_text(encoding="utf-8")
        public_key = public_path.read_text(encoding="utf-8")
        self.signer = PythonRSASigner(public_key, private_key)
        return self.signer

    async def resolve_host(self, host: str) -> tuple[str, int]:
        address, port = normalize_host(host)
        try:
            socket.inet_aton(address)
            return address, port
        except OSError:
            pass

        loop = asyncio.get_running_loop()
        try:
            addresses = await loop.getaddrinfo(
                address,
                port,
                family=socket.AF_INET,
                type=socket.SOCK_STREAM,
            )
        except socket.gaierror as error:
            raise RuntimeError(f"could not resolve {host}") from error
        if not addresses:
            raise RuntimeError(f"could not resolve {host}")
        return str(addresses[0][4][0]), port

    async def start(self) -> None:
        self.load_state()
        self.ensure_keys()
        try:
            await self.connect()
        except Exception:
            if self.host == self.default_host and self.name == self.default_name:
                raise
            self.host = self.default_host
            self.name = self.default_name
            self.identifier = ""
            self.address = ""
            self.port = DEFAULT_ADB_PORT
            await self.connect()

    async def connect(
        self,
        *,
        host: str | None = None,
        name: str | None = None,
        auth_timeout_s: float = AUTH_TIMEOUT_S,
    ) -> None:
        if self.connected and self.device is not None and host is None:
            return

        target_host = host or self.host
        target_name = name or self.name
        address, port = await self.resolve_host(target_host)
        identifier = host_key(address, port)

        await self.close_connection()
        signer = self.ensure_keys()
        device = AdbDeviceTcp(
            address,
            port,
            default_transport_timeout_s=CONNECT_TIMEOUT_S,
        )

        try:
            connected = await asyncio.to_thread(
                device.connect,
                rsa_keys=[signer],
                auth_timeout_s=auth_timeout_s,
            )
        except DeviceAuthError as error:
            self.host = host_key(address, port)
            self.name = target_name
            self.identifier = identifier
            self.address = address
            self.port = port
            raise RuntimeError(
                "accept the Allow USB debugging prompt on the Fire TV, "
                "then retry connection"
            ) from error
        except Exception as error:
            # adb-shell wraps transport failures in several exception types.
            raise RuntimeError(
                f"could not connect to Fire TV at {host_key(address, port)}: {error}"
            ) from error

        if not connected:
            raise RuntimeError(
                f"could not connect to Fire TV at {host_key(address, port)}"
            )

        self.device = device
        self.connected = True
        self.address = address
        self.port = port
        self.host = host_key(address, port)
        self.name = target_name or await self.read_device_name()
        self.identifier = identifier
        self.remember_device(authorized=True)
        self.discovered[identifier] = self.safe_device(
            identifier=identifier,
            name=self.name,
            address=address,
            port=port,
            authorized=True,
            online=True,
        )

    async def close_connection(self) -> None:
        device = self.device
        self.device = None
        self.connected = False
        if device is None:
            return
        try:
            await asyncio.to_thread(device.close)
        except Exception:
            pass

    async def close(self) -> None:
        await self.close_connection()

    async def shell(self, command: str) -> str:
        if self.device is None or not self.connected:
            raise RuntimeError("not connected")
        result = await asyncio.to_thread(
            self.device.shell,
            command,
            transport_timeout_s=SHELL_TIMEOUT_S,
            read_timeout_s=SHELL_TIMEOUT_S,
        )
        if result is None:
            return ""
        return str(result)

    async def read_device_name(self) -> str:
        try:
            raw = await self.shell("getprop ro.product.model")
            name = raw.strip().splitlines()[0].strip() if raw.strip() else ""
            if name:
                return name
        except Exception:
            pass
        return self.name or "Fire TV Stick"

    async def power_status(self) -> str:
        try:
            display = await self.shell(
                "dumpsys power | grep -E 'Display Power|mScreenOn|mWakefulness' | head -n 8"
            )
        except Exception:
            return "unknown"

        lowered = display.lower()
        if "state=off" in lowered or "mscreenon=false" in lowered:
            return "asleep"
        if "mwakefulness=asleep" in lowered or "mwakefulness=dreaming" in lowered:
            return "idle"
        if "state=on" in lowered or "mscreenon=true" in lowered:
            return "awake"
        return "unknown"

    @staticmethod
    def safe_device(
        *,
        identifier: str,
        name: str,
        address: str,
        port: int,
        authorized: bool = False,
        online: bool = False,
    ) -> dict[str, Any]:
        return {
            "identifier": identifier,
            "name": name,
            "host": host_key(address, port),
            "address": address,
            "port": port,
            "paired": authorized,
            "authorized": authorized,
            "online": online,
        }

    def remember_device(self, *, authorized: bool) -> None:
        if not authorized or not self.identifier:
            return
        device = self.safe_device(
            identifier=self.identifier,
            name=self.name,
            address=self.address,
            port=self.port,
            authorized=True,
            online=True,
        )
        self.state.setdefault("devices", {})[device["identifier"]] = device
        self.state["selected"] = device["identifier"]
        self.save_state()

    async def probe_host(
        self,
        host: str,
        *,
        name: str = "",
        authorized: bool | None = None,
    ) -> dict[str, Any] | None:
        try:
            address, port = await self.resolve_host(host)
        except Exception:
            return None

        identifier = host_key(address, port)
        open_port = await self.tcp_open(address, port)
        if not open_port:
            if authorized:
                return self.safe_device(
                    identifier=identifier,
                    name=name or identifier,
                    address=address,
                    port=port,
                    authorized=True,
                    online=False,
                )
            return None

        device_name = name or identifier
        is_authorized = bool(authorized)
        if authorized is None or authorized:
            # Best-effort model read only when already trusted; avoid
            # hanging on a brand-new unauthorized prompt during scans.
            if authorized:
                try:
                    probe = AdbDeviceTcp(
                        address,
                        port,
                        default_transport_timeout_s=2.0,
                    )
                    signer = self.ensure_keys()
                    ok = await asyncio.to_thread(
                        probe.connect,
                        rsa_keys=[signer],
                        auth_timeout_s=0.5,
                    )
                    if ok:
                        try:
                            raw = await asyncio.to_thread(
                                probe.shell,
                                "getprop ro.product.model",
                                transport_timeout_s=2.0,
                                read_timeout_s=2.0,
                            )
                            candidate = str(raw or "").strip().splitlines()
                            if candidate and candidate[0].strip():
                                device_name = candidate[0].strip()
                            is_authorized = True
                        finally:
                            await asyncio.to_thread(probe.close)
                except DeviceAuthError:
                    is_authorized = False
                except Exception:
                    is_authorized = bool(authorized)

        return self.safe_device(
            identifier=identifier,
            name=device_name,
            address=address,
            port=port,
            authorized=is_authorized,
            online=True,
        )

    @staticmethod
    async def tcp_open(address: str, port: int, timeout: float = 0.4) -> bool:
        try:
            _reader, writer = await asyncio.wait_for(
                asyncio.open_connection(address, port),
                timeout=timeout,
            )
        except Exception:
            return False
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True

    async def avahi_browse(self, service: str) -> list[dict[str, str]]:
        """Return IPv4 records for a DNS-SD service type via avahi-browse."""
        try:
            process = await asyncio.create_subprocess_exec(
                "avahi-browse",
                "-rtpk",
                service,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except FileNotFoundError:
            return []

        try:
            stdout = await asyncio.wait_for(
                process.stdout.readexactly(AVAHI_OUTPUT_LIMIT_BYTES + 1),
                timeout=6.0,
            )
        except asyncio.IncompleteReadError as error:
            stdout = error.partial
        except TimeoutError:
            stdout = None

        if stdout is None or len(stdout) > AVAHI_OUTPUT_LIMIT_BYTES:
            if process.returncode is None:
                process.kill()
            await process.wait()
            return []

        await process.wait()
        return parse_avahi_records(stdout.decode(errors="replace"), service)

    async def avahi_adb_hosts(self) -> list[dict[str, str]]:
        return await self.avahi_browse("_adb._tcp")

    async def avahi_fire_tv_hosts(self) -> list[dict[str, str]]:
        # Amazon advertises Fire TV on _amzn-wplay._tcp even when ADB mDNS is off.
        return await self.avahi_browse("_amzn-wplay._tcp")

    @staticmethod
    def default_route_ipv4() -> str | None:
        """Best-effort primary LAN IPv4 (for /24 ADB port scan)."""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                sock.connect(("1.1.1.1", 80))
                return str(sock.getsockname()[0])
            finally:
                sock.close()
        except OSError:
            return None

    async def scan_lan_adb_hosts(self) -> list[dict[str, str]]:
        """Probe TCP/5555 on the local /24 (bounded concurrency)."""
        local = self.default_route_ipv4()
        if not local:
            return []
        parts = local.split(".")
        if len(parts) != 4:
            return []
        prefix = ".".join(parts[:3])
        try:
            own = int(parts[3])
        except ValueError:
            return []

        semaphore = asyncio.Semaphore(48)
        found: list[dict[str, str]] = []

        async def check(host_num: int) -> None:
            if host_num == own or host_num in (0, 255):
                return
            address = f"{prefix}.{host_num}"
            async with semaphore:
                if not await self.tcp_open(address, DEFAULT_ADB_PORT, timeout=0.35):
                    return
            found.append(
                {
                    "name": f"ADB {address}",
                    "host": host_key(address, DEFAULT_ADB_PORT),
                    "address": address,
                    "port": str(DEFAULT_ADB_PORT),
                }
            )

        await asyncio.gather(*(check(n) for n in range(1, 255)))
        return found

    async def scan_devices(self) -> list[dict[str, Any]]:
        candidates: dict[str, dict[str, Any]] = {}

        async def consider(host: str, name: str = "", *, authorized: bool | None = None) -> None:
            probed = await self.probe_host(host, name=name, authorized=authorized)
            if probed is not None:
                candidates[str(probed["identifier"])] = probed

        preferred = await self.probe_host(self.default_host, name=self.default_name)
        if preferred is not None:
            candidates[str(preferred["identifier"])] = preferred
        else:
            try:
                address, port = await self.resolve_host(self.default_host)
                identifier = host_key(address, port)
                candidates[identifier] = self.safe_device(
                    identifier=identifier,
                    name=self.default_name or identifier,
                    address=address,
                    port=port,
                    authorized=False,
                    online=False,
                )
            except Exception:
                pass

        for identifier, stored in self.state.get("devices", {}).items():
            if not isinstance(stored, dict):
                continue
            host = str(stored.get("host") or stored.get("address") or identifier)
            name = str(stored.get("name") or host)
            probed = await self.probe_host(host, name=name, authorized=True)
            if probed is not None:
                candidates[str(probed["identifier"])] = probed
            else:
                address, port = normalize_host(host)
                candidates[identifier] = self.safe_device(
                    identifier=str(identifier),
                    name=name,
                    address=address,
                    port=port,
                    authorized=True,
                    online=False,
                )

        for record in await self.avahi_adb_hosts():
            await consider(record["host"], record.get("name", ""))

        for record in await self.avahi_fire_tv_hosts():
            await consider(
                host_key(record["address"], DEFAULT_ADB_PORT),
                record.get("name", "") or "Fire TV",
            )

        # Last resort: open ADB ports on the primary LAN (/24).
        if not any(bool(d.get("online")) for d in candidates.values()):
            for record in await self.scan_lan_adb_hosts():
                await consider(record["host"], record.get("name", ""))

        if self.connected and self.identifier:
            candidates[self.identifier] = self.safe_device(
                identifier=self.identifier,
                name=self.name,
                address=self.address,
                port=self.port,
                authorized=True,
                online=True,
            )

        for identifier, device in candidates.items():
            self.discovered[identifier] = device
            if device.get("authorized"):
                self.state.setdefault("devices", {})[identifier] = {
                    **device,
                    "online": bool(device.get("online")),
                }

        self.save_state()
        return sorted(
            candidates.values(),
            key=lambda device: (
                not bool(device.get("online")),
                not bool(device.get("authorized")),
                str(device.get("name", "")).lower(),
            ),
        )

    def active_device(self) -> dict[str, str]:
        return {
            "identifier": self.identifier,
            "name": self.name,
            "host": self.host,
        }

    async def switch_device(self, identifier: str) -> None:
        if identifier == self.identifier and self.connected:
            emit("switched", **self.active_device())
            return

        device = self.discovered.get(identifier)
        if device is None:
            stored = self.state.get("devices", {}).get(identifier)
            if isinstance(stored, dict):
                device = stored
        if device is None:
            # Treat bare identifiers as host:port targets.
            device = {"host": identifier, "name": identifier}

        host = str(device.get("host") or device.get("address") or identifier)
        name = str(device.get("name") or host)
        await self.connect(host=host, name=name)
        emit("switched", **self.active_device())

    async def authorize_device(self, identifier: str = "") -> None:
        target = identifier or self.identifier or self.host
        device = self.discovered.get(target)
        if device is None:
            stored = self.state.get("devices", {}).get(target)
            if isinstance(stored, dict):
                device = stored
        host = str((device or {}).get("host") or target)
        name = str((device or {}).get("name") or host)
        await self.connect(host=host, name=name, auth_timeout_s=AUTH_TIMEOUT_S)
        emit("authorized", **self.active_device())

    async def add_device(self, host: str, name: str = "") -> None:
        address, port = await self.resolve_host(host)
        identifier = host_key(address, port)
        label = name.strip() or identifier
        self.discovered[identifier] = self.safe_device(
            identifier=identifier,
            name=label,
            address=address,
            port=port,
            authorized=False,
            online=await self.tcp_open(address, port),
        )
        try:
            await self.connect(host=identifier, name=label)
            emit("authorized", **self.active_device())
        except RuntimeError as error:
            message = str(error)
            if "Allow USB debugging" in message:
                emit(
                    "auth-required",
                    identifier=identifier,
                    name=label,
                    host=identifier,
                    message=message,
                )
                return
            raise

    async def handle_request(self, request: dict[str, Any]) -> None:
        operation = str(request.get("op", ""))
        if operation == "discover":
            emit("devices", devices=await self.scan_devices())
            return
        if operation == "switch":
            await self.switch_device(str(request.get("identifier", "")))
            return
        if operation == "authorize":
            await self.authorize_device(str(request.get("identifier", "")))
            return
        if operation == "add":
            await self.add_device(
                str(request.get("host", "")),
                str(request.get("name", "")),
            )
            return
        if operation == "auth-cancel":
            emit("auth-cancelled")
            return
        raise ValueError(f"unknown operation: {operation}")

    async def launch_app(self, app_id: str) -> str:
        packages = APP_PACKAGES.get(app_id)
        if not packages:
            raise ValueError(f"unknown app: {app_id}")

        errors: list[str] = []
        for package in packages:
            # Prefer leanback (TV), then generic launcher, then monkey.
            for command in (
                "am start -a android.intent.action.MAIN "
                f"-c android.intent.category.LEANBACK_LAUNCHER -p {package}",
                "am start -a android.intent.action.MAIN "
                f"-c android.intent.category.LAUNCHER -p {package}",
                f"monkey -p {package} -c android.intent.category.LAUNCHER 1",
            ):
                try:
                    output = await self.shell(command)
                except Exception as error:  # noqa: BLE001 - keep best error for UI
                    errors.append(f"{package}: {error}")
                    continue
                lowered = (output or "").lower()
                if "error" in lowered and "warning" not in lowered:
                    errors.append(f"{package}: {output.strip()}")
                    continue
                return package

        detail = "; ".join(errors[-3:]) if errors else "not installed"
        raise RuntimeError(f"could not launch {app_id} ({detail})")

    async def dispatch_connected(self, action: str) -> str:
        if action in KEYEVENTS:
            await self.shell(f"input keyevent {KEYEVENTS[action]}")
            return ""
        if action.startswith("app-"):
            return await self.launch_app(action.removeprefix("app-"))
        if action == "status":
            return await self.power_status()
        raise ValueError(f"unknown action: {action}")

    async def dispatch(self, action: str) -> str:
        await self.connect()
        try:
            return await self.dispatch_connected(action)
        except (AdbConnectionError, AdbTimeoutError, OSError, RuntimeError):
            await self.close_connection()
            await self.connect()
            return await self.dispatch_connected(action)

    async def run(self) -> None:
        try:
            await self.start()
            status = await self.power_status() if self.connected else ""
            emit("ready", status=status, **self.active_device())
        except Exception as error:
            message = str(error)
            if "Allow USB debugging" in message:
                emit(
                    "auth-required",
                    identifier=self.identifier or self.host,
                    name=self.name,
                    host=self.host,
                    message=message,
                )
            else:
                emit("error", action="connect", message=message)

        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                break

            raw_command = line.strip()
            if not raw_command:
                continue
            if raw_command == "quit":
                break

            started = time.monotonic()
            try:
                if raw_command.startswith("{"):
                    request = json.loads(raw_command)
                    await self.handle_request(request)
                    continue

                result = await self.dispatch(raw_command)
                emit(
                    "result",
                    action=raw_command,
                    result=result,
                    elapsedMs=round((time.monotonic() - started) * 1000, 1),
                )
            except Exception as error:
                action = raw_command
                if raw_command.startswith("{"):
                    try:
                        action = str(json.loads(raw_command).get("op", "request"))
                    except json.JSONDecodeError:
                        action = "request"
                message = str(error)
                if "Allow USB debugging" in message:
                    emit(
                        "auth-required",
                        identifier=self.identifier or self.host,
                        name=self.name,
                        host=self.host,
                        message=message,
                    )
                    continue
                emit(
                    "error",
                    action=action,
                    message=message,
                    connected=self.connected,
                )


async def async_main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()

    session = RemoteSession(args.host, args.name)
    try:
        await session.run()
    finally:
        await session.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(async_main()))
