"""Report how the local VNC server offers authentication."""
import socket

s = socket.create_connection(("127.0.0.1", 5900), 5)
s.settimeout(5)
banner = s.recv(12).decode("ascii", "replace").strip()
s.sendall(b"RFB 003.008\n")
data = s.recv(64)
names = {1: "none", 2: "vnc-password", 16: "tight", 19: "veNCrypt",
         30: "apple-ard-account", 35: "apple-ard-account"}
types = list(data[1:1 + data[0]]) if data[:1] == b"\x01" else list(data)
print("banner=%s types=%s names=%s" % (banner, types, [names.get(x, x) for x in types]))
