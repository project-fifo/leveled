%% -------- PENCILLER MANIFEST ---------
%%
%% The manifest is an ordered set of files for each level to be used to find
%% which file is relevant for a given key or range lookup at a given level.
%%


-module(leveled_manifest).

-include("include/leveled.hrl").

-export([
        new_manifest/0,
        open_manifest/1,
        copy_manifest/1,
        load_manifest/3,
        close_manifest/2,
        save_manifest/2,
        get_manifest_sqn/1,
        key_lookup/3,
        range_lookup/4,
        merge_lookup/4,
        insert_manifest_entry/4,
        remove_manifest_entry/4,
        switch_manifest_entry/4,
        mergefile_selector/2,
        add_snapshot/3,
        release_snapshot/2,
        ready_to_delete/2,
        check_for_work/2,
        is_basement/2,
        levelzero_present/1
        ]).      

-export([
        filepath/2
        ]).

-include_lib("eunit/include/eunit.hrl").

-define(MANIFEST_FILEX, "man").
-define(MANIFEST_FP, "ledger_manifest").
-define(MAX_LEVELS, 8).

-record(manifest, {levels,
                        % an array of lists or trees representing the manifest
                    manifest_sqn = 0 :: integer(),
                        % The current manifest SQN
                    snapshots :: list(),
                        % A list of snaphots (i.e. clones)
                    min_snapshot_sqn = 0 :: integer(),
                        % The smallest snapshot manifest SQN in the snapshot
                        % list
                    pending_deletes :: dict:dict(),
                        % a dictionary mapping keys (filenames) to SQN when
                        % the deletion was made
                    basement :: integer()
                        % Currently the lowest level (the largest number)
                    }).      

%%%============================================================================
%%% API
%%%============================================================================

new_manifest() ->
    #manifest{
        levels = array:new([{size, ?MAX_LEVELS + 1}, {default, []}]), 
        manifest_sqn = 0, 
        snapshots = [],
        pending_deletes = dict:new(),
        basement = 0
    }.    

open_manifest(RootPath) ->
    % Open the manifest in the file path which has the highest SQN, and will
    % open without error
    ManifestPath = filepath(RootPath, manifest),
    {ok, Filenames} = file:list_dir(ManifestPath),
    CurrRegex = "nonzero_(?<MSN>[0-9]+)\\." ++ ?MANIFEST_FILEX,
    ExtractSQNFun =
        fun(FN, Acc) ->
            case re:run(FN, CurrRegex, [{capture, ['MSN'], list}]) of
                nomatch ->
                    Acc;
                {match, [Int]} when is_list(Int) ->
                    Acc ++ [list_to_integer(Int)]
            end
        end,
    ValidManSQNs = lists:reverse(lists:sort(lists:foldl(ExtractSQNFun,
                                                        [],
                                                        Filenames))),
    open_manifestfile(RootPath, ValidManSQNs).
    
copy_manifest(Manifest) ->
    % Copy the manifest ensuring anything only the master process should care
    % about is switched to undefined
    Manifest#manifest{snapshots = undefined, pending_deletes = undefined}.

