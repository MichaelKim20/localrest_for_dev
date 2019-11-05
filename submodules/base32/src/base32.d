// Written in the D programming language.

/**
 * _Base32 encoder and decoder, according to
 * $(LINK2 http://tools.ietf.org/html/rfc4648, RFC 4648).
 *
 * Example:
 * -----
 * ubyte[] data = [0xde, 0xad, 0xbe, 0xef, 0x01, 0x23];
 *
 * const(char)[] encoded = Base32.encode(data);
 * assert(encoded == "32W353YBEM======");
 *
 * ubyte[] decoded = Base32.decode("32W353YBEM======");
 * assert(decoded == [0xde, 0xad, 0xbe, 0xef, 0x01, 0x23]);
 * -----
 *
 * Copyright: Copyright Kazuya Takahashi 2015.
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Kazuya Takahashi
 * Standards: $(LINK2 http://tools.ietf.org/html/rfc4648,
 *            RFC 4648 - The Base16, _Base32, and Base64 Data Encodings)
 */
module base32;


import std.typecons : Flag;


///
alias UseHex = Flag!"base32hex";
///
alias UsePad = Flag!"base32pad";


/**
 * The standard _base32 encoding, containing A-Z, 2-7 and =.
 */
alias Base32 = Base32Impl!();


/**
 * The _base32 encoding with "extended hex alphabet", also known as "base32hex",
 * containing 0-9, A-V, and =.
 */
alias Base32Hex = Base32Impl!(UseHex.yes);


/**
 * Implementation for _base32.
 */
