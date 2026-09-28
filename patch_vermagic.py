import sys
p = sys.argv[1]
d = bytearray(open(p,'rb').read())
i = d.find(b'vermagic=')
if i < 0:
    print('vermagic not found'); sys.exit(1)
j = d.find(b'\x00', i)
orig = bytes(d[i+9:j]).decode()
new = b'6.18.18.c951-trim SMP mod_unload aarch64'
print('原 vermagic:', orig, '(%d 字节)' % len(orig))
print('新 vermagic:', new.decode(), '(%d 字节)' % len(new))
if len(new) > (j - i - 9):
    print('新值更长，用覆盖+空格填充策略')
    # 找下一个可用的 0 区域：把整个字段重写
    d[i+9:j] = new[:j-i-9]
    print('!! 被截断，需要更长空间')
else:
    d[i+9:i+9+len(new)] = new
    # 剩余部分填 0
    for k in range(i+9+len(new), j):
        d[k] = 0
    print('改写完成')
open(p,'wb').write(d)