load_manifest(Manifest, PidFun, SQNFun) ->
    UpdateLevelFun =
        fun(LevelIdx, {AccMaxSQN, AccMan}) ->
            L0 = array:get(LevelIdx, AccMan#manifest.levels),
            {L1, SQN1} = load_level(LevelIdx, L0, PidFun, SQNFun),
            UpdLevels = array:set(LevelIdx, L1, AccMan#manifest.levels),
            {max(AccMaxSQN, SQN1), AccMan#manifest{levels = UpdLevels}}
        end,
    lists:foldl(UpdateLevelFun, {0, Manifest},
                    lists:seq(0, Manifest#manifest.basement)).

close_manifest(Manifest, CloseEntryFun) ->
    CloseLevelFun =
        fun(LevelIdx) ->
            Level = array:get(LevelIdx, Manifest#manifest.levels),
            close_level(LevelIdx, Level, CloseEntryFun)
        end,
    lists:foreach(CloseLevelFun, lists:seq(0, Manifest#manifest.basement)).

save_manifest(Manifest, RootPath) ->
    FP = filepath(RootPath, Manifest#manifest.manifest_sqn, current_manifest),
    ManBin = term_to_binary(Manifest),
    CRC = erlang:crc32(ManBin),
    ok = file:write_file(FP, <<CRC:32/integer, ManBin/binary>>).

insert_manifest_entry(Manifest, ManSQN, LevelIdx, Entry) ->
    Levels = Manifest#manifest.levels,
    Level = array:get(LevelIdx, Levels),
    UpdLevel = add_entry(LevelIdx, Level, Entry),
    Basement = max(LevelIdx, Manifest#manifest.basement),
    Manifest#manifest{levels = array:set(LevelIdx, UpdLevel, Levels),
                        basement = Basement,
                        manifest_sqn = ManSQN}.

remove_manifest_entry(Manifest, ManSQN, LevelIdx, Entry) ->
    Levels = Manifest#manifest.levels,
    Level = array:get(LevelIdx, Levels),
    UpdLevel = remove_entry(LevelIdx, Level, Entry),
    DelFun =
        fun(E, Acc) ->
            dict:store(E#manifest_entry.filename, ManSQN, Acc)
        end,
    Entries = 
        case is_list(Entry) of
            true ->
                Entry;
            false ->
                [Entry]
        end,
    PendingDeletes = lists:foldl(DelFun,
                                    Manifest#manifest.pending_deletes,
                                    Entries),
    UpdLevels = array:set(LevelIdx, UpdLevel, Levels),
    case is_empty(LevelIdx, UpdLevel) of
        true ->
            Manifest#manifest{levels = UpdLevels,
                                basement = get_basement(UpdLevels),
                                manifest_sqn = ManSQN,
                                pending_deletes = PendingDeletes};
        false ->
            Manifest#manifest{levels = UpdLevels,
                                manifest_sqn = ManSQN,
                                pending_deletes = PendingDeletes}
    end.

switch_manifest_entry(Manifest, ManSQN, SrcLevel, Entry) ->
    % Move to level below - so needs to be removed but not marked as a
    % pending deletion
    Levels = Manifest#manifest.levels,
    Level = array:get(SrcLevel, Levels),
    UpdLevel = remove_entry(SrcLevel, Level, Entry),
    UpdLevels = array:set(SrcLevel, UpdLevel, Levels),
    insert_manifest_entry(Manifest#manifest{levels = UpdLevels},
                            ManSQN,
                            SrcLevel + 1,
                            Entry).

get_manifest_sqn(Manifest) ->
    Manifest#manifest.manifest_sqn.

key_lookup(Manifest, LevelIdx, Key) ->
    case LevelIdx > Manifest#manifest.basement of
        true ->
            false;
        false ->
            key_lookup_level(LevelIdx,
                                array:get(LevelIdx, Manifest#manifest.levels),
                                Key)
    end.

range_lookup(Manifest, LevelIdx, StartKey, EndKey) ->
    MakePointerFun =
        fun(M) ->
            {next, M, StartKey}
        end,
    range_lookup_int(Manifest, LevelIdx, StartKey, EndKey, MakePointerFun).

merge_lookup(Manifest, LevelIdx, StartKey, EndKey) ->
    MakePointerFun =
        fun(M) ->
            {next, M, all}
        end,
    range_lookup_int(Manifest, LevelIdx, StartKey, EndKey, MakePointerFun).



%% An algorithm for discovering which files to merge ....
%% We can find the most optimal file:
%% - The one with the most overlapping data below?
%% - The one that overlaps with the fewest files below?
%% - The smallest file?
%% We could try and be fair in some way (merge oldest first)
%% Ultimately, there is a lack of certainty that being fair or optimal is
%% genuinely better - eventually every file has to be compacted.
%%
%% Hence, the initial implementation is to select files to merge at random
mergefile_selector(Manifest, LevelIdx) ->
    Level = array:get(LevelIdx, Manifest#manifest.levels),
    lists:nth(random:uniform(length(Level)), Level).

add_snapshot(Manifest, Pid, Timeout) ->
    {MegaNow, SecNow, _} = os:timestamp(),
    TimeToTimeout = MegaNow * 1000000 + SecNow + Timeout,
    SnapEntry = {Pid, Manifest#manifest.manifest_sqn, TimeToTimeout},
    SnapList0 = [SnapEntry|Manifest#manifest.snapshots],
    ManSQN = Manifest#manifest.manifest_sqn,
    case Manifest#manifest.min_snapshot_sqn of
        0 ->
            
            Manifest#manifest{snapshots = SnapList0,
                                min_snapshot_sqn = ManSQN};
        N ->
            N0 = min(N, ManSQN),
            Manifest#manifest{snapshots = SnapList0, min_snapshot_sqn = N0}
    end.

release_snapshot(Manifest, Pid) ->
    FilterFun =
        fun({P, SQN, TS}, {Acc, MinSQN}) ->
            case P of
                Pid ->
                    {Acc, min(SQN, MinSQN)};
                _ ->
                    {[{P, SQN, TS}|Acc], min(SQN, MinSQN)}
            end
        end,
    {SnapList0, MinSnapSQN} = lists:foldl(FilterFun,
                                            {[], infinity},
                                            Manifest#manifest.snapshots),
    leveled_log:log("P0004", [SnapList0]),
    case SnapList0 of
        [] ->
            Manifest#manifest{snapshots = SnapList0,
                                min_snapshot_sqn = 0};
        _ ->
            Manifest#manifest{snapshots = SnapList0,
                                min_snapshot_sqn = MinSnapSQN}
    end.

ready_to_delete(Manifest, Filename) ->
    ChangeSQN = dict:fetch(Filename, Manifest#manifest.pending_deletes),
    case Manifest#manifest.min_snapshot_sqn >= ChangeSQN of
        true ->
            % Every snapshot is looking at a version of history after this
            % was removed
            PDs = dict:erase(Filename, Manifest#manifest.pending_deletes),
            {true, Manifest#manifest{pending_deletes = PDs}};
        false ->
            {false, Manifest}
    end.

check_for_work(Manifest, Thresholds) ->
    CheckLevelFun =
        fun({LevelIdx, MaxCount}, {AccL, AccC}) ->
            case LevelIdx > Manifest#manifest.basement of
                true ->
                    {AccL, AccC};
                false ->
                    Level = array:get(LevelIdx, Manifest#manifest.levels),
                    S = size(LevelIdx, Level),
                    case S > MaxCount of
                        true ->
                            {[LevelIdx|AccL], AccC + S - MaxCount};
                        false ->
                            {AccL, AccC}
                    end
            end
        end,
    lists:foldr(CheckLevelFun, {[], 0}, Thresholds).    

is_basement(Manifest, Level) ->
    Level >= Manifest#manifest.basement.

levelzero_present(Manifest) ->
    not is_empty(0, array:get(0, Manifest#manifest.levels)).

%%%============================================================================
%%% Internal Functions
%%%============================================================================

%% All these internal functions that work on a level are also passed LeveIdx
%% even if this is not presently relevant.  Currnetly levels are lists, but
%% future branches may make lower levels trees or skiplists to improve fetch
%% efficiency

load_level(_LevelIdx, Level, PidFun, SQNFun) ->
    LevelLoadFun =
        fun(ME, {L_Out, L_MaxSQN}) ->
            FN = ME#manifest_entry.filename,
            P = PidFun(FN),
            SQN = SQNFun(P),
            {[ME#manifest_entry{owner=P}|L_Out], max(SQN, L_MaxSQN)}
        end,
    lists:foldr(LevelLoadFun, {[], 0}, Level).

close_level(_LevelIdx, Level, CloseEntryFun) ->
    lists:foreach(CloseEntryFun, Level).

is_empty(_LevelIdx, []) ->
    true;
is_empty(_LevelIdx, _Level) ->
    false.

size(_LevelIdx, Level) ->
    length(Level).

add_entry(_LevelIdx, Level, Entries) when is_list(Entries) ->
    lists:sort(Level ++ Entries);
add_entry(_LevelIdx, Level, Entry) ->
    lists:sort([Entry|Level]).

remove_entry(_LevelIdx, Level, Entries) when is_list(Entries) ->
    % We're assuming we're removing a sorted sublist
    RemLength = length(Entries),
    RemStart = lists:nth(1, Entries),
    remove_section(Level, RemStart#manifest_entry.start_key, RemLength - 1);
remove_entry(_LevelIdx, Level, Entry) ->
    remove_section(Level, Entry#manifest_entry.start_key, 0).

remove_section(Level, StartKey, Length) ->
    PredFun =
        fun(E) ->
            E#manifest_entry.start_key < StartKey
        end,
    {Pre, Rest} = lists:splitwith(PredFun, Level),
    Post = lists:nthtail(length(Rest) - Length, Rest),
    Pre ++ Post.


key_lookup_level(_LevelIdx, [], _Key) ->
    false;
key_lookup_level(LevelIdx, [Entry|Rest], Key) ->
    case Entry#manifest_entry.end_key >= Key of
        true ->
            case Key >= Entry#manifest_entry.start_key of
                true ->
                    Entry#manifest_entry.owner;
                false ->
                    false
            end;
        false ->
            key_lookup_level(LevelIdx, Rest, Key)
    end.

range_lookup_int(Manifest, LevelIdx, StartKey, EndKey, MakePointerFun) ->
    Range = 
        case LevelIdx > Manifest#manifest.basement of
            true ->
                [];
            false ->
                range_lookup_level(LevelIdx,
                                    array:get(LevelIdx,
                                                Manifest#manifest.levels),
                                    StartKey,
                                    EndKey)
        end,
    lists:map(MakePointerFun, Range).
    
range_lookup_level(_LevelIdx, Level, QStartKey, QEndKey) ->
    BeforeFun =
        fun(M) ->
            QStartKey > M#manifest_entry.end_key
        end,
    NotAfterFun =
        fun(M) ->
            not leveled_codec:endkey_passed(QEndKey,
                                            M#manifest_entry.start_key)
        end,
    {_Before, MaybeIn} = lists:splitwith(BeforeFun, Level),
    {In, _After} = lists:splitwith(NotAfterFun, MaybeIn),
    In.

get_basement(Levels) ->
    GetBaseFun =
        fun(L, Acc) ->
            case is_empty(L, array:get(L, Levels)) of
                false ->
                    max(L, Acc);
                true ->
                    Acc
            end
        end,
    lists:foldl(GetBaseFun, 0, lists:seq(0, ?MAX_LEVELS)).


filepath(RootPath, manifest) ->
    MFP = RootPath ++ "/" ++ ?MANIFEST_FP ++ "/",
    filelib:ensure_dir(MFP),
    MFP.

filepath(RootPath, NewMSN, current_manifest) ->
    filepath(RootPath, manifest)  ++ "nonzero_"
                ++ integer_to_list(NewMSN) ++ "." ++ ?MANIFEST_FILEX.


open_manifestfile(_RootPath, []) ->
    leveled_log:log("P0013", []),
    new_manifest();
open_manifestfile(_RootPath, [0]) ->
    leveled_log:log("P0013", []),
    new_manifest();
open_manifestfile(RootPath, [TopManSQN|Rest]) ->
    CurrManFile = filepath(RootPath, TopManSQN, current_manifest),
    {ok, FileBin} = file:read_file(CurrManFile),
    <<CRC:32/integer, BinaryOfTerm/binary>> = FileBin,
    case erlang:crc32(BinaryOfTerm) of
        CRC ->
            leveled_log:log("P0012", [TopManSQN]),
            binary_to_term(BinaryOfTerm);
        _ ->
            leveled_log:log("P0033", [CurrManFile, "crc wonky"]),
            open_manifestfile(RootPath, Rest)
    end.

%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

initial_setup() -> 
    E1 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld1"}, "K8"},
                            end_key={i, "Bucket1", {"Idx1", "Fld9"}, "K93"},
                            filename="Z1",
                            owner="pid_z1"},
    E2 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld9"}, "K97"},
                                end_key={o, "Bucket1", "K71", null},
                                filename="Z2",
                                owner="pid_z2"},
    E3 = #manifest_entry{start_key={o, "Bucket1", "K75", null},
                            end_key={o, "Bucket1", "K993", null},
                            filename="Z3",
                            owner="pid_z3"},
    E4 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld1"}, "K8"},
                            end_key={i, "Bucket1", {"Idx1", "Fld7"}, "K93"},
                            filename="Z4",
                            owner="pid_z4"},
    E5 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld7"}, "K97"},
                            end_key={o, "Bucket1", "K78", null},
                            filename="Z5",
                            owner="pid_z5"},
    E6 = #manifest_entry{start_key={o, "Bucket1", "K81", null},
                            end_key={o, "Bucket1", "K996", null},
                            filename="Z6",
                            owner="pid_z6"},
    
    Man0 = new_manifest(),
    % insert_manifest_entry(Manifest, ManSQN, Level, Entry)
    Man1 = insert_manifest_entry(Man0, 1, 1, E1),
    Man2 = insert_manifest_entry(Man1, 1, 1, E2),
    Man3 = insert_manifest_entry(Man2, 1, 1, E3),
    Man4 = insert_manifest_entry(Man3, 1, 2, E4),
    Man5 = insert_manifest_entry(Man4, 1, 2, E5),
    Man6 = insert_manifest_entry(Man5, 1, 2, E6),
    {Man0, Man1, Man2, Man3, Man4, Man5, Man6}.

changeup_setup(Man6) ->
    E1 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld1"}, "K8"},
                            end_key={i, "Bucket1", {"Idx1", "Fld9"}, "K93"},
                            filename="Z1",
                            owner="pid_z1"},
    E2 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld9"}, "K97"},
                                end_key={o, "Bucket1", "K71", null},
                                filename="Z2",
                                owner="pid_z2"},
    E3 = #manifest_entry{start_key={o, "Bucket1", "K75", null},
                            end_key={o, "Bucket1", "K993", null},
                            filename="Z3",
                            owner="pid_z3"},
                            
    E1_2 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld4"}, "K8"},
                            end_key={i, "Bucket1", {"Idx1", "Fld9"}, "K62"},
                            owner="pid_y1",
                            filename="Y1"},
    E2_2 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld9"}, "K67"},
                            end_key={o, "Bucket1", "K45", null},
                            owner="pid_y2",
                            filename="Y2"},
    E3_2 = #manifest_entry{start_key={o, "Bucket1", "K47", null},
                            end_key={o, "Bucket1", "K812", null},
                            owner="pid_y3",
                            filename="Y3"},
    E4_2 = #manifest_entry{start_key={o, "Bucket1", "K815", null},
                            end_key={o, "Bucket1", "K998", null},
                            owner="pid_y4",
                            filename="Y4"},
    
    Man7 = remove_manifest_entry(Man6, 2, 1, E1),
    Man8 = remove_manifest_entry(Man7, 2, 1, E2),
    Man9 = remove_manifest_entry(Man8, 2, 1, E3),
    
    Man10 = insert_manifest_entry(Man9, 2, 1, E1_2),
    Man11 = insert_manifest_entry(Man10, 2, 1, E2_2),
    Man12 = insert_manifest_entry(Man11, 2, 1, E3_2),
    Man13 = insert_manifest_entry(Man12, 2, 1, E4_2),
    % remove_manifest_entry(Manifest, ManSQN, Level, Entry)
    
    {Man7, Man8, Man9, Man10, Man11, Man12, Man13}.

keylookup_manifest_test() ->
    {Man0, Man1, Man2, Man3, _Man4, _Man5, Man6} = initial_setup(),
    LK1_1 = {o, "Bucket1", "K711", null},
    LK1_2 = {o, "Bucket1", "K70", null},
    LK1_3 = {o, "Bucket1", "K71", null},
    LK1_4 = {o, "Bucket1", "K75", null},
    LK1_5 = {o, "Bucket1", "K76", null},
    
    ?assertMatch(false, key_lookup(Man0, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man1, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man2, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man3, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man6, 1, LK1_1)),
    
    ?assertMatch("pid_z2", key_lookup(Man6, 1, LK1_2)),
    ?assertMatch("pid_z2", key_lookup(Man6, 1, LK1_3)),
    ?assertMatch("pid_z3", key_lookup(Man6, 1, LK1_4)),
    ?assertMatch("pid_z3", key_lookup(Man6, 1, LK1_5)),
    
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_2)),
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_3)),
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_4)),
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_5)),
    
    {_Man7, _Man8, _Man9, _Man10, _Man11, _Man12,
        Man13} = changeup_setup(Man6),
    
    ?assertMatch(false, key_lookup(Man0, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man1, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man2, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man3, 1, LK1_1)),
    ?assertMatch(false, key_lookup(Man6, 1, LK1_1)),
    
    ?assertMatch("pid_z2", key_lookup(Man6, 1, LK1_2)),
    ?assertMatch("pid_z2", key_lookup(Man6, 1, LK1_3)),
    ?assertMatch("pid_z3", key_lookup(Man6, 1, LK1_4)),
    ?assertMatch("pid_z3", key_lookup(Man6, 1, LK1_5)),
    
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_2)),
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_3)),
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_4)),
    ?assertMatch("pid_z5", key_lookup(Man6, 2, LK1_5)),
    
    ?assertMatch("pid_y3", key_lookup(Man13, 1, LK1_4)),
    ?assertMatch("pid_z5", key_lookup(Man13, 2, LK1_4)).


