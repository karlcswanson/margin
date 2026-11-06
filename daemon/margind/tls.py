"""HTTPS for web previews, so pages are secure contexts (service workers,
crypto.subtle, getUserMedia, clipboard, ...).

The daemon keeps its own small certificate authority, like mkcert, in the
workspace state folder. It is restricted (X.509 name constraints) to private
addresses, localhost and the names in `tls_names`, so even a stolen key can't
vouch for anything else. The app trusts it for previews by itself; installing
it on the iPad as a profile makes everything trust it (WebSockets, workers).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import ipaddress
import logging
import os
import plistlib
import re
import socket
import ssl
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from .config import WorkspaceConfig

log = logging.getLogger("margind.tls")

PRIVATE_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "::1/128", "fc00::/7", "fe80::/10")]
LEAF_DAYS = 397          # Apple's limit for TLS server certificates is 398 days
WINDOWS = sys.platform == "win32"


@dataclass
class Certs:
    ca_pem: bytes
    cert_path: Path
    key_path: Path

    @property
    def ca_der(self) -> bytes:
        return x509.load_pem_x509_certificate(self.ca_pem).public_bytes(serialization.Encoding.DER)

    @property
    def ca_sha256(self) -> str:
        return hashlib.sha256(self.ca_der).hexdigest()

    def server_context(self) -> ssl.SSLContext:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(self.cert_path, self.key_path)
        return ctx


def local_names(ws: WorkspaceConfig) -> tuple[list[str], list[str]]:
    """DNS names and private IP addresses this computer answers on."""
    names = {"localhost", *ws.tls_names}
    host = socket.gethostname().split(".")[0]
    if host:
        names.add(f"{host}.local")
    ips = {"127.0.0.1", "::1"}
    if WINDOWS:
        ips.update(_windows_ips())
    else:
        try:
            out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
            ips.update(re.findall(r"^\s*inet (\d+\.\d+\.\d+\.\d+)", out, re.M))
        except (OSError, subprocess.TimeoutExpired):
            pass
    if ws.bind not in ("0.0.0.0", "::", ""):
        ips.add(ws.bind)
    private = sorted(i for i in ips if any(ipaddress.ip_address(i) in n for n in PRIVATE_NETS))
    return sorted(names), private


def _windows_ips() -> set[str]:
    """IPv4 addresses of this computer's interfaces (no ifconfig on Windows)."""
    try:
        import psutil
        return {a.address for addrs in psutil.net_if_addrs().values() for a in addrs
                if a.family == socket.AF_INET}
    except (ImportError, OSError):
        pass
    try:
        return {i[4][0] for i in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)}
    except OSError:
        return set()


def _cn(name: str) -> str:
    """A certificate's common name holds at most 64 bytes of UTF-8; long computer names are cut."""
    while len(name.encode()) > 64:
        name = name[:-1]
    return name


def ensure(ws: WorkspaceConfig) -> Certs:
    """The CA (made once) and a server certificate for this computer's current
    names and addresses (remade when they change or it nears expiry)."""
    d = ws.state_path / "tls"
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    names, ips = local_names(ws)
    ca_key, ca = _ca(d, ws, names)
    cert_path, key_path = d / "server.pem", d / "server.key"
    if not _leaf_ok(cert_path, names, ips):
        key = ec.generate_private_key(ec.SECP256R1())
        now = dt.datetime.now(dt.timezone.utc)
        san = [x509.DNSName(n) for n in names] + [x509.IPAddress(ipaddress.ip_address(i)) for i in ips]
        cert = (x509.CertificateBuilder()
                .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, _cn(f"margind {ws.name}"))]))
                .issuer_name(ca.subject)
                .public_key(key.public_key())
                .serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(hours=1))
                .not_valid_after(now + dt.timedelta(days=LEAF_DAYS))
                .add_extension(x509.SubjectAlternativeName(san), critical=False)
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                .add_extension(x509.KeyUsage(digital_signature=True, key_encipherment=False, content_commitment=False,
                                             data_encipherment=False, key_agreement=False, key_cert_sign=False,
                                             crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
                .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
                .sign(ca_key, hashes.SHA256()))
        _write(key_path, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()), private=True)
        _write(cert_path, cert.public_bytes(serialization.Encoding.PEM) + ca.public_bytes(serialization.Encoding.PEM))
        log.info("TLS certificate for %s", ", ".join(names + ips))
    return Certs(ca.public_bytes(serialization.Encoding.PEM), cert_path, key_path)


