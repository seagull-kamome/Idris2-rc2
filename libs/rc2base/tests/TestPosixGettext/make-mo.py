#!/usr/bin/env python3
# Writes locale/ja/LC_MESSAGES/gettext_test.mo, the catalog TestPosixGettext reads
# (msgfmt is not needed). The .mo format: a header, the tables of the original
# and the translated strings (length, offset), then the strings, NUL-terminated.
# A plural message is its singular and plural joined by NUL; so are its forms.
import os
import struct

msgs = {
    b"": b"Content-Type: text/plain; charset=UTF-8\nPlural-Forms: nplurals=2; plural=(n != 1);\n",
    b"hello": "こんにちは".encode(),
    b"file\0files": "ファイル\0ファイルたち".encode(),
}
keys = sorted(msgs)
n = len(keys)
ids = b"".join(k + b"\0" for k in keys)
strs = b"".join(msgs[k] + b"\0" for k in keys)
orig_table = 7 * 4
trans_table = orig_table + 8 * n
ids_base = trans_table + 8 * n
strs_base = ids_base + len(ids)
out = struct.pack("<7I", 0x950412DE, 0, n, orig_table, trans_table, 0, 0)
pos = ids_base
for k in keys:
    out += struct.pack("<II", len(k), pos)
    pos += len(k) + 1
pos = strs_base
for k in keys:
    out += struct.pack("<II", len(msgs[k]), pos)
    pos += len(msgs[k]) + 1
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "locale/ja/LC_MESSAGES/gettext_test.mo"), "wb") as f:
    f.write(out + ids + strs)
