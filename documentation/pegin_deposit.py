#!/usr/bin/env python3
"""pegin_deposit.py — build / sign / broadcast a Bifrost peg-in deposit (Bitcoin testnet4).

Pure Python stdlib (no third-party deps). Reference implementation of
documentation/bitcoin_tx_construction.md §1. Transaction layout:

    in  : your P2WPKH funding UTXO (one, auto-selected via the node)
    out0: peg-in P2TR (value = --amount sat)          # Taproot(Y_fed, refund tapleaf)
    out1: OP_RETURN "BFR" || depositor_auth_outputkey  # beacon: the depositor's key-path Taproot
                                                       #   output key = the BIP-322 completion key
    out2: P2WPKH change (omitted if below dust)

Usage:
    python3 pegin_deposit.py --wif-file karl.wif --amount 2500 --fee 1000           # build + print
    python3 pegin_deposit.py --wif-file karl.wif --amount 2500 --fee 1000 --submit  # broadcast
    python3 pegin_deposit.py --wif-file karl.wif --amount 2500 --fee 1000 --test    # testmempoolaccept
"""
import sys, json, hashlib, urllib.request, base64, argparse

# ---- bridge / network constants (this demo deployment) -----------------------
Y_FED = bytes.fromhex("0ce472ae5d8993e7609ee4ef33b344f6b8499a1259374bdf528f82240985bf03")
REFUND_TIMEOUT = 720
HRP = "tb"                          # testnet4 bech32 human-readable part
RPC_URL, RPC_USER, RPC_PASS = "http://127.0.0.1:48332", "bitcoin", "bitcoin"
DUST = 294

# ---- secp256k1 ---------------------------------------------------------------
Pp = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G  = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
      0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
def inv(a, m): return pow(a, m - 2, m)
def add(p, q):
    if p is None: return q
    if q is None: return p
    if p[0] == q[0] and (p[1] != q[1] or p[1] == 0): return None
    l = (3*p[0]*p[0]*inv(2*p[1], Pp)) % Pp if p == q else ((q[1]-p[1])*inv(q[0]-p[0], Pp)) % Pp
    x = (l*l - p[0] - q[0]) % Pp
    return (x, (l*(p[0]-x) - p[1]) % Pp)
def mul(k, p=G):
    r = None
    while k:
        if k & 1: r = add(r, p)
        p = add(p, p); k >>= 1
    return r
