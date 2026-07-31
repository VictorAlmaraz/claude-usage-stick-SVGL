#!/usr/bin/env python3
"""
grab_screen.py — baixa o framebuffer do device e salva um PNG 480x320.

Ao contrario de gen_mockups.py (que DESENHA aproximacoes das telas com outra
fonte), aqui os pixels sao os reais: Montserrat do LVGL, antialiasing e cores
exatas. Um mockup diverge do firmware em silencio; um screenshot nao tem como.

Uso:
    python3 tools/grab_screen.py assets/screen-sessoes.png
    python3 tools/grab_screen.py --host 192.168.1.50 out.png

Sem dependencias: PNG escrito com zlib/struct da stdlib.
"""
import argparse
import struct
import subprocess
import sys
import urllib.request
import zlib

CANVAS_W, CANVAS_H = 320, 480          # canvas retrato; a UI e desenhada girada
OUT_W, OUT_H = CANVAS_H, CANVAS_W      # 480x320


def resolve_mdns(name):
    """Mesma tecnica do stick-notify.sh: o getaddrinfo do macOS leva ~2.8s para
    resolver .local; o ping resolve em ~80ms falando direto com o mDNSResponder."""
    try:
        out = subprocess.run(["ping", "-c", "1", "-t", "1", "-W", "1000", name],
                             capture_output=True, text=True, timeout=3).stdout
        return out.split("(", 1)[1].split(")", 1)[0]
    except Exception:
        return None


def fetch(host, timeout):
    with urllib.request.urlopen(f"http://{host}/screenshot", timeout=timeout) as r:
        data = r.read()
    want = CANVAS_W * CANVAS_H * 2
    if len(data) != want:
        sys.exit(f"framebuffer truncado: {len(data)} bytes, esperado {want}")
    return data


def to_rows(data, swap):
    """RGB565 -> linhas RGB888, desfazendo a rotacao do disp_flush_cb.

    O firmware grava canvas_fb[(479 - lx) * 320 + ly] = lvgl[ly][lx], entao o
    inverso e ler o pixel de saida (x, y) do indice (479 - x) * 320 + y.
    """
    px = struct.unpack(f"{'>' if swap else '<'}{CANVAS_W * CANVAS_H}H", data)
    # tabelas de expansao 5/6 bits -> 8 bits (evita recalcular 153k vezes)
    t5 = [(i * 255 + 15) // 31 for i in range(32)]
    t6 = [(i * 255 + 31) // 63 for i in range(64)]
    rows = []
    for y in range(OUT_H):
        row = bytearray(OUT_W * 3)
        for x in range(OUT_W):
            v = px[(479 - x) * CANVAS_W + y]
            o = x * 3
            row[o]     = t5[(v >> 11) & 0x1F]
            row[o + 1] = t6[(v >> 5) & 0x3F]
            row[o + 2] = t5[v & 0x1F]
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", OUT_W, OUT_H, 8, 2, 0, 0, 0)   # 8 bits, truecolor
    raw = b"".join(b"\x00" + r for r in rows)                     # filtro 0 por linha
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", help="arquivo PNG de saida")
    ap.add_argument("--host", default=None, help="IP ou nome (padrao: descobre claude-stick.local)")
    ap.add_argument("--swap", action="store_true", help="inverte a ordem dos bytes RGB565")
    ap.add_argument("--timeout", type=float, default=20.0)
    a = ap.parse_args()

    host = a.host or resolve_mdns("claude-stick.local")
    if not host:
        sys.exit("device nao encontrado na rede; passe --host <ip>")

    rows = to_rows(fetch(host, a.timeout), a.swap)
    write_png(a.out, rows)
    r, g, b = rows[2][6], rows[2][7], rows[2][8]
    print(f"{a.out}  {OUT_W}x{OUT_H}  (de {host})")
    print(f"  fundo amostrado: #{r:02X}{g:02X}{b:02X}  (esperado ~#0F0F12; se vier "
          f"estranho, tente --swap)")


if __name__ == "__main__":
    main()
