import sys, struct
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
data = data + b'\x00' * (65536 - len(data))
with open(dst, 'w') as f:
    for i in range(0, 65536, 4):
        word = struct.unpack('<I', data[i:i+4])[0]
        f.write(f'{word:08x}\n')
print(f'boot_rom.hex written: {len(data)//1024} KB')