def _ca(d: Path, ws: WorkspaceConfig, names: list[str]) -> tuple[ec.EllipticCurvePrivateKey, x509.Certificate]:
    key_path, pem_path = d / "ca.key", d / "ca.pem"
    if key_path.exists() and pem_path.exists():
        key = serialization.load_pem_private_key(key_path.read_bytes(), None)
        ca = x509.load_pem_x509_certificate(pem_path.read_bytes())
        if _ca_covers(ca, names):
            return key, ca  # type: ignore[return-value]
        log.warning("tls_names changed: making a new CA (reinstall the profile on the iPad)")
    key = ec.generate_private_key(ec.SECP256R1())
    now = dt.datetime.now(dt.timezone.utc)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,
                                            _cn(f"Margin local CA · {ws.name} on {socket.gethostname().split('.')[0]}"))])
    permitted = ([x509.DNSName(n) for n in sorted({"localhost", "local", *ws.tls_names})]
                 + [x509.IPAddress(n) for n in PRIVATE_NETS])
    ca = (x509.CertificateBuilder()
          .subject_name(subject).issuer_name(subject)
          .public_key(key.public_key())
          .serial_number(x509.random_serial_number())
          .not_valid_before(now - dt.timedelta(hours=1))
          .not_valid_after(now + dt.timedelta(days=3650))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
          .add_extension(x509.KeyUsage(digital_signature=False, key_encipherment=False, content_commitment=False,
                                       data_encipherment=False, key_agreement=False, key_cert_sign=True,
                                       crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
          .add_extension(x509.NameConstraints(permitted_subtrees=permitted, excluded_subtrees=None), critical=True)
          .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
          .sign(key, hashes.SHA256()))
    _write(key_path, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()), private=True)
    _write(pem_path, ca.public_bytes(serialization.Encoding.PEM))
    (d / "server.pem").unlink(missing_ok=True)
    return key, ca


def _ca_covers(ca: x509.Certificate, names: list[str]) -> bool:
    try:
        nc = ca.extensions.get_extension_for_class(x509.NameConstraints).value
    except x509.ExtensionNotFound:
        return False
    allowed = [g.value for g in nc.permitted_subtrees or [] if isinstance(g, x509.DNSName)]
    return all(any(n == a or n.endswith("." + a) for a in allowed) for n in names)


def _leaf_ok(path: Path, names: list[str], ips: list[str]) -> bool:
    if not path.exists():
        return False
    try:
        cert = x509.load_pem_x509_certificate(path.read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    except (ValueError, x509.ExtensionNotFound):
        return False
    have_names = set(san.get_values_for_type(x509.DNSName))
    have_ips = {str(i) for i in san.get_values_for_type(x509.IPAddress)}
    fresh = cert.not_valid_after_utc - dt.datetime.now(dt.timezone.utc) > dt.timedelta(days=30)
    return fresh and set(names) <= have_names and set(ips) <= have_ips


def _write(path: Path, data: bytes, private: bool = False) -> None:
    path.write_bytes(data)
    if private:
        os.chmod(path, 0o600)


def mobileconfig(certs: Certs, ws: WorkspaceConfig) -> bytes:
    """A configuration profile that installs the CA on the iPad (then turn it on
    in Settings → General → About → Certificate Trust Settings)."""
    ident = f"net.clockclub.margin.ca.{ws.slug}.{certs.ca_sha256[:12]}"
    return plistlib.dumps({
        "PayloadType": "Configuration", "PayloadVersion": 1,
        "PayloadIdentifier": ident, "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_URL, ident)).upper(),
        "PayloadDisplayName": f"Margin · {ws.name} previews",
        "PayloadDescription": "Lets the iPad trust HTTPS web previews from margind on your computer. "
                              "Limited to private network addresses and your own host names.",
        "PayloadContent": [{
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": ident + ".cert",
            "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_URL, ident + ".cert")).upper(),
            "PayloadDisplayName": "Margin local CA", "PayloadContent": certs.ca_der,
        }],
    })