template Base32Impl(UseHex useHex = UseHex.no, UsePad usePad= UsePad.yes)
{
    // For all
    import std.range.primitives;
    import std.traits;

    private immutable char pad = '=';


    // For encoding
    static if (useHex)
    {
        // convert to 0123456789ABCDEFGHIJKLMNOPQRSTUV
        private @safe pure nothrow char encodingMap(ubyte a)
        in
        {
            assert(0 <= a && a <= 31);
        }
        body
        {
            if (0 <= a && a <= 9)
            {
                return cast(char)(a + '0');
            }
            else
            {
                return cast(char)(a - 10 + 'A');
            }
        }
    }
    else
    {
        // convert to ABCDEFGHIJKLMNOPQRSTUVWXYZ234567
        private @safe pure nothrow char encodingMap(ubyte a)
        in
        {
            assert(0 <= a && a <= 31);
        }
        body
        {
            if (0 <= a && a <= 25)
            {
                return cast(char)(a + 'A');
            }
            else
            {
                return cast(char)(a - 26 + '2');
            }
        }
    }


    private enum size_t encSourceChunkLength = 5;
    private enum size_t encResultChunkLength = 8;
    private immutable size_t[5] shortfallToMeaningfulLength = [8, 7, 5, 4, 2];


    /**
     * Calculates the length for encoding.
     *
     * Params:
     *  sourceLength = The length of a source.
     *
     * Returns:
     *  The resulting length after a source with $(D_PARAM sourceLength) is
     *  encoded.
     */
    @safe pure nothrow
    size_t encodeLength(in size_t sourceLength)
    {
        static if (usePad)
        {
            return (sourceLength / 5 + (sourceLength % 5 ? 1 : 0)) * 8;
        }
        else
        {
            immutable remainLength = sourceLength % encSourceChunkLength;

            if (remainLength)
            {
                immutable sourceShortfallLength = encSourceChunkLength - remainLength;
                immutable meaningfulLength = shortfallToMeaningfulLength[sourceShortfallLength];
                immutable padLength = encResultChunkLength - meaningfulLength;

                return (sourceLength / 5 + (sourceLength % 5 ? 1 : 0)) * 8 - padLength;
            }
            else
            {
                return (sourceLength / 5 + (sourceLength % 5 ? 1 : 0)) * 8;
            }
        }
    }


    // ubyte[] to char[]

    /**
     * Encodes $(D_PARAM source) and stores the result in $(D_PARAM buffer).
     * If no _buffer is assigned, a new buffer will be created.
     *
     * Params:
     *  source = An array to _encode.
     *  buffer = An array to store the encoded result.
     *
     * Returns:
     *  The slice of $(D_PARAM buffer) containing the result.
     */
    @trusted pure
    char[] encode(UB : ubyte, C = char)(in UB[] source, C[] buffer = null)
        if (is(C == char))
    in
    {
        assert(!buffer.ptr || buffer.length >= encodeLength(source.length),
            "Insufficient buffer for encoding");
    }
    out(result)
    {
        assert(result.length == encodeLength(source.length),
            "The length of result is different from Base32");
    }
    body
    {
        immutable srcLen = source.length;
        if (srcLen == 0)
        {
            return [];
        }

        if (!buffer.ptr)
        {
            buffer = new char[encodeLength(srcLen)];
        }

        auto bufPtr = buffer.ptr;
        auto srcPtr = source.ptr;

        foreach (_; 0 .. srcLen / encSourceChunkLength)
        {
            *bufPtr++ = encodingMap(*srcPtr >>> 3 & 0x1f);
            *bufPtr++ = encodingMap((*srcPtr << 2 | *++srcPtr >>> 6) & 0x1f);
            *bufPtr++ = encodingMap(*srcPtr >>> 1 & 0x1f);
            *bufPtr++ = encodingMap((*srcPtr << 4 | *++srcPtr >>> 4) & 0x1f);
            *bufPtr++ = encodingMap((*srcPtr << 1 | *++srcPtr >>> 7) & 0x1f);
            *bufPtr++ = encodingMap(*srcPtr >>> 2 & 0x1f);
            *bufPtr++ = encodingMap((*srcPtr << 3 | *++srcPtr >>> 5) & 0x1f);
            *bufPtr++ = encodingMap(*srcPtr & 0x1f);

            srcPtr++;
        }

        immutable remainLength = srcLen % encSourceChunkLength;

        if (remainLength != 0)
        {
            immutable sourceShortfallLength = encSourceChunkLength - remainLength;
            immutable meaningfulLength = shortfallToMeaningfulLength[sourceShortfallLength];
            immutable padLength = encResultChunkLength - meaningfulLength;

            if (meaningfulLength >= 2)
            {
                immutable a = *srcPtr;
                immutable b = meaningfulLength == 2 ? 0 : *++srcPtr;

                *bufPtr++ = encodingMap(a >>> 3 & 0x1f);
                *bufPtr++ = encodingMap((a << 2 | b >>> 6) & 0x1f);
            }
            if (meaningfulLength >= 4)
            {
                immutable b = *srcPtr;
                immutable c = meaningfulLength == 4 ? 0 : *++srcPtr;

                *bufPtr++ = encodingMap(b >>> 1 & 0x1f);
                *bufPtr++ = encodingMap((b << 4 | c >>> 4) & 0x1f);
            }
            if (meaningfulLength >= 5)
            {
                immutable c = *srcPtr;
                immutable d = meaningfulLength == 5 ? 0 : *++srcPtr;

                *bufPtr++ = encodingMap((c << 1 | d >>> 7) & 0x1f);
            }
            if (meaningfulLength == 7)
            {
                immutable d = *srcPtr;

                *bufPtr++ = encodingMap(d >>> 2 & 0x1f);
                *bufPtr++ = encodingMap(d << 3 & 0x1f);
            }

            static if (usePad)
            {
                buffer[bufPtr - buffer.ptr .. bufPtr - buffer.ptr + padLength] = pad;
                bufPtr += padLength;
            }
        }

        return buffer[0 .. bufPtr - buffer.ptr];
    }


    // InputRange to char[]

    /**
     * Encodes $(D_PARAM source) and stores the result in $(D_PARAM buffer).
     * If no _buffer is assigned, a new buffer will be created.
     *
     * Params:
     *  source = An InputRange to _encode.
     *  buffer = An array to store the encoded result.
     *
     * Returns:
     *  The slice of $(D_PARAM buffer) containing the result.
     */
    char[] encode(UBR, C = char)(UBR source, C[] buffer = null)
        if (!isArray!UBR && isInputRange!UBR && is(ElementType!UBR : ubyte)
            && hasLength!UBR && is(C == char))
    in
    {
        assert(!buffer.ptr || buffer.length >= encodeLength(source.length),
            "Insufficient buffer for encoding");
    }
    out(result)
    {
        // delegate to the proxies
    }
    body
    {
        immutable srcLen = source.length;
        if (srcLen == 0)
        {
            // proxy out contract
            assert(0 == encodeLength(srcLen),
                "The length of result is different from Base32");

            return [];
        }

        if (!buffer.ptr)
        {
            buffer = new char[encodeLength(srcLen)];
        }

        auto bufPtr = buffer.ptr;

        foreach (_; 0 .. srcLen / encSourceChunkLength)
        {
            immutable a = source.front;
            source.popFront();
            immutable b = source.front;
            source.popFront();
            immutable c = source.front;
            source.popFront();
            immutable d = source.front;
            source.popFront();
            immutable e = source.front;
            source.popFront();

            *bufPtr++ = encodingMap(a >>> 3);
            *bufPtr++ = encodingMap((a << 2 | b >>> 6) & 0x1f);
            *bufPtr++ = encodingMap(b >>> 1 & 0x1f);
            *bufPtr++ = encodingMap((b << 4 | c >>> 4) & 0x1f);
            *bufPtr++ = encodingMap((c << 1 | d >>> 7) & 0x1f);
            *bufPtr++ = encodingMap(d >>> 2 & 0x1f);
            *bufPtr++ = encodingMap((d << 3 | e >>> 5) & 0x1f);
            *bufPtr++ = encodingMap(e & 0x1f);
        }

        immutable remainLength = srcLen % encSourceChunkLength;

        if (remainLength != 0)
        {
            immutable sourceShortfallLength = encSourceChunkLength - remainLength;
            immutable meaningfulLength = shortfallToMeaningfulLength[sourceShortfallLength];
            immutable padLength = encResultChunkLength - meaningfulLength;

            if (meaningfulLength >= 2)
            {
                immutable a = source.front;
                source.popFront();
                immutable b = source.empty ? 0 : source.front;

                *bufPtr++ = encodingMap(a >>> 3);
                *bufPtr++ = encodingMap((a << 2 | b >>> 6) & 0x1f);
            }
            if (meaningfulLength >= 4)
            {
                immutable b = source.front;
                source.popFront();
                immutable c = source.empty ? 0 : source.front;

                *bufPtr++ = encodingMap(b >>> 1 & 0x1f);
                *bufPtr++ = encodingMap((b << 4 | c >>> 4) & 0x1f);
            }
            if (meaningfulLength >= 5)
            {
                immutable c = source.front;
                source.popFront();
                immutable d = source.empty ? 0 : source.front;

                *bufPtr++ = encodingMap((c << 1 | d >>> 7) & 0x1f);
            }
            if (meaningfulLength == 7)
            {
                immutable d = source.front;
                source.popFront();
                assert(source.empty);

                *bufPtr++ = encodingMap(d >>> 2 & 0x1f);
                *bufPtr++ = encodingMap(d << 3 & 0x1f);
            }

            static if (usePad)
            {
                buffer[bufPtr - buffer.ptr .. bufPtr - buffer.ptr + padLength] = pad;
                bufPtr += padLength;
            }
        }

        // proxy out contract
        assert(bufPtr - buffer.ptr == encodeLength(srcLen),
            "The length of result is different from Base32");

        return buffer[0 .. bufPtr - buffer.ptr];
    }


    // ubyte[] to OutputRange

    /**
     * Encodes $(D_PARAM source) and outputs the result to $(D_PARAM range).
     *
     * Params:
     *  source = An array to _encode.
     *  range  = An OutputRange to receive the encoded result.
     *
     * Returns:
     *  The length of the output characters.
     */
    size_t encode(UB : ubyte, CR)(in UB[] source, CR range)
        if (isOutputRange!(CR, char))
    out(result)
    {
        assert(result == encodeLength(source.length),
            "The number of put is different from the length of Base32");
    }
    body
    {
        immutable srcLen = source.length;
        if (srcLen == 0)
        {
            return 0;
        }

        size_t putCnt;
        auto srcPtr = source.ptr;

        foreach (_; 0 .. srcLen / encSourceChunkLength)
        {
            range.put(encodingMap(*srcPtr >>> 3 & 0x1f));
            range.put(encodingMap((*srcPtr << 2 | *++srcPtr >>> 6) & 0x1f));
            range.put(encodingMap(*srcPtr >>> 1 & 0x1f));
            range.put(encodingMap((*srcPtr << 4 | *++srcPtr >>> 4) & 0x1f));
            range.put(encodingMap((*srcPtr << 1 | *++srcPtr >>> 7) & 0x1f));
            range.put(encodingMap(*srcPtr >>> 2 & 0x1f));
            range.put(encodingMap((*srcPtr << 3 | *++srcPtr >>> 5) & 0x1f));
            range.put(encodingMap(*srcPtr & 0x1f));

            putCnt += 8;
            srcPtr++;
        }

        immutable remainLength = srcLen % encSourceChunkLength;

        if (remainLength != 0)
        {
            immutable sourceShortfallLength = encSourceChunkLength - remainLength;
            immutable meaningfulLength = shortfallToMeaningfulLength[sourceShortfallLength];
            immutable padLength = encResultChunkLength - meaningfulLength;

            if (meaningfulLength >= 2)
            {
                immutable a = *srcPtr;
                immutable b = meaningfulLength == 2 ? 0 : *++srcPtr;

                range.put(encodingMap(a >>> 3 & 0x1f));
                range.put(encodingMap((a << 2 | b >>> 6) & 0x1f));

                putCnt += 2;
            }
            if (meaningfulLength >= 4)
            {
                immutable b = *srcPtr;
                immutable c = meaningfulLength == 4 ? 0 : *++srcPtr;

                range.put(encodingMap(b >>> 1 & 0x1f));
                range.put(encodingMap((b << 4 | c >>> 4) & 0x1f));

                putCnt += 2;
            }
            if (meaningfulLength >= 5)
            {
                immutable c = *srcPtr;
                immutable d = meaningfulLength == 5 ? 0 : *++srcPtr;

                range.put(encodingMap((c << 1 | d >>> 7) & 0x1f));

                putCnt++;
            }
            if (meaningfulLength == 7)
            {
                immutable d = *srcPtr;

                range.put(encodingMap(d >>> 2 & 0x1f));
                range.put(encodingMap(d << 3 & 0x1f));

                putCnt += 2;
            }

            static if (usePad)
            {
                foreach (_; 0 .. padLength)
                {
                    range.put(pad);
                }
                putCnt += padLength;
            }
        }

        return putCnt;
    }


    // InputRange to OutputRange

    /**
     * Encodes $(D_PARAM source) and outputs the result to $(D_PARAM range).
     *
     * Params:
     *  source = An InputRange to _encode.
     *  range  = An OutputRange to receive the encoded result.
     *
     * Returns:
     *  The length of the output characters.
     */
    size_t encode(UBR, CR)(UBR source, CR range)
        if (!isArray!UBR && isInputRange!UBR && is(ElementType!UBR : ubyte)
            && hasLength!UBR && isOutputRange!(CR, char))
    out(result)
    {
        // delegate to the proxies
    }
    body
    {
        immutable srcLen = source.length;
        if (srcLen == 0)
        {
            // proxy out contract
            assert(0 == encodeLength(srcLen),
                "The number of put is different from the length of Base32");

            return 0;
        }

        size_t putCnt;

        foreach (_; 0 .. srcLen / encSourceChunkLength)
        {
            immutable a = source.front;
            source.popFront();
            immutable b = source.front;
            source.popFront();
            immutable c = source.front;
            source.popFront();
            immutable d = source.front;
            source.popFront();
            immutable e = source.front;
            source.popFront();

            range.put(encodingMap(a >>> 3));
            range.put(encodingMap((a << 2 | b >>> 6) & 0x1f));
            range.put(encodingMap(b >>> 1 & 0x1f));
            range.put(encodingMap((b << 4 | c >>> 4) & 0x1f));
            range.put(encodingMap((c << 1 | d >>> 7) & 0x1f));
            range.put(encodingMap(d >>> 2 & 0x1f));
            range.put(encodingMap((d << 3 | e >>> 5) & 0x1f));
            range.put(encodingMap(e & 0x1f));

            putCnt += 8;
        }

        immutable remainLength = srcLen % encSourceChunkLength;

        if (remainLength != 0)
        {
            immutable sourceShortfallLength = encSourceChunkLength - remainLength;
            immutable meaningfulLength = shortfallToMeaningfulLength[sourceShortfallLength];
            immutable padLength = encResultChunkLength - meaningfulLength;

            if (meaningfulLength >= 2)
            {
                immutable a = source.front;
                source.popFront();
                immutable b = source.empty ? 0 : source.front;

                range.put(encodingMap(a >>> 3));
                range.put(encodingMap((a << 2 | b >>> 6) & 0x1f));

                putCnt += 2;
            }
            if (meaningfulLength >= 4)
            {
                immutable b = source.front;
                source.popFront();
                immutable c = source.empty ? 0 : source.front;

                range.put(encodingMap(b >>> 1 & 0x1f));
                range.put(encodingMap((b << 4 | c >>> 4) & 0x1f));

                putCnt += 2;
            }
            if (meaningfulLength >= 5)
            {
                immutable c = source.front;
                source.popFront();
                immutable d = source.empty ? 0 : source.front;

                range.put(encodingMap((c << 1 | d >>> 7) & 0x1f));

                putCnt++;
            }
            if (meaningfulLength == 7)
            {
                immutable d = source.front;
                source.popFront();
                assert(source.empty);

                range.put(encodingMap(d >>> 2 & 0x1f));
                range.put(encodingMap(d << 3 & 0x1f));

                putCnt += 2;
            }

            static if (usePad)
            {
                foreach (_; 0 .. padLength)
                {
                    range.put(pad);
                }
                putCnt += padLength;
            }
        }

        // proxy out contract
        assert(putCnt == encodeLength(srcLen),
            "The number of put is different from the length of Base32");

        return putCnt;
    }


    /**
     * Creates an InputRange which lazily encodes $(D_PARAM source).
     *
     * Params:
     *  source = An InputRange to _encode.
     *
     * Returns:
     *  An InputRange which iterates over $(D_PARAM source) and lazily encodes it.
     *  If $(D_PARAM source) is a ForwardRange, the returned range will be the same.
     */
    template encoder(Range) if (isInputRange!Range && is(ElementType!Range : ubyte))
    {
        //
        auto encoder(Range source)
        {
            return Encoder(source);
        }


        struct Encoder
        {
            private
            {
                Range source;
                bool _empty;
                char _front;

                static if (hasLength!Range)
                {
                    size_t _length;
                }

                size_t resultChunkIdx = 0;
                size_t resultChunkLen = encResultChunkLength;
                ubyte srcBuf0, srcBuf1;
            }


            this(Range source)
            {
                _empty = source.empty;

                if (!_empty)
                {
                    static if (isForwardRange!Range)
                    {
                        this.source = source.save;
                    }
                    else
                    {
                        this.source = source;
                    }

                    static if (hasLength!Range)
                    {
                        _length = encodeLength(this.source.length);
                    }

                    _front = makeFront();
                }
            }

            static if (isInfinite!Range)
            {
                enum empty = false;
            }
            else
            {
                @property @safe @nogc nothrow
                bool empty() const
                {
                    static if (usePad)
                    {
                        return _empty && resultChunkIdx == 0;
                    }
                    else
                    {
                        return _empty;
                    }
                }
            }

            @property @safe
            char front() const
            {
                if (empty)
                {
                    throw new Base32Exception("Cannot call front on Encoder with no data remaining");
                }

                return _front;
            }

            void popFront()
            {
                if (empty)
                {
                    throw new Base32Exception("Cannot call popFront on Encoder with no data remaining");
                }

                ++resultChunkIdx %= encResultChunkLength;

                if (!_empty)
                {
                    _empty = resultChunkLen == resultChunkIdx;
                }

                static if (hasLength!Range)
                {
                    if (_length)
                    {
                        _length--;
                    }
                }

                _front = makeFront();
            }

            static if (isForwardRange!Range)
            {
                @property
                typeof(this) save()
                {
                    auto self = this;
                    self.source = self.source.save;
                    return self;
                }
            }

            static if (hasLength!Range)
            {
                @property @safe @nogc nothrow
                size_t length() const
                {
                    return _length;
                }
            }

            private
            char makeFront()
            {
                ubyte result;

                final switch (resultChunkIdx)
                {
                case 0:
                    if (source.empty)
                    {
                        srcBuf0 = 0;
                        resultChunkLen = 0;
                    }
                    else
                    {
                        srcBuf0 = source.front;
                        source.popFront();
                        result = srcBuf0 >>> 3;
                    }

                    break;
                case 1:
                    if (source.empty)
                    {
                        srcBuf1 = 0;
                        resultChunkLen = 2;
                    }
                    else
                    {
                        srcBuf1 = source.front;
                        source.popFront();
                    }

                    result = (srcBuf0 << 2 | srcBuf1 >>> 6) & 0x1f;
                    break;
                case 2:
                    result = srcBuf1 >>> 1 & 0x1f;
                    break;
                case 3:
                    if (source.empty)
                    {
                        srcBuf0 = 0;
                        resultChunkLen = 4;
                    }
                    else
                    {
                        srcBuf0 = source.front;
                        source.popFront();
                    }

                    result = (srcBuf1 << 4 | srcBuf0 >>> 4) & 0x1f;
                    break;
                case 4:
                    if (source.empty)
                    {
                        srcBuf1 = 0;
                        resultChunkLen = 5;
                    }
                    else
                    {
                        srcBuf1 = source.front;
                        source.popFront();
                    }

                    result = (srcBuf0 << 1 | srcBuf1 >>> 7) & 0x1f;
                    break;
                case 5:
                    result = srcBuf1 >>> 2 & 0x1f;
                    break;
                case 6:
                    if (source.empty)
                    {
                        srcBuf0 = 0;
                        resultChunkLen = 7;
                    }
                    else
                    {
                        srcBuf0 = source.front;
                        source.popFront();
                    }

                    result = (srcBuf1 << 3 | srcBuf0 >>> 5) & 0x1f;
                    break;
                case 7:
                    if (source.empty)
                    {
                        resultChunkLen = 0;
                    }

                    result = srcBuf0 & 0x1f;
                    break;
                }

                static if (usePad)
                {
                    return _empty ? pad : encodingMap(result);
                }
                else
                {
                    return encodingMap(result);
                }
            }
        }
    }


    // For decoding
    private enum size_t decSourceChunkLength = 8;
    private enum size_t decResultChunkLength = 5;


    private @safe pure nothrow
    size_t normalize(in size_t sourceLength)
    {
        size_t r = sourceLength;

        while(r % decSourceChunkLength)
        {
            r++;
        }

        return r;
    }


    private @safe pure nothrow
    size_t padToMeaningfulLength(in size_t padLength)
    {
        switch (padLength)
        {
        case 0:
            return 5;
        case 1:
            return 4;
        case 3:
            return 3;
        case 4:
            return 2;
        case 6:
            return 1;
        default:
            return size_t.max;
        }
    }


    private @safe pure nothrow
    bool isValidPadLength(in size_t padLength)
    {
        immutable m = padToMeaningfulLength(padLength);

        return 0 < m && m < 6;
    }


    /**
     * Calculates the length for decoding.
     *
     * Params:
     *  sourceLength = The length of a source.
     *
     * Returns:
     *  The maximum length which the result may have after a source with
     *  $(D_PARAM sourceLength) is decoded.
     */
    @safe pure nothrow
    size_t decodeLength(in size_t sourceLength)
    {
        static if (usePad){
            return (sourceLength / 8) * 5;
        }
        else
        {
            return (sourceLength / 8 + (sourceLength % 8 ? 1 : 0))* 5;
        }
    }


    // This should be called after input validation
    private @safe pure nothrow
    size_t preciseDecodeLength(Array)(Array source)
    {
        immutable approx = decodeLength(source.length);
        if (approx == 0)
        {
            return 0;
        }


        static if (usePad)
        {
            size_t padLength;

            if (source[$ - 1] == pad)
            {
                padLength = 1;

                if (source[$ - 2] == pad && source[$ - 3] == pad)
                {
                    padLength = 3;

                    if (source[$ - 4] == pad)
                    {
                        padLength = 4;

                        if (source[$ - 5] == pad && source[$ - 6] == pad)
                        {
                            padLength = 6;
                        }
                    }
                }
            }
        }
        else
        {
            immutable padLength = normalize(source.length) - source.length;
        }

        immutable meaninglessLength = decResultChunkLength - padToMeaningfulLength(padLength);
        return approx - meaninglessLength;
    }


    //
    private @safe pure nothrow
    size_t preciseDecodeLength(in size_t sourceLength, in size_t padLength)
    {
        immutable approx = decodeLength(sourceLength);
        if (approx == 0)
        {
            return 0;
        }

        immutable meaninglessLength = decResultChunkLength - padToMeaningfulLength(padLength);
        return approx - meaninglessLength;
    }


    // char[] to ubyte[]

    /**
     * Decodes $(D_PARAM source) and stores the result in $(D_PARAM buffer).
     * If no _buffer is assigned, a new buffer will be created.
     *
     * Params:
     *  source = A _base32 character array to _decode.
     *  buffer = An array to store the decoded result.
     *
     * Returns:
     *  The slice of $(D_PARAM buffer) containing the result.
     *
     * Throws:
     *  Exception if $(D_PARAM source) is an invalid _base32 data.
     */
    @trusted pure
    ubyte[] decode(C : dchar, UB = ubyte)(in C[] source, UB[] buffer = null)
        if (isOutputRange!(UB[], ubyte))
    in
    {
        assert(!buffer.ptr || buffer.length >= decodeLength(source.length),
            "Insufficient buffer for decoding");
    }
    out(result)
    {
        immutable expect = preciseDecodeLength(source);
        assert(result.length == expect,
            "The result length is different from the expected");
    }
    body
    {
        immutable actualLen = source.length;

        if (actualLen == 0)
        {
            return [];
        }

        static if (usePad)
        {
            immutable normalizedLen = actualLen;

            if (normalizedLen % decSourceChunkLength)
            {
                throw new Base32Exception("Invalid source length");
            }
        }
        else
        {
            immutable normalizedLen = normalize(actualLen);

            if (!isValidPadLength(normalizedLen - actualLen))
            {
                throw new Base32Exception("Invalid source length");
            }
        }

        if (!buffer.ptr)
        {
            buffer = new ubyte[decodeLength(normalizedLen)];
        }

        size_t padLength;
        size_t processedLength;
        auto srcPtr = source.ptr;
        auto bufPtr = buffer.ptr;

        ubyte[decSourceChunkLength] tmpBuffer;
        foreach (_; 0 .. normalizedLen / decSourceChunkLength)
        {
            bool firstPadFound;

            foreach (i, ref e; tmpBuffer)
            {
                static if (!usePad)
                {
                    if (firstPadFound || srcPtr - source.ptr == actualLen)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;
                        }

                        continue;
                    }
                }

                immutable c = *srcPtr++;

                static if (useHex)
                {
                    if (!firstPadFound && '0' <= c && c <= '9')
                    {
                        e = cast(ubyte)(c - '0');
                    }
                    else if (!firstPadFound && 'A' <= c && c <= 'V')
                    {
                        e = cast(ubyte)(c - 'A' + 10);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!usePad || !isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
                else
                {
                    if (!firstPadFound && 'A' <= c && c <= 'Z')
                    {
                        e = cast(ubyte)(c - 'A');
                    }
                    else if (!firstPadFound && '2' <= c && c <= '7')
                    {
                        e = cast(ubyte)(c - '2' + 26);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!usePad || !isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
            }

            immutable meaningfulLength = padToMeaningfulLength(padLength);
            processedLength += meaningfulLength;

            *bufPtr++ = cast(ubyte)(tmpBuffer[0] << 3 | tmpBuffer[1] >>> 2);
            if (meaningfulLength == 1)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[1] << 6 | tmpBuffer[2] << 1 | tmpBuffer[3] >>> 4);
            if (meaningfulLength == 2)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[3] << 4 | tmpBuffer[4] >>> 1);
            if (meaningfulLength == 3)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[4] << 7 | tmpBuffer[5] << 2 | tmpBuffer[6] >>> 3);
            if (meaningfulLength == 4)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[6] << 5 | tmpBuffer[7]);
        }

        return buffer[0 .. processedLength];
    }


    // InputRange to ubyte[]

    /**
     * Decodes $(D_PARAM source) and stores the result in $(D_PARAM buffer).
     * If no _buffer is assigned, a new buffer will be created.
     *
     * Params:
     *  source = A _base32 InputRange to _decode.
     *  buffer = An array to store the decoded result.
     *
     * Returns:
     *  The slice of $(D_PARAM buffer) containing the result.
     *
     * Throws:
     *  Exception if $(D_PARAM source) is an invalid _base32 data.
     */
    ubyte[] decode(CR, UB = ubyte)(CR source, UB[] buffer = null)
        if (!isArray!CR && isInputRange!CR && is(ElementType!CR : dchar)
            && hasLength!CR && isOutputRange!(UB[], ubyte))
    in
    {
        assert(!buffer.ptr || buffer.length >= decodeLength(source.length),
               "Insufficient buffer for decoding");
    }
    out(result)
    {
        // delegate to the proxies
    }
    body
    {
        immutable actualLen = source.length;

        if (actualLen == 0)
        {
            // proxy out contract
            assert(0 == preciseDecodeLength(actualLen, 0));
            return [];
        }

        static if (usePad)
        {
            immutable normalizedLen = actualLen;

            if (normalizedLen % decSourceChunkLength)
            {
                throw new Base32Exception("Invalid source length");
            }
        }
        else
        {
            immutable normalizedLen = normalize(actualLen);

            if (!isValidPadLength(normalizedLen - actualLen))
            {
                throw new Base32Exception("Invalid source length");
            }
        }

        if (!buffer.ptr)
        {
            buffer = new ubyte[decodeLength(normalizedLen)];
        }

        size_t padLength;
        size_t processedLength;
        auto bufPtr = buffer.ptr;

        ubyte[decSourceChunkLength] tmpBuffer;
        foreach (_; 0 .. normalizedLen / decSourceChunkLength)
        {
            bool firstPadFound;

            foreach (i, ref e; tmpBuffer)
            {
                static if (!usePad)
                {
                    if (firstPadFound || source.empty)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;
                        }

                        continue;
                    }
                }

                immutable c = source.front;
                source.popFront();

                static if (useHex)
                {
                    if (!firstPadFound && '0' <= c && c <= '9')
                    {
                        e = cast(ubyte)(c - '0');
                    }
                    else if (!firstPadFound && 'A' <= c && c <= 'V')
                    {
                        e = cast(ubyte)(c - 'A' + 10);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
                else
                {
                    if (!firstPadFound && 'A' <= c && c <= 'Z')
                    {
                        e = cast(ubyte)(c - 'A');
                    }
                    else if (!firstPadFound && '2' <= c && c <= '7')
                    {
                        e = cast(ubyte)(c - '2' + 26);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
            }

            immutable meaningfulLength = padToMeaningfulLength(padLength);
            processedLength += meaningfulLength;

            *bufPtr++ = cast(ubyte)(tmpBuffer[0] << 3 | tmpBuffer[1] >>> 2);
            if (meaningfulLength == 1)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[1] << 6 | tmpBuffer[2] << 1 | tmpBuffer[3] >>> 4);
            if (meaningfulLength == 2)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[3] << 4 | tmpBuffer[4] >>> 1);
            if (meaningfulLength == 3)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[4] << 7 | tmpBuffer[5] << 2 | tmpBuffer[6] >>> 3);
            if (meaningfulLength == 4)
            {
                break;
            }

            *bufPtr++ = cast(ubyte)(tmpBuffer[6] << 5 | tmpBuffer[7]);
        }

        // proxy out contract
        assert(processedLength == preciseDecodeLength(actualLen, padLength));

        return buffer[0 .. processedLength];
    }


    // char[] to OutputRange

    /**
     * Decodes $(D_PARAM source) and outputs the result to $(D_PARAM range).
     *
     * Params:
     *  source = A _base32 array to _decode.
     *  range  = An OutputRange to receive decoded result
     *
     * Returns:
     *  The number of the output characters.
     *
     * Throws:
     *  Exception if $(D_PARAM source) is invalid _base32 data.
     */
    size_t decode(C : dchar, UBR)(in C[] source, UBR range)
        if (!is(UBR == ubyte[]) && isOutputRange!(UBR, ubyte))
    out(result)
    {
        immutable expect = preciseDecodeLength(source);
        assert(result == expect,
               "The result is different from the expected");
    }
    body
    {
        immutable actualLen = source.length;

        if (actualLen == 0)
        {
            return 0;
        }

        static if (usePad)
        {
            immutable normalizedLen = actualLen;

            if (normalizedLen % decSourceChunkLength)
            {
                throw new Base32Exception("Invalid source length");
            }
        }
        else
        {
            immutable normalizedLen = normalize(actualLen);

            if (!isValidPadLength(normalizedLen - actualLen))
            {
                throw new Base32Exception("Invalid source length");
            }
        }

        size_t padLength;
        size_t processedLength;
        auto srcPtr = source.ptr;

        ubyte[decSourceChunkLength] tmpBuffer;
        foreach (_; 0 .. normalizedLen / decSourceChunkLength)
        {
            bool firstPadFound;

            foreach (i, ref e; tmpBuffer)
            {
                static if (!usePad)
                {
                    if (firstPadFound || srcPtr - source.ptr == actualLen)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;
                        }

                        continue;
                    }
                }

                immutable c = *srcPtr++;

                static if (useHex)
                {
                    if (!firstPadFound && '0' <= c && c <= '9')
                    {
                        e = cast(ubyte)(c - '0');
                    }
                    else if (!firstPadFound && 'A' <= c && c <= 'V')
                    {
                        e = cast(ubyte)(c - 'A' + 10);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!usePad || !isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
                else
                {
                    if (!firstPadFound && 'A' <= c && c <= 'Z')
                    {
                        e = cast(ubyte)(c - 'A');
                    }
                    else if (!firstPadFound && '2' <= c && c <= '7')
                    {
                        e = cast(ubyte)(c - '2' + 26);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!usePad || !isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
            }

            immutable meaningfulLength = padToMeaningfulLength(padLength);
            processedLength += meaningfulLength;

            range.put(cast(ubyte)(tmpBuffer[0] << 3 | tmpBuffer[1] >>> 2));
            if (meaningfulLength == 1)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[1] << 6 | tmpBuffer[2] << 1 | tmpBuffer[3] >>> 4));
            if (meaningfulLength == 2)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[3] << 4 | tmpBuffer[4] >>> 1));
            if (meaningfulLength == 3)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[4] << 7 | tmpBuffer[5] << 2 | tmpBuffer[6] >>> 3));
            if (meaningfulLength == 4)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[6] << 5 | tmpBuffer[7]));
        }

        return processedLength;
    }


    // InputRange to OutputRange

    /**
     * Decodes $(D_PARAM source) and outputs the result to $(D_PARAM range).
     *
     * Params:
     *  source = A _base32 InputRange to _decode.
     *  range  = An OutputRange to receive decoded result
     *
     * Returns:
     *  The number of the output characters.
     *
     * Throws:
     *  Exception if $(D_PARAM source) is invalid _base32 data.
     */
    size_t decode(CR, UBR)(CR source, UBR range)
        if (!isArray!CR && isInputRange!CR && is(ElementType!CR : dchar)
            && hasLength!CR && !is(UBR == ubyte[])
            && isOutputRange!(UBR, ubyte))
    out(result)
    {
        // delegate to the proxies
    }
    body
    {
        immutable actualLen = source.length;

        if (actualLen == 0)
        {
            // proxy out contract
            assert(0 == preciseDecodeLength(actualLen, 0));
            return 0;
        }

        static if (usePad)
        {
            immutable normalizedLen = actualLen;

            if (normalizedLen % decSourceChunkLength)
            {
                throw new Base32Exception("Invalid source length");
            }
        }
        else
        {
            immutable normalizedLen = normalize(actualLen);

            if (!isValidPadLength(normalizedLen - actualLen))
            {
                throw new Base32Exception("Invalid source length");
            }
        }

        size_t padLength;
        size_t processedLength;

        ubyte[decSourceChunkLength] tmpBuffer;
        foreach (_; 0 .. normalizedLen / decSourceChunkLength)
        {
            bool firstPadFound;

            foreach (i, ref e; tmpBuffer)
            {
                static if (!usePad)
                {
                    if (firstPadFound || source.empty)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;
                        }

                        continue;
                    }
                }

                auto c = source.front;
                // assert(!source.empty);
                source.popFront();

                static if (useHex)
                {
                    if (!firstPadFound && '0' <= c && c <= '9')
                    {
                        e = cast(ubyte)(c - '0');
                    }
                    else if (!firstPadFound && 'A' <= c && c <= 'V')
                    {
                        e = cast(ubyte)(c - 'A' + 10);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
                else
                {
                    if (!firstPadFound && 'A' <= c && c <= 'Z')
                    {
                        e = cast(ubyte)(c - 'A');
                    }
                    else if (!firstPadFound && '2' <= c && c <= '7')
                    {
                        e = cast(ubyte)(c - '2' + 26);
                    }
                    else if (c == pad)
                    {
                        e = 0;

                        if (!firstPadFound)
                        {
                            firstPadFound = true;
                            padLength = decSourceChunkLength - i;

                            if (!isValidPadLength(padLength))
                            {
                                throw new Base32Exception("Invalid padding found");
                            }
                        }
                    }
                    else
                    {
                        import std.conv : text;

                        throw new Base32Exception(text("Invalid character '", c, "' found"));
                    }
                }
            }

            immutable meaningfulLength = padToMeaningfulLength(padLength);
            processedLength += meaningfulLength;

            range.put(cast(ubyte)(tmpBuffer[0] << 3 | tmpBuffer[1] >>> 2));
            if (meaningfulLength == 1)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[1] << 6 | tmpBuffer[2] << 1 | tmpBuffer[3] >>> 4));
            if (meaningfulLength == 2)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[3] << 4 | tmpBuffer[4] >>> 1));
            if (meaningfulLength == 3)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[4] << 7 | tmpBuffer[5] << 2 | tmpBuffer[6] >>> 3));
            if (meaningfulLength == 4)
            {
                break;
            }

            range.put(cast(ubyte)(tmpBuffer[6] << 5 | tmpBuffer[7]));
        }

        assert(source.empty);

        // proxy out contract
        assert(processedLength == preciseDecodeLength(actualLen, padLength));

        return processedLength;
    }
}


