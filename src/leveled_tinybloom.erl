%% -------- TINY BLOOM ---------
%%
%% For sheltering relatively expensive lookups with a probabilistic check
%%
%% Uses multiple 512 byte blooms.  Can sensibly hold up to 1000 keys per array.
%% Even at 1000 keys should still offer only a 20% false positive
%%
%% Restricted to no more than 256 arrays - so can't handle more than 250K keys
%% in total
%%
%% Implemented this way to make it easy to control false positive (just by
%% setting the width).  Also only requires binary manipulations of a single
%% hash

-module(leveled_tinybloom).

-include("include/leveled.hrl").

-export([
        enter/2,
        check/2,
        empty/1
        ]).      


-include_lib("eunit/include/eunit.hrl").

%%%============================================================================
%%% Bloom API
%%%============================================================================


empty(Width) when Width =< 256 ->
    FoldFun = fun(X, Acc) -> dict:store(X, <<0:4096>>, Acc) end,
    lists:foldl(FoldFun, dict:new(), lists:seq(0, Width - 1)).

enter({hash, no_lookup}, Bloom) ->
    Bloom;
enter({hash, Hash}, Bloom) ->
    {Slot0, Q, Bit1, Bit2, Bit3} = split_hash(Hash),
    Slot = Slot0 rem dict:size(Bloom),
    BitArray0 = dict:fetch(Slot, Bloom),
    {Pre, SplitArray0, Post} = split_array(BitArray0, Q),
    FoldFun =
        fun(Bit, Arr) -> add_to_array(Bit, Arr, 1024) end,
    SplitArray1 = lists:foldl(FoldFun,
                                SplitArray0,
                                lists:usort([Bit1, Bit2, Bit3])),
    dict:store(Slot, <<Pre/binary, SplitArray1/binary, Post/binary>>, Bloom);
enter(Key, Bloom) ->
    Hash = leveled_codec:magic_hash(Key),
    enter({hash, Hash}, Bloom).

check({hash, Hash}, Bloom) ->
    {Slot0, Q, Bit1, Bit2, Bit3} = split_hash(Hash),
    Slot = Slot0 rem dict:size(Bloom),
    BitArray = dict:fetch(Slot, Bloom),
    {_Pre, SplitArray, _Post} = split_array(BitArray, Q),
    
    case getbit(Bit1, SplitArray, 1024) of
        <<0:1>> ->
            false;
        <<1:1>> ->
            case getbit(Bit2, SplitArray, 1024) of
                <<0:1>> ->
                    false;
                <<1:1>> ->
                    case getbit(Bit3, SplitArray, 1024) of
                        <<0:1>> ->
                            false;
                        <<1:1>> ->
                            true
                    end
            end
    end;
check(Key, Bloom) ->
    Hash = leveled_codec:magic_hash(Key),
    check({hash, Hash}, Bloom).


%%%============================================================================
%%% Internal Functions
%%%============================================================================

split_hash(Hash) ->
    SlotH1 = Hash band 255,
    SlotH2 = (Hash bsr 8) band 255,
    SlotH3 = (Hash bsr 16) band 255,
    SlotH4 = (Hash bsr 24) band 255,
    Slot = (SlotH1 bxor SlotH2) bxor (SlotH3 bxor SlotH4),
    Q1 = Hash band 3,
    H1 = (Hash bsr 2) band 1023,
    H2 = (Hash bsr 12) band 1023,
    H3 = (Hash bsr 22) band 1023,
    {Slot, Q1, H1, H2, H3}.

split_array(Bin, Q) ->
    case Q of
        0 ->
            <<ToUse:128/binary, Post/binary>> = Bin,
            {<<>>, ToUse, Post};
        1 ->
            <<Pre:128/binary, ToUse:128/binary, Post/binary>> = Bin,
            {Pre, ToUse, Post};
        2 ->
            <<Pre:256/binary, ToUse:128/binary, Post/binary>> = Bin,
            {Pre, ToUse, Post};
        3 ->
            <<Pre:384/binary, ToUse:128/binary>> = Bin,
            {Pre, ToUse, <<>>}
    end.

add_to_array(Bit, BitArray, ArrayLength) ->
    RestLen = ArrayLength - Bit - 1,
    <<Head:Bit/bitstring,
        _B:1/bitstring,
        Rest:RestLen/bitstring>> = BitArray,
    <<Head/bitstring, 1:1, Rest/bitstring>>.

getbit(Bit, BitArray, ArrayLength) ->
    RestLen = ArrayLength - Bit - 1,
    <<_Head:Bit/bitstring,
        B:1/bitstring,
        _Rest:RestLen/bitstring>> = BitArray,
    B.


%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

simple_test() ->
    N = 4000,
    W = 4,
    KLin = lists:map(fun(X) -> "Key_" ++
                                integer_to_list(X) ++
                                integer_to_list(random:uniform(100)) ++
                                binary_to_list(crypto:rand_bytes(2))
                                end,
                        lists:seq(1, N)),
    KLout = lists:map(fun(X) ->
                            "NotKey_" ++
                            integer_to_list(X) ++
                            integer_to_list(random:uniform(100)) ++
                            binary_to_list(crypto:rand_bytes(2))
                            end,
                        lists:seq(1, N)),
    SW0_PH = os:timestamp(),
    lists:foreach(fun(X) -> erlang:phash2(X) end, KLin),
    io:format(user,
                "~nNative hash function hashes ~w keys in ~w microseconds~n",
                [N, timer:now_diff(os:timestamp(), SW0_PH)]),
    SW0_MH = os:timestamp(),
    lists:foreach(fun(X) -> leveled_codec:magic_hash(X) end, KLin),
    io:format(user,
                "~nMagic hash function hashes ~w keys in ~w microseconds~n",
                [N, timer:now_diff(os:timestamp(), SW0_MH)]),
    
    SW1 = os:timestamp(),
    Bloom = lists:foldr(fun enter/2, empty(W), KLin),
    io:format(user,
                "~nAdding ~w keys to bloom took ~w microseconds~n",
                [N, timer:now_diff(os:timestamp(), SW1)]),
    
    SW2 = os:timestamp(),
    lists:foreach(fun(X) -> ?assertMatch(true, check(X, Bloom)) end, KLin),
    io:format(user,
                "~nChecking ~w keys in bloom took ~w microseconds~n",
                [N, timer:now_diff(os:timestamp(), SW2)]),
    
    SW3 = os:timestamp(),
    FP = lists:foldr(fun(X, Acc) -> case check(X, Bloom) of
                                        true -> Acc + 1;
                                        false -> Acc
                                    end end,
                        0,
                        KLout),
    io:format(user,
                "~nChecking ~w keys out of bloom took ~w microseconds " ++
                    "with ~w false positive rate~n",
                [N, timer:now_diff(os:timestamp(), SW3), FP / N]),
    ?assertMatch(true, FP < (N div 4)).



-endif.