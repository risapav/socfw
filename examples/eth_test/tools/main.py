import socket

# IP tvojho PC a port, na ktorý FPGA odosiela dáta
BIND_IP = "192.168.20.234"
# Podľa tvojho kódu je dest port buď 8080 (1F90) alebo 50000
BIND_PORT = 8080

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((BIND_IP, BIND_PORT))

print(f"Pocuvam na UDP {BIND_IP}:{BIND_PORT} ...")

while True:
    data, addr = sock.recvfrom(1024) # buffer size is 1024 bytes
    print(f"Prijata sprava od {addr}:")
    print(f"Hex: {data.hex()}")
    try:
        print(f"Text: {data.decode('ascii')}")
    except:
        pass
    print("-" * 20)