rangequery_manifest_test() ->
    {_Man0, _Man1, _Man2, _Man3, _Man4, _Man5, Man6} = initial_setup(),
    
    PidMapFun =
        fun(Pointer) ->
            {next, ME, _SK} = Pointer,
            ME#manifest_entry.owner
        end,
    
    SK1 = {o, "Bucket1", "K711", null},
    EK1 = {o, "Bucket1", "K999", null},
    RL1_1 = lists:map(PidMapFun, range_lookup(Man6, 1, SK1, EK1)),
    ?assertMatch(["pid_z3"], RL1_1),
    RL1_2 = lists:map(PidMapFun, range_lookup(Man6, 2, SK1, EK1)),
    ?assertMatch(["pid_z5", "pid_z6"], RL1_2),
    SK2 = {i, "Bucket1", {"Idx1", "Fld8"}, null},
    EK2 = {i, "Bucket1", {"Idx1", "Fld8"}, null},
    RL2_1 = lists:map(PidMapFun, range_lookup(Man6, 1, SK2, EK2)),
    ?assertMatch(["pid_z1"], RL2_1),
    RL2_2 = lists:map(PidMapFun, range_lookup(Man6, 2, SK2, EK2)),
    ?assertMatch(["pid_z5"], RL2_2),
    
    SK3 = {o, "Bucket1", "K994", null},
    EK3 = {o, "Bucket1", "K995", null},
    RL3_1 = lists:map(PidMapFun, range_lookup(Man6, 1, SK3, EK3)),
    ?assertMatch([], RL3_1),
    RL3_2 = lists:map(PidMapFun, range_lookup(Man6, 2, SK3, EK3)),
    ?assertMatch(["pid_z6"], RL3_2),
    
    {_Man7, _Man8, _Man9, _Man10, _Man11, _Man12,
        Man13} = changeup_setup(Man6),
    
    RL1_1A = lists:map(PidMapFun, range_lookup(Man6, 1, SK1, EK1)),
    ?assertMatch(["pid_z3"], RL1_1A),
    RL2_1A = lists:map(PidMapFun, range_lookup(Man6, 1, SK2, EK2)),
    ?assertMatch(["pid_z1"], RL2_1A),
    RL3_1A = lists:map(PidMapFun, range_lookup(Man6, 1, SK3, EK3)),
    ?assertMatch([], RL3_1A),
     
    RL1_1B = lists:map(PidMapFun, range_lookup(Man13, 1, SK1, EK1)),
    ?assertMatch(["pid_y3", "pid_y4"], RL1_1B),
    RL2_1B = lists:map(PidMapFun, range_lookup(Man13, 1, SK2, EK2)),
    ?assertMatch(["pid_y1"], RL2_1B),
    RL3_1B = lists:map(PidMapFun, range_lookup(Man13, 1, SK3, EK3)),
    ?assertMatch(["pid_y4"], RL3_1B).

levelzero_present_test() ->
    E0 = #manifest_entry{start_key={i, "Bucket1", {"Idx1", "Fld1"}, "K8"},
                            end_key={o, "Bucket1", "Key996", null},
                            filename="Z0",
                            owner="pid_z0"},
     
    Man0 = new_manifest(),
    ?assertMatch(false, levelzero_present(Man0)),
    % insert_manifest_entry(Manifest, ManSQN, Level, Entry)
    Man1 = insert_manifest_entry(Man0, 1, 0, E0),
    ?assertMatch(true, levelzero_present(Man1)).

-endif.