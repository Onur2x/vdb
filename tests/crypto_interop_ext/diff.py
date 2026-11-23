# v3.72 / SKILL6 08 (B) - bagimsiz kriptografi referansi (Python stdlib).
#
# Bu betik VDB'nin uretim koduna BAGLI DEGILDIR ve depo disinda yasar.
# hashlib/hmac (OpenSSL tabanli) SHA-256, HMAC-SHA-256 ve PBKDF2-HMAC-SHA256
# icin BAGIMSIZ referans uretir. Ayni kaynaktan kopyalanmis iki test
# bagimsiz dogrulama sayilmaz; bu yuzden beklenen degerler burada, motorun
# disinda hesaplanir.
#
# Kullanim:
#   python diff.py selftest        -> "OK hashlib" / "OK hashlib gcm"
#   python diff.py req.txt out.txt -> her satir icin "<spec> | <hex>"
#
# SKILL16-B: GCM spec turu eklendi. AES-256-GCM ct+tag degerleri Python
# `cryptography` (OpenSSL tabanli, BAGIMSIZ) ile hesaplanir; VDB'nin
# VDbCryptGcmSeal ciktisi bayt bayt karsilastirilir. cryptography yoksa
# GCM satirlari "NO-CRYPTO" doner ve kapi bunlari SKIP olarak isaretler.
import sys
import hashlib
import hmac

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    HAVE_GCM = True
except Exception:  # noqa: BLE001 - opsiyonel dogrulama araci
    AESGCM = None
    HAVE_GCM = False

SKIP = 77


def gen(tok, n):
    n = int(n)
    if tok == "P":
        return bytes(((i * 37 + 11) & 255) for i in range(n))
    if tok == "A":
        return b"a" * n
    raise ValueError("bilinmeyen uretici: " + tok)


def solve(spec):
    t = spec.split()
    kind = t[0]
    if kind == "SHA":
        return hashlib.sha256(gen(t[1], t[2])).hexdigest()
    if kind == "HMAC":
        key = gen(t[1], t[2])
        msg = gen(t[3], t[4])
        return hmac.new(key, msg, hashlib.sha256).hexdigest()
    if kind == "PBKDF2":
        pw = gen(t[1], t[2])
        salt = gen(t[3], t[4])
        it = int(t[5])
        dk = int(t[6])
        return hashlib.pbkdf2_hmac("sha256", pw, salt, it, dk).hex()
    if kind == "GCM":
        if not HAVE_GCM:
            return "NO-CRYPTO"
        key = gen(t[1], t[2])
        nonce = gen(t[3], t[4])
        aad = gen(t[5], t[6])
        pt = gen(t[7], t[8])
        return AESGCM(key).encrypt(nonce, pt, aad).hex()
    raise ValueError("bilinmeyen tur: " + kind)


def main(argv):
    if len(argv) < 2:
        sys.stdout.write("kullanim hatasi\n")
        return 2
    mode = argv[1]
    if mode == "selftest":
        # hashlib/hmac gercekten calisiyor mu? (bos + 1 bayt)
        if hashlib.sha256(b"").hexdigest() != (
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ):
            sys.stdout.write("HASHLIB BOZUK\n")
            return 2
        sys.stdout.write("OK hashlib" + (" gcm" if HAVE_GCM else "") + "\n")
        return 0
    out = []
    if len(argv) != 3:
        sys.stdout.write("kullanim hatasi\n")
        return 2
    with open(mode, "r", encoding="ascii") as f:
        for line in f:
            spec = line.strip()
            if not spec:
                continue
            out.append(spec + " | " + solve(spec))
    with open(argv[2], "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    sys.stdout.write("OK %d\n" % len(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001 - kapiya neden bildir
        sys.stdout.write("HATA %s\n" % exc)
        sys.exit(2)
