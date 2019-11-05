# bitblob

A lightweight wrapper to represent hashes as value types.

## Example

```D
/// Alias for a 256 bits / 32 byte hash type
alias Hash = BitBlob!256;

/// Used in the following tests
enum BTCGenesisStr = `0x000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f`;

// Most functions are anotated as `nothrow`/`@nogc`/`pure`/`@safe`,
// except for the two `toString` overloads
@nogc @safe pure nothrow unittest
{
    import std.digest.sha;
    // Can be initialized from an `ubyte[32]`
    // (or `ubyte[]` of length 32)
    const Hash fromSha = sha256Of("Hello World");

    // Or from a string
    const Hash genesis = BTCGenesisStr;

    assert(!genesis.isNull());
    assert(Hash.init.isNull());

    ubyte[5] empty;
    assert(Hash.init < genesis);
    assert(genesis[0 .. 5] == empty);
}

// This cannot be nothrow/@nogc because format is not allocated as such
// However, Bitblob has tests that it does not allocate
unittest
{
    // This does not allocate
    char[Hash.StringBufferSize] buff;
    const Hash genesis = BTCGenesisStr;
    formattedWrite(buff[], "%s", genesis);
    assert(buff[] == BTCGenesisStr);
}
```

## Note on design

`BitBlob` is intended  for convenient representation
of fully computed / finalized hashes.

String representation, comparison, and seamless conversion
from string or binary representation are the focus.

Byte-level manipulation of the underlying data is not
prefered, although possible through `opSlice`.
