#!/usr/bin/env python3
"""Convert Windows .cur files to PNG + emit hotspot metadata."""
import struct, zlib, os, sys, json

def write_png(path, width, height, rgba: bytes):
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    raw = b''.join(b'\x00' + rgba[y*width*4:(y+1)*width*4] for y in range(height))
    idat = zlib.compress(raw, 9)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', idat))
        f.write(chunk(b'IEND', b''))

def parse_cur(path):
    data = open(path, 'rb').read()
    reserved, type_, count = struct.unpack_from('<HHH', data, 0)
    if type_ != 2:
        print(f"  skip {path}: not a cursor (type={type_})")
        return None

    best = None
    for i in range(count):
        base = 6 + i * 16
        w, h = data[base], data[base+1]
        w = w or 256; h = h or 256
        hotx, hoty = struct.unpack_from('<HH', data, base+4)
        size, offset = struct.unpack_from('<II', data, base+8)
        img = data[offset:offset+size]

        # PNG embedded directly
        if img[:8] == b'\x89PNG\r\n\x1a\n':
            from PIL import Image
            import io
            im = Image.open(io.BytesIO(img)).convert('RGBA')
            rgba = im.tobytes()
            entry = dict(w=im.width, h=im.height, hotx=hotx, hoty=hoty, rgba=rgba)
        else:
            # DIB
            bi_size, bi_w, bi_h, _, bpp, compr = struct.unpack_from('<IiiHHI', img, 0)
            actual_h = abs(bi_h) // 2  # biHeight is doubled (includes AND mask)
            px_off = bi_size

            if bpp == 32:
                pix = img[px_off: px_off + bi_w * actual_h * 4]
                rgba = bytearray(bi_w * actual_h * 4)
                for y in range(actual_h):
                    sy = actual_h - 1 - y  # flip vertical
                    for x in range(bi_w):
                        s = (sy * bi_w + x) * 4
                        d = (y  * bi_w + x) * 4
                        rgba[d]   = pix[s+2]  # R (from B)
                        rgba[d+1] = pix[s+1]  # G
                        rgba[d+2] = pix[s]    # B (from R)
                        rgba[d+3] = pix[s+3]  # A
                entry = dict(w=bi_w, h=actual_h, hotx=hotx, hoty=hoty, rgba=bytes(rgba))

            elif bpp == 24:
                row_stride = ((bi_w * 3 + 3) & ~3)
                pix = img[px_off: px_off + row_stride * actual_h]
                # AND mask follows XOR data
                mask_off = px_off + row_stride * actual_h
                mask_stride = ((bi_w + 31) // 32) * 4
                mask = img[mask_off: mask_off + mask_stride * actual_h]
                rgba = bytearray(bi_w * actual_h * 4)
                for y in range(actual_h):
                    sy = actual_h - 1 - y
                    for x in range(bi_w):
                        s = sy * row_stride + x * 3
                        d = (y * bi_w + x) * 4
                        rgba[d]   = pix[s+2]
                        rgba[d+1] = pix[s+1]
                        rgba[d+2] = pix[s]
                        # AND mask: 0 = opaque, 1 = transparent
                        mask_byte = mask[sy * mask_stride + x // 8]
                        bit = (mask_byte >> (7 - (x % 8))) & 1
                        rgba[d+3] = 0 if bit else 255
                entry = dict(w=bi_w, h=actual_h, hotx=hotx, hoty=hoty, rgba=bytes(rgba))

            else:
                print(f"  skip image {i} in {path}: unsupported bpp={bpp}")
                continue

        if best is None or entry['w'] >= best['w']:
            best = entry

    return best

def main():
    src = '/tmp/cursor_pack/Android-Material-Cursors-Teal'
    dst = '/Users/lemnisc8/CursorOverlay/build/CursorOverlay.app/Contents/Resources'
    os.makedirs(dst, exist_ok=True)

    manifest = {}
    for fname in sorted(os.listdir(src)):
        if not fname.endswith('.cur'):
            continue
        result = parse_cur(os.path.join(src, fname))
        if result is None:
            continue
        stem = fname[:-4]
        png_name = stem + '.png'
        write_png(os.path.join(dst, png_name), result['w'], result['h'], result['rgba'])
        manifest[stem] = {'hotx': result['hotx'], 'hoty': result['hoty'],
                          'w': result['w'], 'h': result['h']}
        print(f"  {png_name}  {result['w']}x{result['h']}  hotspot=({result['hotx']},{result['hoty']})")

    json.dump(manifest, open(os.path.join(dst, 'cursors.json'), 'w'), indent=2)
    print(f"\nWrote {len(manifest)} cursors + cursors.json to {dst}")

main()
