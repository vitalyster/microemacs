/* -*- c -*-
 *
 * JASSPA MicroEmacs - www.jasspa.com
 * utf8.c - UTF-8 encoding/decoding helper routines.
 *
 * Copyright (C) 2026 JASSPA (www.jasspa.com)
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 2 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 675 Mass Ave, Cambridge, MA 02139, USA.
 */
/*
 * Created:     2026
 * Synopsis:    UTF-8 encoding/decoding helper routines.
 * Description:
 *      Lines are always stored as raw bytes ('meLine.text'); when a buffer
 *      has the 'utf8' mode set those bytes are UTF-8. These two routines are
 *      the only place that turns a byte sequence into a codepoint (and back)
 *      - everything else (cursor motion, column maths, display) works in
 *      terms of them plus the meUtf8IsLead() macro in eextrn.h, so the
 *      underlying byte storage never has to change.
 */

#include "emain.h"

/*
 * meUtf8Decode
 *
 * Decode the UTF-8 sequence starting at ss[index] (the line has 'len' bytes
 * in total) into a codepoint, and return the number of bytes it occupies.
 *
 * Invalid or truncated UTF-8 is decoded as a single Latin-1 byte, so callers
 * always get a length of at least 1 and can advance safely even over data
 * that never was UTF-8.
 */
unsigned
meUtf8Decode(const meUByte *ss, int index, int len, meUInt *res)
{
    meUInt value ;
    meUByte c ;
    unsigned bytes, mask, ii ;

    c = ss[index] ;
    *res = c ;

    /* 0xxxxxxx is plain ASCII, 10xxxxxx is a continuation byte with no lead
     * - both are returned as-is, one byte long */
    if(c < 0xc0)
        return 1 ;

    /* 11xxxxxx.... - count the leading one-bits to get the sequence length */
    mask = 0x20 ;
    bytes = 2 ;
    while(c & mask)
    {
        bytes++ ;
        mask >>= 1 ;
    }
    if((bytes > 6) || ((index + (int) bytes) > len))
        return 1 ;

    value = c & (mask - 1) ;
    for(ii = 1 ; ii < bytes ; ii++)
    {
        c = ss[index+ii] ;
        if((c & 0xc0) != 0x80)
            return 1 ;
        value = (value << 6) | (c & 0x3f) ;
    }
    *res = value ;
    return bytes ;
}

/*
 * meUtf8Encode
 *
 * Encode a codepoint as the shortest UTF-8 sequence into 'buf' (which must
 * have room for at least 6 bytes) and return the number of bytes written.
 */
unsigned
meUtf8Encode(meUInt c, meUByte *buf)
{
    unsigned bytes = 1 ;

    buf[0] = (meUByte) c ;
    if(c > 0x7f)
    {
        meUInt prefix = 0x40 ;
        meUByte *a, *b ;

        b = buf ;
        do {
            *b++ = (meUByte) (0x80 + (c & 0x3f)) ;
            bytes++ ;
            prefix >>= 1 ;
            c >>= 6 ;
        } while(c >= prefix) ;
        *b = (meUByte) (c - 2*prefix) ;

        /* the bytes were generated least-significant first, put them back
         * the right way round */
        a = buf ;
        while(a < b)
        {
            meUByte t = *a ;
            *a++ = *b ;
            *b-- = t ;
        }
    }
    return bytes ;
}
