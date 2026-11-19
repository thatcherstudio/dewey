"""macOS only: what `shutil.copy2` leaves behind when a file is copied to another disk.

copy2 brings the bytes, the mode, the modified time and the flags. Finder tags, "where from" and
the quarantine mark (extended attributes), the ACL and the creation date need copyfile(3) and
setattrlist(2). Python doesn't wrap those, so they are called through ctypes.
"""
from __future__ import annotations

import ctypes
import os
import sys

COPYFILE_ACL, COPYFILE_XATTR = 1 << 0, 1 << 2
COPYFILE_NOFOLLOW = (1 << 18) | (1 << 19)  # neither end is a symlink we'd want to follow
ATTR_BIT_MAP_COUNT = 5
ATTR_CMN_CRTIME = 0x00000200
FSOPT_NOFOLLOW = 0x00000001


class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16),
                ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32),
                ("fileattr", ctypes.c_uint32), ("forkattr", ctypes.c_uint32)]


class _Timespec(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_nsec", ctypes.c_long)]


class _CreatedReply(ctypes.Structure):  # getattrlist's answer: its length, then the one attribute asked for
    _pack_ = 4
    _fields_ = [("length", ctypes.c_uint32), ("created", _Timespec)]


_libc = None


def _lib():
    global _libc
    if _libc is None:
        lib = ctypes.CDLL(None, use_errno=True)
        lib.copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
        lib.copyfile.restype = ctypes.c_int
        for fn in (lib.getattrlist, lib.setattrlist):
            fn.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong]
            fn.restype = ctypes.c_int
        _libc = lib
    return _libc


def _check(rc: int, path) -> None:
    if rc != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), os.fspath(path))


def created_ns(path) -> int:
    """The creation date in nanoseconds (os.stat only has it as a float, which rounds it)."""
    want = _AttrList(ATTR_BIT_MAP_COUNT, 0, ATTR_CMN_CRTIME, 0, 0, 0, 0)
    reply = _CreatedReply()
    _check(_lib().getattrlist(os.fsencode(path), ctypes.byref(want), ctypes.byref(reply),
                              ctypes.sizeof(reply), FSOPT_NOFOLLOW), path)
    return reply.created.tv_sec * 10**9 + reply.created.tv_nsec


def set_created_ns(path, ns: int) -> None:
    what = _AttrList(ATTR_BIT_MAP_COUNT, 0, ATTR_CMN_CRTIME, 0, 0, 0, 0)
    when = _Timespec(ns // 10**9, ns % 10**9)
    _check(_lib().setattrlist(os.fsencode(path), ctypes.byref(what), ctypes.byref(when),
                              ctypes.sizeof(when), FSOPT_NOFOLLOW), path)


def keep_metadata(src, dst) -> list[str]:
    """Give `dst` (a copy2 of `src`) the extended attributes, ACL and creation date of `src`.

    Best effort: the bytes are what a move must not lose, and some disks (FAT, network shares) can't
    hold all of this. Returns what couldn't be kept, [] when everything was (or off macOS, where
    copy2 already does what the system allows).
    """
    if sys.platform != "darwin":
        return []
    lost = []
    try:
        _check(_lib().copyfile(os.fsencode(src), os.fsencode(dst), None,
                               COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW), dst)
    except (OSError, AttributeError):
        lost.append("tags and other extended attributes")
    try:  # last: setting an earlier modified time (copy2 did) pulls the creation date along with it
        set_created_ns(dst, created_ns(src))
    except (OSError, AttributeError):
        lost.append("creation date")
    return lost
