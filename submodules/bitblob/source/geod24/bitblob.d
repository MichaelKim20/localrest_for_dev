/*******************************************************************************

    Variadic-sized value type to represent a hash

    A `BitBlob` is a value type representing a hash.
    The argument is the size in bits, e.g. for sha256 it is 256.
    It can be initialized from the hexadecimal string representation
    or an `ubyte[]`, making it easy to interact with `std.digest`

    Author:         Mathias 'Geod24' Lang
    License:        MIT (See LICENSE.txt)
    Copyright:      Copyright (c) 2017-2018 Mathias Lang. All rights reserved.

*******************************************************************************/

module geod24.bitblob;

static import std.ascii;
import std.algorithm.iteration : each, map;
import std.range;
import std.utf;

///
@nogc @safe pure nothrow unittest
{
    /// Alias for a 256 bits / 32 byte hash type
    alias Hash = BitBlob!256;

    import std.digest.sha;
    // Can be initialized from an `ubyte[32]`
    // (or `ubyte[]` of length 32)
    Hash fromSha = sha256Of("Hello World");

    // Of from a string
    Hash genesis = GenesisBlockHashStr;

    assert(!genesis.isNull());
    assert(Hash.init.isNull());

    ubyte[5] empty;
    assert(Hash.init < genesis);
    // The underlying 32 bytes can be access through `opIndex` and `opSlice`
    assert(genesis[$ - 5 .. $] == empty);
}


/*******************************************************************************

    A value type representing a hash

    Params:
      Bits = The size of the hash, in bits. Must be a multiple of 8.

*******************************************************************************/

public struct BitBlob (size_t Bits)
{
    @safe:

    static assert (
        Bits % 8 == 0,
        "Argument to BitBlob must be a multiple of 8");

    /// The width of this aggregate, in octets
    public static immutable Width = Bits / 8;

    /// Convenience enum
    public enum StringBufferSize = (Width * 2 + 2);

    /***************************************************************************

        Format the hash as a lowercase hex string

        Used by `std.format`.
        Does not allocate/throw if the sink does not allocate/throw.

    ***************************************************************************/

    public void toString (scope void delegate(const(char)[]) @safe sink) const
    {
        /// Used for formatting
        static immutable LHexDigits = `0123456789abcdef`;

        sink("0x");
        char[2] data;
        // retro because the data is stored in little endian
        this.data[].retro.each!(
            (bin)
            {
                data[0] = LHexDigits[bin >> 4];
                data[1] = LHexDigits[(bin & 0b0000_1111)];
                sink(data);
            });
    }

    /***************************************************************************

        Get the string representation of this hash

        Only performs one allocation.

    ***************************************************************************/

    public string toString () const
    {
        size_t idx;
        char[StringBufferSize] buffer = void;
        scope sink = (const(char)[] v) {
                buffer[idx .. idx + v.length] = v;
                idx += v.length;
            };
        this.toString(sink);
        return buffer.idup;
    }

    pure nothrow @nogc:

    /***************************************************************************

        Create a BitBlob from binary data, e.g. serialized data

        Params:
            bin  = Binary data to store in this `BitBlob`.
            isLE = `true` if the data is little endian, `false` otherwise.
                   Internally the data will be stored in little endian.

        Throws:
            If `bin.length != typeof(this).Width`

    ***************************************************************************/

    public this (scope const ubyte[] bin, bool isLE = true)
    {
        assert(bin.length == Width);
        this.data[] = bin[];
        if (!isLE)
        {
            foreach (cnt; 0 .. Width / 2)
            {
                // Not sure the frontend is clever enough to avoid bounds checks
                this.data[cnt] ^= this.data[$ - 1 - cnt];
                this.data[$ - 1 - cnt] ^= this.data[cnt];
                this.data[cnt] ^= this.data[$ - 1 - cnt];
            }
        }
    }

    /***************************************************************************

        Create a BitBlob from an hexadecimal string representation

        Params:
            hexstr = String representation of the binary data in base 16.
                     The hexadecimal prefix (0x) is optional.
                     Can be upper or lower case.

        Throws:
            If `hexstr_without_prefix.length != (typeof(this).Width * 2)`.

    ***************************************************************************/

    public this (scope const(char)[] hexstr)
    {
        enum ErrorMsg = "Wrong string size passed to ctor";
        if (hexstr.length == (Width * 2) + "0x".length)
        {
            assert(hexstr[0] == '0', ErrorMsg);
            assert(hexstr[1] == 'x' || hexstr[1] == 'X', ErrorMsg);
            hexstr = hexstr[2 .. $];
        }
        else
            assert(hexstr.length == (Width * 2), ErrorMsg);

        auto range = hexstr.byChar.map!(std.ascii.toLower!(char));
        foreach (size_t idx, chunk; range.map!(fromHex).chunks(2).retro.enumerate)
            this.data[idx] = cast(ubyte)((chunk[0] << 4) + chunk[1]);
    }

