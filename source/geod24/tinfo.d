module geod24.tinfo;

public struct TInfo
{
    public string id;

    static @property ref tinfo () nothrow
    {
        static TInfo val;
        return val;
    }

}

public @property ref TInfo tinfo () nothrow
{
    return TInfo.tinfo;
}

