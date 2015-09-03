//
//  idn_defines.h
//  Quickblox
//
//  Created by Anton Sokolchenko on 9/2/15.
//  Copyright © 2015 QuickBlox. All rights reserved.
//

#ifndef idn_defines_h
#define idn_defines_h

#define gboolean int
#define gchar char
#define guchar unsigned char
#define glong long
#define gint int
#define guint unsigned int
#define gushort unsigned short
#define gint16 int16_t
#define guint16 uint16_t
#define gunichar uint32_t
#define gsize size_t
#define gssize ssize_t
#define g_malloc malloc
#define g_free free
#define g_return_val_if_fail(expr, val)                                        \
  {                                                                            \
    if (!(expr))                                                               \
      return (val);                                                            \
  }
#ifndef FALSE
#define FALSE (0)
#endif

#ifndef TRUE
#define TRUE (!FALSE)
#endif

#define G_N_ELEMENTS(arr) (sizeof(arr) / sizeof((arr)[0]))

#define G_UNLIKELY(expr) (expr)
#define UTF8_COMPUTE(Char, Mask, Len)                                          \
  if (Char < 128) {                                                            \
    Len = 1;                                                                   \
    Mask = 0x7f;                                                               \
  } else if ((Char & 0xe0) == 0xc0) {                                          \
    Len = 2;                                                                   \
    Mask = 0x1f;                                                               \
  } else if ((Char & 0xf0) == 0xe0) {                                          \
    Len = 3;                                                                   \
    Mask = 0x0f;                                                               \
  } else if ((Char & 0xf8) == 0xf0) {                                          \
    Len = 4;                                                                   \
    Mask = 0x07;                                                               \
  } else if ((Char & 0xfc) == 0xf8) {                                          \
    Len = 5;                                                                   \
    Mask = 0x03;                                                               \
  } else if ((Char & 0xfe) == 0xfc) {                                          \
    Len = 6;                                                                   \
    Mask = 0x01;                                                               \
  } else                                                                       \
    Len = -1;

#define UTF8_LENGTH(Char)                                                      \
  ((Char) < 0x80                                                               \
       ? 1                                                                     \
       : ((Char) < 0x800 ? 2 : ((Char) < 0x10000                               \
                                    ? 3                                        \
                                    : ((Char) < 0x200000                       \
                                           ? 4                                 \
                                           : ((Char) < 0x4000000 ? 5 : 6)))))

#define UTF8_GET(Result, Chars, Count, Mask, Len)                              \
  (Result) = (Chars)[0] & (Mask);                                              \
  for ((Count) = 1; (Count) < (Len); ++(Count)) {                              \
    if (((Chars)[(Count)] & 0xc0) != 0x80) {                                   \
      (Result) = -1;                                                           \
      break;                                                                   \
    }                                                                          \
    (Result) <<= 6;                                                            \
    (Result) |= ((Chars)[(Count)] & 0x3f);                                     \
  }
#define SBase 0xAC00
#define LBase 0x1100
#define VBase 0x1161
#define TBase 0x11A7
#define LCount 19
#define VCount 21
#define TCount 28
#define NCount (VCount * TCount)
#define SCount (LCount * NCount)

#endif /* idn_defines_h */
