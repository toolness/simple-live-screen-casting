// This file was originally taken from the Mozilla Rainbow project:
// https://github.com/mozilla/rainbow

/* Converter functions from libvidcap */
int RGB32toI420(int width, int height, const char *src, char *dst);
int BGR32toI420(int width, int height, const char *src, char *dst);
int I420toRGB32(int width, int height, const char *src, char *dst);

