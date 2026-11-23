#!/usr/bin/env python3
# Taps Left Shift through uinput every 20 s so the screen stays on.
import fcntl, os, struct, time
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE = 0x405c5503, 0x5501
EV_SYN, EV_KEY, KEY_LEFTSHIFT = 0, 1, 42
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_KEYBIT, KEY_LEFTSHIFT)
fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 3, 1, 1, 1, b"bench-keepawake", 0))
fcntl.ioctl(fd, UI_DEV_CREATE)
def ev(t, c, v):
    os.write(fd, struct.pack("llHHi", 0, 0, t, c, v))
time.sleep(1)
while True:
    for v in (1, 0):
        ev(EV_KEY, KEY_LEFTSHIFT, v); ev(EV_SYN, 0, 0)
    time.sleep(20)
