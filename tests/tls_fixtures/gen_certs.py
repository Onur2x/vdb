#!/usr/bin/env python3
"""VDB TLS test fiksturu ureticisi.

Uretilen dosyalar YALNIZ test icindir; ozel anahtarlar bilincli olarak
depoda tutulur ve baska hicbir yerde kullanilmamalidir.

  ca.crt / ca.key            - test kok sertifikasi (CA:TRUE)
  server.crt / server.key    - SAN: DNS:localhost, IP:127.0.0.1
  wrong_ca.crt / wrong_ca.key- farkli bir CA (dogrulama reddi testi icin)
  other.crt / other.key      - SAN: DNS:example.invalid (hostname uyusmazligi)

Kullanim:  python gen_certs.py
"""
import datetime as dt
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

HERE = os.path.dirname(os.path.abspath(__file__))
NOT_BEFORE = dt.datetime(2025, 1, 1, tzinfo=dt.timezone.utc)
NOT_AFTER = dt.datetime(2035, 1, 1, tzinfo=dt.timezone.utc)


def new_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def write_key(path, key):
    data = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )
    with open(path, "wb") as f:
        f.write(data)


def write_cert(path, cert):
    with open(path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


def ca_cert(cn):
    key = new_key()
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOT_BEFORE)
        .not_valid_after(NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    return key, cert


def leaf_cert(cn, ca_key, ca, sans):
    key = new_key()
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)]))
        .issuer_name(ca.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOT_BEFORE)
        .not_valid_after(NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=True,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.SubjectAlternativeName(sans), critical=False)
    )
    return key, builder.sign(ca_key, hashes.SHA256())


def main():
    ca_key, ca = ca_cert("VDB Test CA")
    write_key(os.path.join(HERE, "ca.key"), ca_key)
    write_cert(os.path.join(HERE, "ca.crt"), ca)

    wkey, wca = ca_cert("VDB Wrong CA")
    write_key(os.path.join(HERE, "wrong_ca.key"), wkey)
    write_cert(os.path.join(HERE, "wrong_ca.crt"), wca)

    skey, scert = leaf_cert(
        "localhost",
        ca_key,
        ca,
        [
            x509.DNSName("localhost"),
            x509.IPAddress(__import__("ipaddress").ip_address("127.0.0.1")),
        ],
    )
    write_key(os.path.join(HERE, "server.key"), skey)
    write_cert(os.path.join(HERE, "server.crt"), scert)

    okey, ocert = leaf_cert(
        "example.invalid",
        ca_key,
        ca,
        [x509.DNSName("example.invalid")],
    )
    write_key(os.path.join(HERE, "other.key"), okey)
    write_cert(os.path.join(HERE, "other.crt"), ocert)

    print("OK: ca.crt ca.key wrong_ca.crt wrong_ca.key server.crt server.key other.crt other.key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
