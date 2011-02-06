import os
import sys
import math
import subprocess
import plistlib

PRODUCT_NAME = 'Echoance'
PLIST_PATH = 'ScreenCapTheora-Info.plist'
BUNDLE_PATH = 'build/Release/%s.app' % PRODUCT_NAME
WRITABLE_DMG_PATH = '%s-writable.dmg' % PRODUCT_NAME
MOUNTED_PATH = '/Volumes/%s' % PRODUCT_NAME

def unmount():
    subprocess.check_call(["hdiutil", "detach", MOUNTED_PATH])

if __name__ == '__main__':
    plist = plistlib.readPlist(PLIST_PATH)

    if plist['CFBundleShortVersionString'] != plist['CFBundleVersion']:
        print "error, CFBundleShortVersionString != CFBundleVersion"
        print "in %s." % PLIST_PATH
        sys.exit(1)

    version = plist['CFBundleVersion']
    readonly_dmg_path = '%s-%s.dmg' % (PRODUCT_NAME, version)

    print "creating %s" % readonly_dmg_path
    
    total_size = 0
    for dirpath, dirnames, filenames in os.walk(BUNDLE_PATH):
        for filename in filenames:
            info = os.stat(os.path.join(dirpath, filename))
            total_size += info.st_size
            print "%10d %s" % (info.st_size, filename)
    print "uncompressed bundle size: %d bytes" % total_size

    # For some reason we keep getting 'No space left on device'
    # if we make the DMG exactly as big as the app bundle, so
    # we'll double the size of the DMG and assume that the
    # excess gets compressed when we convert the image at
    # the end.

    dmg_kbytes = int(math.ceil(float(total_size)/1024)) * 2
    if os.path.exists(MOUNTED_PATH):
        unmount()
    if os.path.exists(WRITABLE_DMG_PATH):
        os.remove(WRITABLE_DMG_PATH)
    subprocess.check_call([
        "hdiutil", "create", "-size", "%dk" % dmg_kbytes,
        "-fs", "HFS+", "-volname", PRODUCT_NAME,
        WRITABLE_DMG_PATH
    ])
    subprocess.check_call(["hdiutil", "attach", WRITABLE_DMG_PATH])

    subprocess.check_call(["cp", "-R", BUNDLE_PATH, MOUNTED_PATH])

    unmount()
    if os.path.exists(readonly_dmg_path):
        os.remove(readonly_dmg_path)
    subprocess.check_call([
        "hdiutil", "convert", WRITABLE_DMG_PATH,
        "-format", "UDZO", "-o", readonly_dmg_path
    ])
    os.remove(WRITABLE_DMG_PATH)

    print "done!"