def lift_x(x):
    y = pow((pow(x,3,Pp)+7) % Pp, (Pp+1)//4, Pp)
    return (x, y if y % 2 == 0 else Pp - y)

# ---- hashes ------------------------------------------------------------------
def sha256(b): return hashlib.sha256(b).digest()
def hash256(b): return sha256(sha256(b))
def hash160(b): return hashlib.new("ripemd160", sha256(b)).digest()
def tagged(tag, m): t = sha256(tag.encode()); return sha256(t + t + m)

# ---- base58 (WIF decode) -----------------------------------------------------
_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def b58decode(s):
    n = 0
    for c in s: n = n*58 + _B58.index(c)
    raw = n.to_bytes((n.bit_length()+7)//8, "big")
    pad = len(s) - len(s.lstrip("1"))
    return b"\x00"*pad + raw
def wif_to_priv(wif):
    raw = b58decode(wif.strip())
    body, chk = raw[:-4], raw[-4:]
    assert hash256(body)[:4] == chk, "bad WIF checksum"
    key = body[1:]                              # drop version byte
    if len(key) == 33 and key[-1] == 1: key = key[:-1]   # drop compressed flag
    return key

def priv_to_pub_compressed(priv):
    pt = mul(int.from_bytes(priv, "big"))
    return bytes([2 + (pt[1] & 1)]) + pt[0].to_bytes(32, "big")

# ---- bech32 / bech32m (encode) ----------------------------------------------
_CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def _polymod(v):
    GEN = [0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; chk = 1
    for x in v:
        b = chk >> 25; chk = ((chk & 0x1ffffff) << 5) ^ x
        for i in range(5): chk ^= GEN[i] if (b >> i) & 1 else 0
    return chk
def _convertbits(data, f, t):
    acc = bits = 0; out = []; maxv = (1 << t) - 1
    for b in data:
        acc = (acc << f) | b; bits += f
        while bits >= t: bits -= t; out.append((acc >> bits) & maxv)
    if bits: out.append((acc << (t - bits)) & maxv)
    return out
def segwit_addr(witver, prog):
    const = 1 if witver == 0 else 0x2bc830a3
    data = [witver] + _convertbits(prog, 8, 5)
    vals = [ord(c) >> 5 for c in HRP] + [0] + [ord(c) & 31 for c in HRP] + data
    pm = _polymod(vals + [0]*6) ^ const
    chk = [(pm >> 5*(5-i)) & 31 for i in range(6)]
    return HRP + "1" + "".join(_CH[d] for d in data + chk)

# ---- ECDSA sign (RFC6979 deterministic k, low-S, DER) ------------------------
def _rfc6979_k(priv, z):
    x = priv; h = z.to_bytes(32, "big") ; xb = x
    import hmac
    v = b"\x01"*32; k = b"\x00"*32
    k = hmac.new(k, v + b"\x00" + xb + h, hashlib.sha256).digest(); v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + xb + h, hashlib.sha256).digest(); v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest(); cand = int.from_bytes(v, "big")
        if 1 <= cand < N: return cand
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest(); v = hmac.new(k, v, hashlib.sha256).digest()
def ecdsa_sign(priv, z):
    d = int.from_bytes(priv, "big")
    k = _rfc6979_k(priv, z); r = mul(k)[0] % N
    s = (inv(k, N) * (z + r*d)) % N
    if s > N//2: s = N - s
    return r, s
def _derint(x):
    b = x.to_bytes((x.bit_length()+7)//8 or 1, "big")
    if b[0] & 0x80: b = b"\x00" + b
    return b"\x02" + bytes([len(b)]) + b
def der(r, s):
    body = _derint(r) + _derint(s)
    return b"\x30" + bytes([len(body)]) + body

# ---- peg-in P2TR -------------------------------------------------------------
def _pushnum(n):                     # minimal CScriptNum push of a small positive int
    b = b""; x = n
    while x: b += bytes([x & 0xff]); x >>= 8
    if b and b[-1] & 0x80: b += b"\x00"
    return bytes([len(b)]) + b
def pegin_outputkey(xonly):
    leaf = _pushnum(REFUND_TIMEOUT) + bytes([0xb2, 0x75, 0x20]) + xonly + bytes([0xac])
    leafhash = tagged("TapLeaf", bytes([0xc0, len(leaf)]) + leaf)   # len(leaf) < 253
    t = int.from_bytes(tagged("TapTweak", Y_FED + leafhash), "big")
    Q = add(lift_x(int.from_bytes(Y_FED, "big")), mul(t))
    return Q[0].to_bytes(32, "big")
def taproot_keypath_output_key(xonly):
    # Depositor's own key-path-only Taproot output key (BIP-341 / BIP-86, empty script tree):
    #   Q = P + H_TapTweak(P)*G.  This is the key the completion's BIP-322 signature verifies
    #   against, so it (NOT the raw internal x-only) is what goes in the BFR beacon.
    t = int.from_bytes(tagged("TapTweak", xonly), "big")
    Q = add(lift_x(int.from_bytes(xonly, "big")), mul(t))
    return Q[0].to_bytes(32, "big")

# ---- tx serialization --------------------------------------------------------
def varint(n):
    if n < 0xfd: return bytes([n])
    if n <= 0xffff: return b"\xfd" + n.to_bytes(2, "little")
    return b"\xfe" + n.to_bytes(4, "little")
def ser_out(value, spk): return value.to_bytes(8, "little") + varint(len(spk)) + spk

# ---- RPC ---------------------------------------------------------------------
def rpc(method, params):
    body = json.dumps({"jsonrpc":"1.0","id":"d","method":method,"params":params}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers={"content-type":"text/plain"})
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{RPC_USER}:{RPC_PASS}".encode()).decode())
    r = json.load(urllib.request.urlopen(req, timeout=120))
    if r.get("error"): raise RuntimeError(r["error"])
    return r["result"]

# ---- build -------------------------------------------------------------------
def build(wif, amount, fee, auth_output_key=None):
    priv = wif_to_priv(wif)
    pub = priv_to_pub_compressed(priv)
    xonly = pub[1:]                                   # x-only = x coordinate
    h160 = hash160(pub)
    funding_spk = b"\x00\x14" + h160                  # P2WPKH scriptPubKey
    p2wpkh = segwit_addr(0, h160)
    okey = pegin_outputkey(xonly)
    pegin_spk = b"\x51\x20" + okey
    pegin_addr = segwit_addr(1, okey)
    # Beacon carries the BIP-322 completion key: the WIF's own key-path Taproot output key by
    # default, or --auth-output-key to authorize the mint from a DIFFERENT wallet (e.g. UniSat).
    # The refund leaf + funding stay with the WIF; only the mint authorization moves.
    if auth_output_key:
        auth_outputkey = bytes.fromhex(auth_output_key)
        if len(auth_outputkey) != 32:
            raise SystemExit("--auth-output-key must be 32 bytes (64 hex chars)")
    else:
        auth_outputkey = taproot_keypath_output_key(xonly)
    auth_addr = segwit_addr(1, auth_outputkey)           # sign the BIP-322 completion from here
    beacon_spk = b"\x6a\x23\x42\x46\x52" + auth_outputkey

    unspents = rpc("scantxoutset", ["start", [f"addr({p2wpkh})"]]).get("unspents", [])
    need = amount + fee
    pick = next((u for u in sorted(unspents, key=lambda u: u["amount"]) if round(u["amount"]*1e8) >= need), None)
    if not pick:
        have = sum(round(u["amount"]*1e8) for u in unspents)
        raise SystemExit(f"insufficient funds at {p2wpkh}: have {have} sat, need {need}")
    in_txid, in_vout, in_val = pick["txid"], pick["vout"], round(pick["amount"]*1e8)

    outs = [(amount, pegin_spk), (0, beacon_spk)]
    change = in_val - amount - fee
    if change >= DUST: outs.append((change, funding_spk))

    # --- BIP143 sighash (single P2WPKH input) ---
    outpoint = bytes.fromhex(in_txid)[::-1] + in_vout.to_bytes(4, "little")
    seq = b"\xff\xff\xff\xff"
    hashPrevouts = hash256(outpoint)
    hashSequence = hash256(seq)
    hashOutputs = hash256(b"".join(ser_out(v, s) for v, s in outs))
    scriptCode = b"\x19\x76\xa9\x14" + h160 + b"\x88\xac"
    preimage = (b"\x02\x00\x00\x00" + hashPrevouts + hashSequence + outpoint + scriptCode +
                in_val.to_bytes(8, "little") + seq + hashOutputs + b"\x00\x00\x00\x00" + b"\x01\x00\x00\x00")
    z = int.from_bytes(hash256(preimage), "big")
    r, s = ecdsa_sign(priv, z)
    sig = der(r, s) + b"\x01"                          # + SIGHASH_ALL
    witness = bytes([2, len(sig)]) + sig + bytes([len(pub)]) + pub

    raw = (b"\x02\x00\x00\x00" + b"\x00\x01" +          # version + segwit marker/flag
           varint(1) + outpoint + b"\x00" + seq +       # 1 input, empty scriptSig
           varint(len(outs)) + b"".join(ser_out(v, s) for v, s in outs) +
           witness + b"\x00\x00\x00\x00")
    return raw.hex(), pegin_addr, p2wpkh, change, auth_addr

def main():
    ap = argparse.ArgumentParser(description="Build a Bifrost peg-in deposit (testnet4).")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--wif"); g.add_argument("--wif-file")
    ap.add_argument("--amount", type=int, required=True, help="deposit sat into the peg-in P2TR")
    ap.add_argument("--fee", type=int, default=1000)
    ap.add_argument("--submit", action="store_true", help="broadcast via sendrawtransaction")
    ap.add_argument("--test", action="store_true", help="validate via testmempoolaccept (no broadcast)")
    ap.add_argument("--auth-output-key", help="32-byte hex Taproot output key for the BFR beacon "
                    "(default: derived from --wif); set to another wallet's output key (e.g. UniSat) "
                    "to authorize the BIP-322 completion from there")
    a = ap.parse_args()
    wif = a.wif if a.wif else open(a.wif_file).read().strip()
    raw, pegin_addr, p2wpkh, change, auth_addr = build(wif, a.amount, a.fee, a.auth_output_key)
    print(f"depositor P2WPKH : {p2wpkh}")
    print(f"auth P2TR (sign) : {auth_addr}")
    print(f"peg-in P2TR      : {pegin_addr}")
    print(f"deposit / fee    : {a.amount} / {a.fee} sat   change {change} sat")
    print(f"raw tx           : {raw}")
    if a.test:
        print("testmempoolaccept:", json.dumps(rpc("testmempoolaccept", [[raw]])))
    if a.submit:
        print("broadcast txid   :", rpc("sendrawtransaction", [raw]))

if __name__ == "__main__":
    main()
