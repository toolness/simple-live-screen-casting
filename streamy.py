import socket
import base64
import time

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('ethervm', 8000))
s.send('SOURCE /screencap.ogg HTTP/1.0\r\n')
s.send('Authorization: Basic %s\r\n' % base64.b64encode('source:o'))
s.send('Content-Type: application/ogg\r\n')
s.send('\r\n')

pos = 0

while 1:
    f = open('screencap.ogv', 'rb')
    f.seek(pos)
    data = f.read(65536)
    f.close()
    pos += len(data)
    if data != '':
        print "sending %d bytes" % len(data)
        s.send(data)
    else:
        print "waiting for more."
        time.sleep(0.5)