    /***************************************************************************

        Support deserialization

        Vibe.d expects the `toString`/`fromString` to be present for it to
        correctly serialize and deserialize a type.
        This allows to use this type as parameter in `vibe.web.rest` methods,
        or use it with Vibe.d's serialization module.

    ***************************************************************************/

    static auto fromString (scope const(char)[] str)
    {
        return BitBlob!(Bits)(str);
    }

    /// Store the internal data
    private ubyte[Width] data;

    /// Returns: If this BitBlob has any value
    public bool isNull () const
    {
        return this == typeof(this).init;
    }

    /// Used for sha256Of
    public inout(ubyte)[] opIndex () inout
    {
        return this.data;
    }

    /// Convenience overload
    public inout(ubyte)[] opSlice (size_t from, size_t to) inout
    {
        return this.data[from .. to];
    }

    /// Ditto
    alias opDollar = Width;

    /// Public because of a visibility bug
    public static ubyte fromHex (char c)
    {
        if (c >= '0' && c <= '9')
            return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f')
            return cast(ubyte)(10 + c - 'a');
        assert(0, "Unexpected char in string passed to BitBlob");
    }

    public int opCmp (ref const typeof(this) s) const
    {
        // Reverse because little endian
        foreach_reverse (idx, b; this.data)
            if (b != s.data[idx])
                return b - s.data[idx];
        return 0;
    }
}

pure @safe nothrow @nogc unittest
{
    alias Hash = BitBlob!256;

    Hash gen1 = GenesisBlockHashStr;
    Hash gen2 = GenesisBlockHash;
    assert(gen1.data == GenesisBlockHash);
    assert(gen1 == gen2);

    Hash gm1 = GMerkle_str;
    Hash gm2 = GMerkle_bin;
    assert(gm1.data == GMerkle_bin);
    assert(gm1 == gm2);

    Hash empty;
    assert(empty.isNull);
    assert(!gen1.isNull);

    // Test opCmp
    assert(empty < gen1);
    assert(gm1 > gen2);
}

/// Test toString
unittest
{
    import std.format;
    alias Hash = BitBlob!256;
    Hash gen1 = GenesisBlockHashStr;
    assert(format("%s", gen1) == GenesisBlockHashStr);
    assert(gen1.toString() == GenesisBlockHashStr);
}

/// Make sure `toString` does not allocate even if it's not `@nogc`
unittest
{
    import core.memory;
    import std.format;
    alias Hash = BitBlob!256;

    Hash gen1 = GenesisBlockHashStr;
    char[Hash.StringBufferSize] buffer;
    auto statsBefore = GC.stats();
    formattedWrite(buffer[], "%s", gen1);
    auto statsAfter = GC.stats();
    assert(buffer == GenesisBlockHashStr);
    assert(statsBefore.usedSize == statsAfter.usedSize);
}

/// Test initialization from big endian
@safe unittest
{
    import std.algorithm.mutation : reverse;
    ubyte[32] genesis = GenesisBlockHash;
    genesis[].reverse;
    auto h = BitBlob!(256)(genesis, false);
    assert(h.toString() == GenesisBlockHashStr);
}

version (unittest)
{
private:
    /// Bitcoin's genesis block hash
    static immutable GenesisBlockHashStr =
        "0x000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f";
    static immutable ubyte[32] GenesisBlockHash = [
        0x6f, 0xe2, 0x8c, 0x0a, 0xb6, 0xf1, 0xb3, 0x72, 0xc1, 0xa6, 0xa2, 0x46,
        0xae, 0x63, 0xf7, 0x4f, 0x93, 0x1e, 0x83, 0x65, 0xe1, 0x5a, 0x08, 0x9c,
        0x68, 0xd6, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00 ];

    /// Bitcoin's genesis block Merkle root hash
    static immutable GMerkle_str =
        "0X4A5E1E4BAAB89F3A32518A88C31BC87F618F76673E2CC77AB2127B7AFDEDA33B";
    static immutable ubyte[] GMerkle_bin = [
        0x3b, 0xa3, 0xed, 0xfd, 0x7a, 0x7b, 0x12, 0xb2, 0x7a, 0xc7, 0x2c, 0x3e,
        0x67, 0x76, 0x8f, 0x61, 0x7f, 0xc8, 0x1b, 0xc3, 0x88, 0x8a, 0x51, 0x32,
        0x3a, 0x9f, 0xb8, 0xaa, 0x4b, 0x1e, 0x5e, 0x4a ];
}