/**
 * Exception thrown on errors in _base32 functions.
 */
class Base32Exception : Exception
{
    @safe pure nothrow
    this(string s, string fn = __FILE__, size_t ln = __LINE__)
    {
        super(s, fn, ln);
    }
}


// Encoding
unittest
{
    alias Base32NoPad = Base32Impl!(UseHex.no, UsePad.no);
    alias Base32HexNoPad = Base32Impl!(UseHex.yes, UsePad.no);

    pure auto toA(string s)
    {
        return cast(ubyte[])s;
    }

    pure auto toR(string s)
    {
        struct Range
        {
            private ubyte[] source;
            private size_t index;

            this(string s)
            {
                source = cast(ubyte[])s;
            }

            bool empty() @property
            {
                return index == source.length;
            }

            ubyte front() @property
            {
                return source[index];
            }

            void popFront()
            {
                index++;
            }

            size_t length() @property
            {
                return source.length;
            }
        }

        import std.range.primitives, std.traits;

        static assert(isInputRange!Range && is(ElementType!Range : ubyte)
            && hasLength!Range);

        return Range(s);
    }


    // Length
    {
        assert(Base32.encodeLength(toA("").length) == 0);
        assert(Base32.encodeLength(toA("f").length) == 8);
        assert(Base32.encodeLength(toA("fo").length) == 8);
        assert(Base32.encodeLength(toA("foo").length) == 8);
        assert(Base32.encodeLength(toA("foob").length) == 8);
        assert(Base32.encodeLength(toA("fooba").length) == 8);
        assert(Base32.encodeLength(toA("foobar").length) == 16);

        assert(Base32Hex.encodeLength(toA("").length) == 0);
        assert(Base32Hex.encodeLength(toA("f").length) == 8);
        assert(Base32Hex.encodeLength(toA("fo").length) == 8);
        assert(Base32Hex.encodeLength(toA("foo").length) == 8);
        assert(Base32Hex.encodeLength(toA("foob").length) == 8);
        assert(Base32Hex.encodeLength(toA("fooba").length) == 8);
        assert(Base32Hex.encodeLength(toA("foobar").length) == 16);

        assert(Base32NoPad.encodeLength(toA("").length) == 0);
        assert(Base32NoPad.encodeLength(toA("f").length) == 2);
        assert(Base32NoPad.encodeLength(toA("fo").length) == 4);
        assert(Base32NoPad.encodeLength(toA("foo").length) == 5);
        assert(Base32NoPad.encodeLength(toA("foob").length) == 7);
        assert(Base32NoPad.encodeLength(toA("fooba").length) == 8);
        assert(Base32NoPad.encodeLength(toA("foobar").length) == 10);

        assert(Base32HexNoPad.encodeLength(toA("").length) == 0);
        assert(Base32HexNoPad.encodeLength(toA("f").length) == 2);
        assert(Base32HexNoPad.encodeLength(toA("fo").length) == 4);
        assert(Base32HexNoPad.encodeLength(toA("foo").length) == 5);
        assert(Base32HexNoPad.encodeLength(toA("foob").length) == 7);
        assert(Base32HexNoPad.encodeLength(toA("fooba").length) == 8);
        assert(Base32HexNoPad.encodeLength(toA("foobar").length) == 10);
    }

    // Array to Array
    {
        assert(Base32.encode(toA("")) == "");
        assert(Base32.encode(toA("f")) == "MY======");
        assert(Base32.encode(toA("fo")) == "MZXQ====");
        assert(Base32.encode(toA("foo")) == "MZXW6===");
        assert(Base32.encode(toA("foob")) == "MZXW6YQ=");
        assert(Base32.encode(toA("fooba")) == "MZXW6YTB");
        assert(Base32.encode(toA("foobar")) == "MZXW6YTBOI======");

        assert(Base32Hex.encode(toA("")) == "");
        assert(Base32Hex.encode(toA("f")) == "CO======");
        assert(Base32Hex.encode(toA("fo")) == "CPNG====");
        assert(Base32Hex.encode(toA("foo")) == "CPNMU===");
        assert(Base32Hex.encode(toA("foob")) == "CPNMUOG=");
        assert(Base32Hex.encode(toA("fooba")) == "CPNMUOJ1");
        assert(Base32Hex.encode(toA("foobar")) == "CPNMUOJ1E8======");

        assert(Base32NoPad.encode(toA("")) == "");
        assert(Base32NoPad.encode(toA("f")) == "MY");
        assert(Base32NoPad.encode(toA("fo")) == "MZXQ");
        assert(Base32NoPad.encode(toA("foo")) == "MZXW6");
        assert(Base32NoPad.encode(toA("foob")) == "MZXW6YQ");
        assert(Base32NoPad.encode(toA("fooba")) == "MZXW6YTB");
        assert(Base32NoPad.encode(toA("foobar")) == "MZXW6YTBOI");

        assert(Base32HexNoPad.encode(toA("")) == "");
        assert(Base32HexNoPad.encode(toA("f")) == "CO");
        assert(Base32HexNoPad.encode(toA("fo")) == "CPNG");
        assert(Base32HexNoPad.encode(toA("foo")) == "CPNMU");
        assert(Base32HexNoPad.encode(toA("foob")) == "CPNMUOG");
        assert(Base32HexNoPad.encode(toA("fooba")) == "CPNMUOJ1");
        assert(Base32HexNoPad.encode(toA("foobar")) == "CPNMUOJ1E8");
    }

    // InputRange to Array
    {
        assert(Base32.encode(toR("")) == "");
        assert(Base32.encode(toR("f")) == "MY======");
        assert(Base32.encode(toR("fo")) == "MZXQ====");
        assert(Base32.encode(toR("foo")) == "MZXW6===");
        assert(Base32.encode(toR("foob")) == "MZXW6YQ=");
        assert(Base32.encode(toR("fooba")) == "MZXW6YTB");
        assert(Base32.encode(toR("foobar")) == "MZXW6YTBOI======");

        assert(Base32Hex.encode(toR("")) == "");
        assert(Base32Hex.encode(toR("f")) == "CO======");
        assert(Base32Hex.encode(toR("fo")) == "CPNG====");
        assert(Base32Hex.encode(toR("foo")) == "CPNMU===");
        assert(Base32Hex.encode(toR("foob")) == "CPNMUOG=");
        assert(Base32Hex.encode(toR("fooba")) == "CPNMUOJ1");
        assert(Base32Hex.encode(toR("foobar")) == "CPNMUOJ1E8======");

        assert(Base32NoPad.encode(toR("")) == "");
        assert(Base32NoPad.encode(toR("f")) == "MY");
        assert(Base32NoPad.encode(toR("fo")) == "MZXQ");
        assert(Base32NoPad.encode(toR("foo")) == "MZXW6");
        assert(Base32NoPad.encode(toR("foob")) == "MZXW6YQ");
        assert(Base32NoPad.encode(toR("fooba")) == "MZXW6YTB");
        assert(Base32NoPad.encode(toR("foobar")) == "MZXW6YTBOI");

        assert(Base32HexNoPad.encode(toR("")) == "");
        assert(Base32HexNoPad.encode(toR("f")) == "CO");
        assert(Base32HexNoPad.encode(toR("fo")) == "CPNG");
        assert(Base32HexNoPad.encode(toR("foo")) == "CPNMU");
        assert(Base32HexNoPad.encode(toR("foob")) == "CPNMUOG");
        assert(Base32HexNoPad.encode(toR("fooba")) == "CPNMUOJ1");
        assert(Base32HexNoPad.encode(toR("foobar")) == "CPNMUOJ1E8");
    }

    // Array to OutputRange
    {
        import std.array : appender;

        auto app = appender!(char[])();

        assert(Base32.encode(toA(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32.encode(toA("f"), app) == 8);
        assert(app.data == "MY======");
        app.clear();
        assert(Base32.encode(toA("fo"), app) == 8);
        assert(app.data == "MZXQ====");
        app.clear();
        assert(Base32.encode(toA("foo"), app) == 8);
        assert(app.data == "MZXW6===");
        app.clear();
        assert(Base32.encode(toA("foob"), app) == 8);
        assert(app.data == "MZXW6YQ=");
        app.clear();
        assert(Base32.encode(toA("fooba"), app) == 8);
        assert(app.data == "MZXW6YTB");
        app.clear();
        assert(Base32.encode(toA("foobar"), app) == 16);
        assert(app.data == "MZXW6YTBOI======");
        app.clear();

        assert(Base32Hex.encode(toA(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32Hex.encode(toA("f"), app) == 8);
        assert(app.data == "CO======");
        app.clear();
        assert(Base32Hex.encode(toA("fo"), app) == 8);
        assert(app.data == "CPNG====");
        app.clear();
        assert(Base32Hex.encode(toA("foo"), app) == 8);
        assert(app.data == "CPNMU===");
        app.clear();
        assert(Base32Hex.encode(toA("foob"), app) == 8);
        assert(app.data == "CPNMUOG=");
        app.clear();
        assert(Base32Hex.encode(toA("fooba"), app) == 8);
        assert(app.data == "CPNMUOJ1");
        app.clear();
        assert(Base32Hex.encode(toA("foobar"), app) == 16);
        assert(app.data == "CPNMUOJ1E8======");
        app.clear();

        assert(Base32NoPad.encode(toA(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32NoPad.encode(toA("f"), app) == 2);
        assert(app.data == "MY");
        app.clear();
        assert(Base32NoPad.encode(toA("fo"), app) == 4);
        assert(app.data == "MZXQ");
        app.clear();
        assert(Base32NoPad.encode(toA("foo"), app) == 5);
        assert(app.data == "MZXW6");
        app.clear();
        assert(Base32NoPad.encode(toA("foob"), app) == 7);
        assert(app.data == "MZXW6YQ");
        app.clear();
        assert(Base32NoPad.encode(toA("fooba"), app) == 8);
        assert(app.data == "MZXW6YTB");
        app.clear();
        assert(Base32NoPad.encode(toA("foobar"), app) == 10);
        assert(app.data == "MZXW6YTBOI");
        app.clear();

        assert(Base32HexNoPad.encode(toA(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32HexNoPad.encode(toA("f"), app) == 2);
        assert(app.data == "CO");
        app.clear();
        assert(Base32HexNoPad.encode(toA("fo"), app) == 4);
        assert(app.data == "CPNG");
        app.clear();
        assert(Base32HexNoPad.encode(toA("foo"), app) == 5);
        assert(app.data == "CPNMU");
        app.clear();
        assert(Base32HexNoPad.encode(toA("foob"), app) == 7);
        assert(app.data == "CPNMUOG");
        app.clear();
        assert(Base32HexNoPad.encode(toA("fooba"), app) == 8);
        assert(app.data == "CPNMUOJ1");
        app.clear();
        assert(Base32HexNoPad.encode(toA("foobar"), app) == 10);
        assert(app.data == "CPNMUOJ1E8");
        app.clear();
    }

    // InputRange to OutputRange
    {
        import std.array : appender;

        auto app = appender!(char[])();

        assert(Base32.encode(toR(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32.encode(toR("f"), app) == 8);
        assert(app.data == "MY======");
        app.clear();
        assert(Base32.encode(toR("fo"), app) == 8);
        assert(app.data == "MZXQ====");
        app.clear();
        assert(Base32.encode(toR("foo"), app) == 8);
        assert(app.data == "MZXW6===");
        app.clear();
        assert(Base32.encode(toR("foob"), app) == 8);
        assert(app.data == "MZXW6YQ=");
        app.clear();
        assert(Base32.encode(toR("fooba"), app) == 8);
        assert(app.data == "MZXW6YTB");
        app.clear();
        assert(Base32.encode(toR("foobar"), app) == 16);
        assert(app.data == "MZXW6YTBOI======");
        app.clear();

        assert(Base32Hex.encode(toR(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32Hex.encode(toR("f"), app) == 8);
        assert(app.data == "CO======");
        app.clear();
        assert(Base32Hex.encode(toR("fo"), app) == 8);
        assert(app.data == "CPNG====");
        app.clear();
        assert(Base32Hex.encode(toR("foo"), app) == 8);
        assert(app.data == "CPNMU===");
        app.clear();
        assert(Base32Hex.encode(toR("foob"), app) == 8);
        assert(app.data == "CPNMUOG=");
        app.clear();
        assert(Base32Hex.encode(toR("fooba"), app) == 8);
        assert(app.data == "CPNMUOJ1");
        app.clear();
        assert(Base32Hex.encode(toR("foobar"), app) == 16);
        assert(app.data == "CPNMUOJ1E8======");
        app.clear();

        assert(Base32NoPad.encode(toR(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32NoPad.encode(toR("f"), app) == 2);
        assert(app.data == "MY");
        app.clear();
        assert(Base32NoPad.encode(toR("fo"), app) == 4);
        assert(app.data == "MZXQ");
        app.clear();
        assert(Base32NoPad.encode(toR("foo"), app) == 5);
        assert(app.data == "MZXW6");
        app.clear();
        assert(Base32NoPad.encode(toR("foob"), app) == 7);
        assert(app.data == "MZXW6YQ");
        app.clear();
        assert(Base32NoPad.encode(toR("fooba"), app) == 8);
        assert(app.data == "MZXW6YTB");
        app.clear();
        assert(Base32NoPad.encode(toR("foobar"), app) == 10);
        assert(app.data == "MZXW6YTBOI");
        app.clear();

        assert(Base32HexNoPad.encode(toR(""), app) == 0);
        assert(app.data == "");
        app.clear();
        assert(Base32HexNoPad.encode(toR("f"), app) == 2);
        assert(app.data == "CO");
        app.clear();
        assert(Base32HexNoPad.encode(toR("fo"), app) == 4);
        assert(app.data == "CPNG");
        app.clear();
        assert(Base32HexNoPad.encode(toR("foo"), app) == 5);
        assert(app.data == "CPNMU");
        app.clear();
        assert(Base32HexNoPad.encode(toR("foob"), app) == 7);
        assert(app.data == "CPNMUOG");
        app.clear();
        assert(Base32HexNoPad.encode(toR("fooba"), app) == 8);
        assert(app.data == "CPNMUOJ1");
        app.clear();
        assert(Base32HexNoPad.encode(toR("foobar"), app) == 10);
        assert(app.data == "CPNMUOJ1E8");
        app.clear();
    }

    // Encoder
    {
        import std.algorithm.comparison : equal;
        import std.exception : assertThrown;

        auto enc1 = Base32.encoder(toA(""));
        assert(enc1.empty);
        assert(enc1.length == 0);
        assert(enc1.equal(""));
        enc1 = Base32.encoder(toA("f"));
        assert(enc1.length == 8);
        assert(enc1.equal("MY======"));
        enc1 = Base32.encoder(toA("fo"));
        assert(enc1.length == 8);
        assert(enc1.equal("MZXQ===="));
        enc1 = Base32.encoder(toA("foo"));
        assert(enc1.length == 8);
        assert(enc1.equal("MZXW6==="));
        enc1 = Base32.encoder(toA("foob"));
        assert(enc1.length == 8);
        assert(enc1.equal("MZXW6YQ="));
        enc1 = Base32.encoder(toA("fooba"));
        assert(enc1.length == 8);
        assert(enc1.equal("MZXW6YTB"));
        enc1 = Base32.encoder(toA("foobar"));
        assert(enc1.length == 16);
        assert(enc1.equal("MZXW6YTBOI======"));

        auto enc2 = Base32NoPad.encoder(toA(""));
        assert(enc2.empty);
        assert(enc2.length == 0);
        assert(enc2.equal(""));
        enc2 = Base32NoPad.encoder(toA("f"));
        assert(enc2.length == 2);
        assert(enc2.equal("MY"));
        enc2 = Base32NoPad.encoder(toA("fo"));
        assert(enc2.length == 4);
        assert(enc2.equal("MZXQ"));
        enc2 = Base32NoPad.encoder(toA("foo"));
        assert(enc2.length == 5);
        assert(enc2.equal("MZXW6"));
        enc2 = Base32NoPad.encoder(toA("foob"));
        assert(enc2.length == 7);
        assert(enc2.equal("MZXW6YQ"));
        enc2 = Base32NoPad.encoder(toA("fooba"));
        assert(enc2.length == 8);
        assert(enc2.equal("MZXW6YTB"));
        enc2 = Base32NoPad.encoder(toA("foobar"));
        assert(enc2.length == 10);
        assert(enc2.equal("MZXW6YTBOI"));

        enc2 = Base32NoPad.encoder(toA("f"));
        // assert(enc2.length == 2);
        // assert(enc2.equal("MY"));
        auto enc3 = enc2.save;
        enc2.popFront();
        enc2.popFront();
        assert(enc2.empty);
        assert(enc2.length == 0);
        assert(enc2.equal(""));
        assert(enc3.length == 2);
        assert(enc3.equal("MY"));

        assertThrown!Base32Exception(enc2.popFront());
        assertThrown!Base32Exception(enc2.front);
    }
}

// Decoding
unittest
{
    alias Base32NoPad = Base32Impl!(UseHex.no, UsePad.no);
    alias Base32HexNoPad = Base32Impl!(UseHex.yes, UsePad.no);

    pure auto toA(in string s)
    {
        return cast(ubyte[])s;
    }

    pure auto toR(in string s)
    {
        struct Range
        {
            private char[] source;
            private size_t index;

            this(string s)
            {
                source = cast(char[])s;
            }

            bool empty() @property
            {
                return index == source.length;
            }

            ubyte front() @property
            {
                return source[index];
            }

            void popFront()
            {
                index++;
            }

            size_t length() @property
            {
                return source.length;
            }
        }

        import std.range.primitives, std.traits;

        static assert(isInputRange!Range && is(ElementType!Range : dchar)
            && hasLength!Range);

        return Range(s);
    }


    import std.exception : assertThrown;

    // Length
    {
        assert(Base32.decodeLength(0) == 0);
        assert(Base32.decodeLength(8) == 5);
        assert(Base32.decodeLength(16) == 10);

        assert(Base32.preciseDecodeLength("") == 0);
        assert(Base32.preciseDecodeLength("MY======") == 1);
        assert(Base32.preciseDecodeLength("MZXQ====") == 2);
        assert(Base32.preciseDecodeLength("MZXW6===") == 3);
        assert(Base32.preciseDecodeLength("MZXW6YQ=") == 4);
        assert(Base32.preciseDecodeLength("MZXW6YTB") == 5);
        assert(Base32.preciseDecodeLength("MZXW6YTBOI======") == 6);

        assert(Base32Hex.decodeLength(0) == 0);
        assert(Base32Hex.decodeLength(8) == 5);
        assert(Base32Hex.decodeLength(16) == 10);

        assert(Base32Hex.preciseDecodeLength("") == 0);
        assert(Base32Hex.preciseDecodeLength("CO======") == 1);
        assert(Base32Hex.preciseDecodeLength("CPNG====") == 2);
        assert(Base32Hex.preciseDecodeLength("CPNMU===") == 3);
        assert(Base32Hex.preciseDecodeLength("CPNMUOG=") == 4);
        assert(Base32Hex.preciseDecodeLength("CPNMUOJ1") == 5);
        assert(Base32Hex.preciseDecodeLength("CPNMUOJ1E8======") == 6);

        assert(Base32NoPad.decodeLength(0) == 0);
        assert(Base32NoPad.decodeLength(2) == 5);
        assert(Base32NoPad.decodeLength(4) == 5);
        assert(Base32NoPad.decodeLength(5) == 5);
        assert(Base32NoPad.decodeLength(7) == 5);
        assert(Base32NoPad.decodeLength(8) == 5);
        assert(Base32NoPad.decodeLength(10) == 10);

        assert(Base32NoPad.preciseDecodeLength("") == 0);
        assert(Base32NoPad.preciseDecodeLength("MY") == 1);
        assert(Base32NoPad.preciseDecodeLength("MZXQ") == 2);
        assert(Base32NoPad.preciseDecodeLength("MZXW6") == 3);
        assert(Base32NoPad.preciseDecodeLength("MZXW6YQ") == 4);
        assert(Base32NoPad.preciseDecodeLength("MZXW6YTB") == 5);
        assert(Base32NoPad.preciseDecodeLength("MZXW6YTBOI") == 6);

        assert(Base32HexNoPad.decodeLength(0) == 0);
        assert(Base32HexNoPad.decodeLength(2) == 5);
        assert(Base32HexNoPad.decodeLength(4) == 5);
        assert(Base32HexNoPad.decodeLength(5) == 5);
        assert(Base32HexNoPad.decodeLength(7) == 5);
        assert(Base32HexNoPad.decodeLength(8) == 5);
        assert(Base32HexNoPad.decodeLength(10) == 10);

        assert(Base32HexNoPad.preciseDecodeLength("") == 0);
        assert(Base32HexNoPad.preciseDecodeLength("CO") == 1);
        assert(Base32HexNoPad.preciseDecodeLength("CPNG") == 2);
        assert(Base32HexNoPad.preciseDecodeLength("CPNMU") == 3);
        assert(Base32HexNoPad.preciseDecodeLength("CPNMUOG") == 4);
        assert(Base32HexNoPad.preciseDecodeLength("CPNMUOJ1") == 5);
        assert(Base32HexNoPad.preciseDecodeLength("CPNMUOJ1E8") == 6);
    }

    // Array to Array
    {
        assert(Base32.decode("") == toA(""));
        assert(Base32.decode("MY======") == toA("f"));
        assert(Base32.decode("MZXQ====") == toA("fo"));
        assert(Base32.decode("MZXW6===") == toA("foo"));
        assert(Base32.decode("MZXW6YQ=") == toA("foob"));
        assert(Base32.decode("MZXW6YTB") == toA("fooba"));
        assert(Base32.decode("MZXW6YTBOI======") == toA("foobar"));

        assert(Base32Hex.decode("") == toA(""));
        assert(Base32Hex.decode("CO======") == toA("f"));
        assert(Base32Hex.decode("CPNG====") == toA("fo"));
        assert(Base32Hex.decode("CPNMU===") == toA("foo"));
        assert(Base32Hex.decode("CPNMUOG=") == toA("foob"));
        assert(Base32Hex.decode("CPNMUOJ1") == toA("fooba"));
        assert(Base32Hex.decode("CPNMUOJ1E8======") == toA("foobar"));

        assert(Base32NoPad.decode("") == toA(""));
        assert(Base32NoPad.decode("MY") == toA("f"));
        assert(Base32NoPad.decode("MZXQ") == toA("fo"));
        assert(Base32NoPad.decode("MZXW6") == toA("foo"));
        assert(Base32NoPad.decode("MZXW6YQ") == toA("foob"));
        assert(Base32NoPad.decode("MZXW6YTB") == toA("fooba"));
        assert(Base32NoPad.decode("MZXW6YTBOI") == toA("foobar"));

        assert(Base32HexNoPad.decode("") == toA(""));
        assert(Base32HexNoPad.decode("CO") == toA("f"));
        assert(Base32HexNoPad.decode("CPNG") == toA("fo"));
        assert(Base32HexNoPad.decode("CPNMU") == toA("foo"));
        assert(Base32HexNoPad.decode("CPNMUOG") == toA("foob"));
        assert(Base32HexNoPad.decode("CPNMUOJ1") == toA("fooba"));
        assert(Base32HexNoPad.decode("CPNMUOJ1E8") == toA("foobar"));

        // Invalid source length
        assertThrown!Base32Exception(Base32.decode("A"));
        assertThrown!Base32Exception(Base32.decode("AA"));
        assertThrown!Base32Exception(Base32.decode("AAA"));
        assertThrown!Base32Exception(Base32.decode("AAAA"));
        assertThrown!Base32Exception(Base32.decode("AAAAA"));
        assertThrown!Base32Exception(Base32.decode("AAAAAA"));
        assertThrown!Base32Exception(Base32.decode("AAAAAAA"));

        assertThrown!Base32Exception(Base32Hex.decode("A"));
        assertThrown!Base32Exception(Base32Hex.decode("AA"));
        assertThrown!Base32Exception(Base32Hex.decode("AAA"));
        assertThrown!Base32Exception(Base32Hex.decode("AAAA"));
        assertThrown!Base32Exception(Base32Hex.decode("AAAAA"));
        assertThrown!Base32Exception(Base32Hex.decode("AAAAAA"));
        assertThrown!Base32Exception(Base32Hex.decode("AAAAAAA"));

        assertThrown!Base32Exception(Base32NoPad.decode("A"));
        assertThrown!Base32Exception(Base32NoPad.decode("AAA"));
        assertThrown!Base32Exception(Base32NoPad.decode("AAAAAA"));
        assertThrown!Base32Exception(Base32NoPad.decode("AAAAAAAAA"));

        assertThrown!Base32Exception(Base32HexNoPad.decode("A"));
        assertThrown!Base32Exception(Base32HexNoPad.decode("AAA"));
        assertThrown!Base32Exception(Base32HexNoPad.decode("AAAAAA"));
        assertThrown!Base32Exception(Base32HexNoPad.decode("AAAAAAAAA"));

        // Invalid character
        assertThrown!Base32Exception(Base32.decode("AA?AA?AA"));
        assertThrown!Base32Exception(Base32Hex.decode("AA?AA?AA"));
        assertThrown!Base32Exception(Base32NoPad.decode("AA?AA?AA"));
        assertThrown!Base32Exception(Base32HexNoPad.decode("AA?AA?AA"));

        // Invalid padding
        assertThrown!Base32Exception(Base32.decode("=AAAAAAA"));
        assertThrown!Base32Exception(Base32Hex.decode("=AAAAAAA"));
        assertThrown!Base32Exception(Base32NoPad.decode("=AAAAAAA"));
        assertThrown!Base32Exception(Base32HexNoPad.decode("=AAAAAAA"));
    }

    // InputRange to Array
    {
        assert(Base32.decode(toR("")) == toA(""));
        assert(Base32.decode(toR("MY======")) == toA("f"));
        assert(Base32.decode(toR("MZXQ====")) == toA("fo"));
        assert(Base32.decode(toR("MZXW6===")) == toA("foo"));
        assert(Base32.decode(toR("MZXW6YQ=")) == toA("foob"));
        assert(Base32.decode(toR("MZXW6YTB")) == toA("fooba"));
        assert(Base32.decode(toR("MZXW6YTBOI======")) == toA("foobar"));

        assert(Base32Hex.decode(toR("")) == toA(""));
        assert(Base32Hex.decode(toR("CO======")) == toA("f"));
        assert(Base32Hex.decode(toR("CPNG====")) == toA("fo"));
        assert(Base32Hex.decode(toR("CPNMU===")) == toA("foo"));
        assert(Base32Hex.decode(toR("CPNMUOG=")) == toA("foob"));
        assert(Base32Hex.decode(toR("CPNMUOJ1")) == toA("fooba"));
        assert(Base32Hex.decode(toR("CPNMUOJ1E8======")) == toA("foobar"));

        assert(Base32NoPad.decode(toR("")) == toA(""));
        assert(Base32NoPad.decode(toR("MY")) == toA("f"));
        assert(Base32NoPad.decode(toR("MZXQ")) == toA("fo"));
        assert(Base32NoPad.decode(toR("MZXW6")) == toA("foo"));
        assert(Base32NoPad.decode(toR("MZXW6YQ")) == toA("foob"));
        assert(Base32NoPad.decode(toR("MZXW6YTB")) == toA("fooba"));
        assert(Base32NoPad.decode(toR("MZXW6YTBOI")) == toA("foobar"));

        assert(Base32HexNoPad.decode(toR("")) == toA(""));
        assert(Base32HexNoPad.decode(toR("CO")) == toA("f"));
        assert(Base32HexNoPad.decode(toR("CPNG")) == toA("fo"));
        assert(Base32HexNoPad.decode(toR("CPNMU")) == toA("foo"));
        assert(Base32HexNoPad.decode(toR("CPNMUOG")) == toA("foob"));
        assert(Base32HexNoPad.decode(toR("CPNMUOJ1")) == toA("fooba"));
        assert(Base32HexNoPad.decode(toR("CPNMUOJ1E8")) == toA("foobar"));

        // Invalid source length
        assertThrown!Base32Exception(Base32.decode(toR("A")));
        assertThrown!Base32Exception(Base32.decode(toR("AA")));
        assertThrown!Base32Exception(Base32.decode(toR("AAA")));
        assertThrown!Base32Exception(Base32.decode(toR("AAAA")));
        assertThrown!Base32Exception(Base32.decode(toR("AAAAA")));
        assertThrown!Base32Exception(Base32.decode(toR("AAAAAA")));
        assertThrown!Base32Exception(Base32.decode(toR("AAAAAAA")));

        assertThrown!Base32Exception(Base32Hex.decode(toR("A")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAAA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAAAA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAAAAA")));

        assertThrown!Base32Exception(Base32NoPad.decode(toR("A")));
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AAA")));
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AAAAAA")));
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AAAAAAAAA")));

        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("A")));
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AAA")));
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AAAAAA")));
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AAAAAAAAA")));

        // Invalid character
        assertThrown!Base32Exception(Base32.decode(toR("AA?AA?AA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("AA?AA?AA")));
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AA?AA?AA")));
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AA?AA?AA")));

        // Invalid padding
        assertThrown!Base32Exception(Base32.decode(toR("=AAAAAAA")));
        assertThrown!Base32Exception(Base32Hex.decode(toR("=AAAAAAA")));
        assertThrown!Base32Exception(Base32NoPad.decode(toR("=AAAAAAA")));
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("=AAAAAAA")));
    }

    // Array to OutputRange
    {
        import std.array : appender;

        auto app = appender!(ubyte[])();

        assert(Base32.decode("", app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32.decode("MY======", app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32.decode("MZXQ====", app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32.decode("MZXW6===", app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32.decode("MZXW6YQ=", app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32.decode("MZXW6YTB", app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32.decode("MZXW6YTBOI======", app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        assert(Base32Hex.decode("", app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32Hex.decode("CO======", app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32Hex.decode("CPNG====", app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32Hex.decode("CPNMU===", app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32Hex.decode("CPNMUOG=", app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32Hex.decode("CPNMUOJ1", app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32Hex.decode("CPNMUOJ1E8======", app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        assert(Base32NoPad.decode("", app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32NoPad.decode("MY", app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32NoPad.decode("MZXQ", app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32NoPad.decode("MZXW6", app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32NoPad.decode("MZXW6YQ", app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32NoPad.decode("MZXW6YTB", app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32NoPad.decode("MZXW6YTBOI", app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        assert(Base32HexNoPad.decode("", app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32HexNoPad.decode("CO", app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32HexNoPad.decode("CPNG", app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32HexNoPad.decode("CPNMU", app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32HexNoPad.decode("CPNMUOG", app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32HexNoPad.decode("CPNMUOJ1", app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32HexNoPad.decode("CPNMUOJ1E8", app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        // Invalid source length
        assertThrown!Base32Exception(Base32.decode("A", app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode("AA", app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode("AAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode("AAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode("AAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode("AAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode("AAAAAAA", app));
        app.clear();

        assertThrown!Base32Exception(Base32Hex.decode("A", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AAAAAAA", app));
        app.clear();

        assertThrown!Base32Exception(Base32NoPad.decode("A", app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode("AAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode("AAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode("AAAAAAAAA", app));
        app.clear();

        assertThrown!Base32Exception(Base32HexNoPad.decode("A", app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode("AAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode("AAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode("AAAAAAAAA", app));
        app.clear();

        // Invalid character
        assertThrown!Base32Exception(Base32.decode("AA?AA?AA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("AA?AA?AA", app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode("AA?AA?AA", app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode("AA?AA?AA", app));
        app.clear();

        // Invalid padding
        assertThrown!Base32Exception(Base32.decode("=AAAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode("=AAAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode("=AAAAAAA", app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode("=AAAAAAA", app));
        app.clear();
    }

    // InputRange to OutputRange
    {
        import std.array : appender;

        auto app = appender!(ubyte[])();

        assert(Base32.decode(toR(""), app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32.decode(toR("MY======"), app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32.decode(toR("MZXQ===="), app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32.decode(toR("MZXW6==="), app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32.decode(toR("MZXW6YQ="), app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32.decode(toR("MZXW6YTB"), app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32.decode(toR("MZXW6YTBOI======"), app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        assert(Base32Hex.decode(toR(""), app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32Hex.decode(toR("CO======"), app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32Hex.decode(toR("CPNG===="), app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32Hex.decode(toR("CPNMU==="), app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32Hex.decode(toR("CPNMUOG="), app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32Hex.decode(toR("CPNMUOJ1"), app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32Hex.decode(toR("CPNMUOJ1E8======"), app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        assert(Base32NoPad.decode(toR(""), app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32NoPad.decode(toR("MY"), app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32NoPad.decode(toR("MZXQ"), app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32NoPad.decode(toR("MZXW6"), app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32NoPad.decode(toR("MZXW6YQ"), app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32NoPad.decode(toR("MZXW6YTB"), app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32NoPad.decode(toR("MZXW6YTBOI"), app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        assert(Base32HexNoPad.decode(toR(""), app) == 0);
        assert(app.data == toA(""));
        app.clear();
        assert(Base32HexNoPad.decode(toR("CO"), app) == 1);
        assert(app.data == toA("f"));
        app.clear();
        assert(Base32HexNoPad.decode(toR("CPNG"), app) == 2);
        assert(app.data == toA("fo"));
        app.clear();
        assert(Base32HexNoPad.decode(toR("CPNMU"), app) == 3);
        assert(app.data == toA("foo"));
        app.clear();
        assert(Base32HexNoPad.decode(toR("CPNMUOG"), app) == 4);
        assert(app.data == toA("foob"));
        app.clear();
        assert(Base32HexNoPad.decode(toR("CPNMUOJ1"), app) == 5);
        assert(app.data == toA("fooba"));
        app.clear();
        assert(Base32HexNoPad.decode(toR("CPNMUOJ1E8"), app) == 6);
        assert(app.data == toA("foobar"));
        app.clear();

        // Invalid source length
        assertThrown!Base32Exception(Base32.decode(toR("A"), app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode(toR("AA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode(toR("AAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode(toR("AAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode(toR("AAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode(toR("AAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32.decode(toR("AAAAAAA"), app));
        app.clear();

        assertThrown!Base32Exception(Base32Hex.decode(toR("A"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AAAAAAA"), app));
        app.clear();

        assertThrown!Base32Exception(Base32NoPad.decode(toR("A"), app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AAAAAAAAA"), app));
        app.clear();

        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("A"), app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AAAAAAAAA"), app));
        app.clear();

        // Invalid character
        assertThrown!Base32Exception(Base32.decode(toR("AA?AA?AA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("AA?AA?AA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode(toR("AA?AA?AA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("AA?AA?AA"), app));
        app.clear();

        // Invalid padding
        assertThrown!Base32Exception(Base32.decode(toR("=AAAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32Hex.decode(toR("=AAAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32NoPad.decode(toR("=AAAAAAA"), app));
        app.clear();
        assertThrown!Base32Exception(Base32HexNoPad.decode(toR("=AAAAAAA"), app));
        app.clear();
    }
}
