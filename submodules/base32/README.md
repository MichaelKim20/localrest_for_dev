# Base32 in D

This library provides a module for encoding and decoding the Base32 format, which is defined in [RFC 4648](http://tools.ietf.org/html/rfc4648).
The implementation is very affected by [Phobos' `std.base64`](http://dlang.org/phobos/std_base64.html).

## Descriptions

### To be simple

```d
import base32;

ubyte[] data = [0xde, 0xad, 0xbe, 0xef, 0x01, 0x23];
const(char)[] encoded = Base32.encode(data);
assert(encoded == "32W353YBEM======");

ubyte[] decoded = Base32.decode("32W353YBEM======");
assert(decoded == [0xde, 0xad, 0xbe, 0xef, 0x01, 0x23]);
```

`encode()` takes a `ubyte` array to encode and returns a `char` array which contains the Base32 encoded result.
If a `char` array which represents a Base32 encoded string is passed to `decode()`, the characters will be decoded and the resulting `ubyte` array will be returned.

### More generally

Actually, these functions take two parameters, *input* and *output*.
You can use several types of arguments: an **array** or an **InputRange** as *input*, and, an **array** or an **OutputRange** as *output*.
For example:

```d
import std.stdio : writeln;
auto n = Base32.encode(data, &writeln!char);

auto array = Base32.decode(SomeInputRangeWithLength(encoded), new ubyte[LARGE]);
```

Note that the OutputRange versions return not the data but the output length.
On the other hand, if you use an array as an output buffer, it must be large enough to contain the result.
There are convenient functions to calculate the length, `encodeLength()` and `decodeLength()`.
Both of them take an input length and return the length which the output buffer must have.

```d
auto buffer = new dchar[Base32.encodeLength(data.length)];
Base32.encode(data, buffer);
```

### Varieties of the Base32 encodings

Although the above examples describe the most standard Base32 encoding, this module can handle some kinds of Base32 encodings.
That is, the standard one containing A-Z, 2-7 and =, and "base32hex" containing 0-9, A-V, and =.
Both are found in the RFC.
They are aliased as `Base32` and `Base32Hex` respectively, by default.

Moreover, no padding "=" versions, which are not in the RFC, are also available.
These, however, should be brought manually.
To activate these varieties, two template parameters `UseHex` and `UsePad` are available.
For example:

```d
alias Base32NoPad = Base32Impl!(UseHex.no, UsePad.no);
alias Base32HexNoPad = Base32Impl!(UseHex.yes, UsePad.no);
```

The `NoPad` versions neither output the paddings when encoding nor accept them when decoding.

### CTFEability

Of course all of the functions are CTFEable.
