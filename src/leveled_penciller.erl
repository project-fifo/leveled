%% -------- PENCILLER ---------
%%
%% The penciller is responsible for writing and re-writing the ledger - a
%% persisted, ordered view of non-recent Keys and Metadata which have been
%% added to the store.
%% - The penciller maintains a manifest of all the files within the current
%% Ledger. 
%% - The Penciller provides re-write (compaction) work up to be managed by
%% the Penciller's Clerk
%% - The Penciller can be cloned and maintains a register of clones who have
%% requested snapshots of the Ledger
%% - The accepts new dumps (in the form of a leveled_tree accomponied by
%% an array of hash-listing binaries) from the Bookie, and responds either 'ok'
%% to the bookie if the information is accepted nad the Bookie can refresh its
%% memory, or 'returned' if the bookie must continue without refreshing as the
%% Penciller is not currently able to accept the update (potentially due to a
%% backlog of compaction work)
%% - The Penciller's persistence of the ledger may not be reliable, in that it
%% may lose data but only in sequence from a particular sequence number.  On
%% startup the Penciller will inform the Bookie of the highest sequence number
%% it has, and the Bookie should load any missing data from that point out of
%% the journal.
%%
%% -------- LEDGER ---------
%%
%% The Ledger is divided into many levels
%% - L0: New keys are received from the Bookie and and kept in the levelzero
%% cache, until that cache is the size of a SST file, and it is then persisted
%% as a SST file at this level.  L0 SST files can be larger than the normal 
%% maximum size - so we don't have to consider problems of either having more
%% than one L0 file (and handling what happens on a crash between writing the
%% files when the second may have overlapping sequence numbers), or having a
%% remainder with overlapping in sequence numbers in memory after the file is
%% written.   Once the persistence is completed, the L0 cache can be erased.
%% There can be only one SST file at Level 0, so the work to merge that file
%% to the lower level must be the highest priority, as otherwise writes to the
%% ledger will stall, when there is next a need to persist.
%% - L1 TO L7: May contain multiple processes managing non-overlapping SST
%% files.  Compaction work should be sheduled if the number of files exceeds
%% the target size of the level, where the target size is 8 ^ n.
%%
%% The most recent revision of a Key can be found by checking each level until
%% the key is found.  To check a level the correct file must be sought from the
%% manifest for that level, and then a call is made to that file.  If the Key
%% is not present then every level should be checked.
%%
%% If a compaction change takes the size of a level beyond the target size,
%% then compaction work for that level + 1 should be added to the compaction
%% work queue.
%% Compaction work is fetched by the Penciller's Clerk because:
%% - it has timed out due to a period of inactivity
%% - it has been triggered by the a cast to indicate the arrival of high
%% priority compaction work
%% The Penciller's Clerk (which performs compaction worker) will always call
%% the Penciller to find out the highest priority work currently required
%% whenever it has either completed work, or a timeout has occurred since it
%% was informed there was no work to do.
%%
%% When the clerk picks work it will take the current manifest, and the
%% Penciller assumes the manifest sequence number is to be incremented.
%% When the clerk has completed the work it can request that the manifest
%% change be committed by the Penciller.  The commit is made through changing
%% the filename of the new manifest - so the Penciller is not held up by the
%% process of wiritng a file, just altering file system metadata.
%%
%% ---------- PUSH ----------
%%
%% The Penciller must support the PUSH of a dump of keys from the Bookie.  The
%% call to PUSH should be immediately acknowledged, and then work should be
%% completed to merge the cache update into the L0 cache.
%%
%% The Penciller MUST NOT accept a new PUSH if the Clerk has commenced the
%% conversion of the current L0 cache into a SST file, but not completed this
%% change.  The Penciller in this case returns the push, and the Bookie should
%% continue to grow the cache before trying again.
%%
%% ---------- FETCH ----------
%%
%% On request to fetch a key the Penciller should look first in the in-memory
%% L0 tree, then look in the SST files Level by Level (including level 0),
%% consulting the Manifest to determine which file should be checked at each
%% level.
%%
%% ---------- SNAPSHOT ----------
%%
%% Iterators may request a snapshot of the database.  A snapshot is a cloned
%% Penciller seeded not from disk, but by the in-memory L0 gb_tree and the
%% in-memory manifest, allowing for direct reference for the SST file processes.
%%
%% Clones formed to support snapshots are registered by the Penciller, so that
%% SST files valid at the point of the snapshot until either the iterator is
%% completed or has timed out.
%%
%% ---------- ON STARTUP ----------
%%
%% On Startup the Bookie with ask the Penciller to initiate the Ledger first.
%% To initiate the Ledger the must consult the manifest, and then start a SST
%% management process for each file in the manifest.
%%
%% The penciller should then try and read any Level 0 file which has the
%% manifest sequence number one higher than the last store in the manifest.
%%
%% The Bookie will ask the Inker for any Keys seen beyond that sequence number
%% before the startup of the overall store can be completed.
%%
%% ---------- ON SHUTDOWN ----------
%%
%% On a controlled shutdown the Penciller should attempt to write any in-memory
%% ETS table to a L0 SST file, assuming one is nto already pending.  If one is
%% already pending then the Penciller will not persist this part of the Ledger.
%%
%% ---------- FOLDER STRUCTURE ----------
%%
%% The following folders are used by the Penciller
%% $ROOT/ledger/ledger_manifest/ - used for keeping manifest files
%% $ROOT/ledger/ledger_files/ - containing individual SST files
%%
%% In larger stores there could be a large number of files in the ledger_file
%% folder - perhaps o(1000).  It is assumed that modern file systems should
%% handle this efficiently.
%%
%% ---------- COMPACTION & MANIFEST UPDATES ----------
%%
%% The Penciller can have one and only one Clerk for performing compaction
%% work.  When the Clerk has requested and taken work, it should perform the
%5 compaction work starting the new SST process to manage the new Ledger state
%% and then write a new manifest file that represents that state with using
%% the next Manifest sequence number as the filename:
%% - nonzero_<ManifestSQN#>.pnd
%% 
%% The Penciller on accepting the change should rename the manifest file to -
%% - nonzero_<ManifestSQN#>.crr
%%
%% On startup, the Penciller should look for the nonzero_*.crr file with the
%% highest such manifest sequence number.  This will be started as the
%% manifest, together with any _0_0.sst file found at that Manifest SQN.
%% Level zero files are not kept in the persisted manifest, and adding a L0
%% file does not advanced the Manifest SQN.
%%
%% The pace at which the store can accept updates will be dependent on the
%% speed at which the Penciller's Clerk can merge files at lower levels plus
%% the time it takes to merge from Level 0.  As if a clerk has commenced
%% compaction work at a lower level and then immediately a L0 SST file is
%% written the Penciller will need to wait for this compaction work to
%% complete and the L0 file to be compacted before the ETS table can be
%% allowed to again reach capacity
%%
%% The writing of L0 files do not require the involvement of the clerk.
%% The L0 files are prompted directly by the penciller when the in-memory tree
%% has reached capacity.  This places the penciller in a levelzero_pending
%% state, and in this state it must return new pushes.  Once the SST file has
%% been completed it will confirm completion to the penciller which can then
%% revert the levelzero_pending state, add the file to the manifest and clear
%% the current level zero in-memory view.
%%


-module(leveled_penciller).

-behaviour(gen_server).

-include("include/leveled.hrl").

-export([
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

-export([
        pcl_start/1,
        pcl_pushmem/2,
        pcl_fetchlevelzero/2,
        pcl_fetch/2,
        pcl_fetch/3,
        pcl_fetchkeys/5,
        pcl_fetchnextkey/5,
        pcl_checksequencenumber/3,
        pcl_workforclerk/1,
        pcl_manifestchange/2,
        pcl_confirml0complete/4,
        pcl_confirmdelete/3,
        pcl_close/1,
        pcl_doom/1,
        pcl_releasesnapshot/2,
        pcl_registersnapshot/5,
        pcl_getstartupsequencenumber/1]).

-export([
        sst_rootpath/1,
        sst_filename/3]).

-export([
        clean_testdir/1]).

-include_lib("eunit/include/eunit.hrl").

-define(LEVEL_SCALEFACTOR, [{0, 0}, {1, 8}, {2, 64}, {3, 512},
                            {4, 4096}, {5, 32768}, {6, 262144},
                            {7, infinity}]).
-define(MAX_LEVELS, 8).
-define(MAX_WORK_WAIT, 300).
-define(MANIFEST_FP, "ledger_manifest").
-define(FILES_FP, "ledger_files").
-define(CURRENT_FILEX, "crr").
-define(PENDING_FILEX, "pnd").
-define(MEMTABLE, mem).
-define(MAX_TABLESIZE, 28000). % This is less than max - but COIN_SIDECOUNT
-define(SUPER_MAX_TABLE_SIZE, 40000).
-define(PROMPT_WAIT_ONL0, 5).
-define(WORKQUEUE_BACKLOG_TOLERANCE, 4).
-define(COIN_SIDECOUNT, 5).
-define(SLOW_FETCH, 20000).
-define(ITERATOR_SCANWIDTH, 4).
-define(SNAPSHOT_TIMEOUT_LONG, 3600).
-define(SNAPSHOT_TIMEOUT_SHORT, 600).

-record(state, {manifest, % a manifest record from the leveled_manifest module
                persisted_sqn = 0 :: integer(), % The highest SQN persisted
                
                ledger_sqn = 0 :: integer(), % The highest SQN added to L0
                root_path = "../test" :: string(),
                
                clerk :: pid() | undefined,
                
                levelzero_pending = false :: boolean(),
                levelzero_constructor :: pid() | undefined,
                levelzero_cache = [] :: list(), % a list of trees
                levelzero_size = 0 :: integer(),
                levelzero_maxcachesize :: integer() | undefined,
                levelzero_cointoss = false :: boolean(),
                levelzero_index, % An array
                
                is_snapshot = false :: boolean(),
                snapshot_fully_loaded = false :: boolean(),
                source_penciller :: pid() | undefined,
                levelzero_astree :: list() | undefined,
                
                work_ongoing = false :: boolean(), % i.e. compaction work
                work_backlog = false :: boolean(), % i.e. compaction work
                
                head_timing :: tuple() | undefined}).

-type penciller_options() :: #penciller_options{}.
-type bookies_memory() :: {tuple()|empty_cache,
                            % array:array()|empty_array,
                            any()|empty_array, % Issue of type compatability with OTP16
                            integer()|infinity,
                            integer()}.
-type pcl_state() :: #state{}.

%%%============================================================================
%%% API
%%%============================================================================

-spec pcl_start(penciller_options()) -> {ok, pid()}.
%% @doc
%% Start a penciller using a penciller options record.  The start_snapshot
%% option should be used if this is to be a clone of an existing penciller,
%% otherwise the penciller will look in root path for a manifest and
%% associated sst files to start-up from a previous persisted state.
%%
%% When starting a clone a query can also be passed.  This prevents the whole
%% Level Zero memory space from being copied to the snapshot, instead the
%% query is run against the level zero space and just the query results are
%5 copied into the clone.  
pcl_start(PCLopts) ->
    gen_server:start(?MODULE, [PCLopts], []).

-spec pcl_pushmem(pid(), bookies_memory()) -> ok|returned.
%% @doc
%% Load the contents of the Bookie's memory of recent additions to the Ledger
%% to the Ledger proper.
%%
%% The load is made up of a cache in the form of a leveled_skiplist tuple (or
%% the atom empty_cache if no cache is present), an index of entries in the
%% skiplist in the form of leveled_pmem index (or empty_index), the minimum
%% sequence number in the cache and the maximum sequence number.
%%
%% If the penciller does not have capacity for the pushed cache it will
%% respond with the atom 'returned'.  This is a signal to hold the memory
%% at the Bookie, and try again soon.  This normally only occurs when there
%% is a backlog of merges - so the bookie should backoff for longer each time.
pcl_pushmem(Pid, LedgerCache) ->
    %% Bookie to dump memory onto penciller
    gen_server:call(Pid, {push_mem, LedgerCache}, infinity).

-spec pcl_fetchlevelzero(pid(), integer()) -> tuple().
%% @doc
%% Allows a single slot of the penciller's levelzero cache to be fetched.  The
%% levelzero cache can be up to 40K keys - sending this to the process that is
%% persisting this in a SST file in a single cast will lock the process for
%% 30-40ms.  This allows that process to fetch this slot by slot, so that
%% this is split into a series of smaller events.
%%
%% The return value will be a leveled_skiplist that forms that part of the
%% cache
pcl_fetchlevelzero(Pid, Slot) ->
    %% Timeout to cause crash of L0 file when it can't get the close signal
    %% as it is deadlocked making this call.
    %%
    %% If the timeout gets hit outside of close scenario the Penciller will
    %% be stuck in L0 pending
    gen_server:call(Pid, {fetch_levelzero, Slot}, 60000).

-spec pcl_fetch(pid(), tuple()) -> {tuple(), tuple()}|not_present.
%% @doc
%% Fetch a key, return the first (highest SQN) occurrence of that Key along
%% with  the value.
%%
%% The Key needs to be hashable (i.e. have a tag which indicates that the key
%% can be looked up) - index entries are not hashable for example.
%%
%% If the hash is already knonw, call pcl_fetch/3 as magic_hash is a
%% relatively expensive hash function
pcl_fetch(Pid, Key) ->
    Hash = leveled_codec:magic_hash(Key),
    if
        Hash /= no_lookup ->
            gen_server:call(Pid, {fetch, Key, Hash}, infinity)
    end.

-spec pcl_fetch(pid(), tuple(), integer()) -> {tuple(), tuple()}|not_present.
%% @doc
%% Fetch a key, return the first (highest SQN) occurrence of that Key along
%% with  the value.
%%
%% Hash should be result of leveled_codec:magic_hash(Key)
pcl_fetch(Pid, Key, Hash) ->
    gen_server:call(Pid, {fetch, Key, Hash}, infinity).

-spec pcl_fetchkeys(pid(), tuple(), tuple(), fun(), any()) -> any().
%% @doc
%% Run a range query between StartKey and EndKey (inclusive).  This will cover
%% all keys in the range - so must only be run against snapshots of the
%% penciller to avoid blocking behaviour.
%%
%% Comparison with the upper-end of the range (EndKey) is done using
%% leveled_codec:endkey_passed/2 - so use nulls within the tuple to manage
%% the top of the range.  Comparison with the start of the range is based on
%% Erlang term order.
pcl_fetchkeys(Pid, StartKey, EndKey, AccFun, InitAcc) ->
    gen_server:call(Pid,
                    {fetch_keys, StartKey, EndKey, AccFun, InitAcc, -1},
                    infinity).

-spec pcl_fetchnextkey(pid(), tuple(), tuple(), fun(), any()) -> any().
%% @doc
%% Run a range query between StartKey and EndKey (inclusive).  This has the
%% same constraints as pcl_fetchkeys/5, but will only return the first key
%% found in erlang term order.
pcl_fetchnextkey(Pid, StartKey, EndKey, AccFun, InitAcc) ->
    gen_server:call(Pid,
                    {fetch_keys, StartKey, EndKey, AccFun, InitAcc, 1},
                    infinity).

-spec pcl_checksequencenumber(pid(), tuple(), integer()) -> boolean().
%% @doc
%% Check if the sequence number of the passed key is not replaced by a change
%% after the passed sequence number.  Will return true if the Key is present
%% and either is equal to, or prior to the passed SQN.
%%
%% If the key is not present, it will be assumed that a higher sequence number
%% tombstone once existed, and false will be returned.
pcl_checksequencenumber(Pid, Key, SQN) ->
    Hash = leveled_codec:magic_hash(Key),
    if
        Hash /= no_lookup ->
            gen_server:call(Pid, {check_sqn, Key, Hash, SQN}, infinity)
    end.

-spec pcl_workforclerk(pid()) -> ok.
%% @doc
%% A request from the clerk to check for work.  If work is present the
%% Penciller will cast back to the clerk, no response is sent to this
%% request.
pcl_workforclerk(Pid) ->
    gen_server:cast(Pid, work_for_clerk).

-spec pcl_manifestchange(pid(), tuple()) -> ok.
%% @doc
%% Provide a manifest record (i.e. the output of the leveled_pmanifest module)
%% that is required to beocme the new manifest.
pcl_manifestchange(Pid, Manifest) ->
    gen_server:cast(Pid, {manifest_change, Manifest}).

-spec pcl_confirml0complete(pid(), string(), tuple(), tuple()) -> ok.
%% @doc
%% Allows a SST writer that has written a L0 file to confirm that the file 
%% is now complete, so the filename and key ranges can be added to the 
%% manifest and the file can be used in place of the in-memory levelzero
%% cache.
pcl_confirml0complete(Pid, FN, StartKey, EndKey) ->
    gen_server:cast(Pid, {levelzero_complete, FN, StartKey, EndKey}).

-spec pcl_confirmdelete(pid(), string(), pid()) -> ok.
%% @doc
%% Poll from a delete_pending file requesting a message if the file is now
%% ready for deletion (i.e. all snapshots which depend on the file have
%% finished)
pcl_confirmdelete(Pid, FileName, FilePid) ->
    gen_server:cast(Pid, {confirm_delete, FileName, FilePid}).

-spec pcl_getstartupsequencenumber(pid()) -> integer().
%% @doc
%% At startup the penciller will get the largest sequence number that is 
%% within the persisted files.  This function allows for this sequence number
%% to be fetched - so that it can be used to determine parts of the Ledger
%% which  may have been lost in the last shutdown (so that the ledger can
%% be reloaded from that point in the Journal)
pcl_getstartupsequencenumber(Pid) ->
    gen_server:call(Pid, get_startup_sqn, infinity).

-spec pcl_registersnapshot(pid(),
                            pid(),
                            no_lookup|{tuple(), tuple()}|undefined,
                            bookies_memory(),
                            boolean())
                                -> {ok, pcl_state()}.
%% @doc
%% Register a snapshot of the penciller, returning a state record from the
%% penciller for the snapshot to use as its LoopData
pcl_registersnapshot(Pid, Snapshot, Query, BookiesMem, LR) ->
    gen_server:call(Pid,
                    {register_snapshot, Snapshot, Query, BookiesMem, LR},
                    infinity).

-spec pcl_releasesnapshot(pid(), pid()) -> ok.
%% @doc
%% Inform the primary penciller that a snapshot is finished, so that the 
%% penciller can allow deletes to proceed if appropriate.
pcl_releasesnapshot(Pid, Snapshot) ->
    gen_server:cast(Pid, {release_snapshot, Snapshot}).

-spec pcl_close(pid()) -> ok.
%% @doc
%% Close the penciller neatly, trying to persist to disk anything in the memory
pcl_close(Pid) ->
    gen_server:call(Pid, close, 60000).

-spec pcl_doom(pid()) -> {ok, list()}.
%% @doc
%% Close the penciller neatly, trying to persist to disk anything in the memory
%% Return a list of filepaths from where files exist for this penciller (should
%% the calling process which to erase the store).
pcl_doom(Pid) ->
    gen_server:call(Pid, doom, 60000).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([PCLopts]) ->
    leveled_rand:seed(),
    case {PCLopts#penciller_options.root_path,
            PCLopts#penciller_options.start_snapshot,
            PCLopts#penciller_options.snapshot_query,
            PCLopts#penciller_options.bookies_mem} of
        {undefined, _Snapshot=true, Query, BookiesMem} ->
            SrcPenciller = PCLopts#penciller_options.source_penciller,
            LongRunning = PCLopts#penciller_options.snapshot_longrunning,
            {ok, State} = pcl_registersnapshot(SrcPenciller, 
                                                self(), 
                                                Query, 
                                                BookiesMem, 
                                                LongRunning),
            leveled_log:log("P0001", [self()]),
            {ok, State#state{is_snapshot=true,
                                source_penciller=SrcPenciller}};
        {_RootPath, _Snapshot=false, _Q, _BM} ->
            start_from_file(PCLopts)
    end.    
    

handle_call({push_mem, {LedgerTable, PushedIdx, MinSQN, MaxSQN}},
                From,
                State=#state{is_snapshot=Snap}) when Snap == false ->
    % The push_mem process is as follows:
    %
    % 1 - Receive a cache.  The cache has four parts: a tree of keys and
    % values, an array of 256 binaries listing the hashes present in the
    % tree, a min SQN and a max SQN
    %
    % 2 - Check to see if there is a levelzero file pending.  If so, the
    % update must be returned.  If not the update can be accepted
    %
    % 3 - The Penciller can now reply to the Bookie to show if the push has
    % been accepted
    %
    % 4 - Update the cache:
    % a) Append the cache to the list
    % b) Add each of the 256 hash-listing binaries to the master L0 index array
    %
    % Check the approximate size of the cache.  If it is over the maximum size,
    % trigger a background L0 file write and update state of levelzero_pending.
    case State#state.levelzero_pending or State#state.work_backlog of
        true ->
            leveled_log:log("P0018", [returned,
                                        State#state.levelzero_pending,
                                        State#state.work_backlog]),
            {reply, returned, State};
        false ->
            leveled_log:log("P0018", [ok, false, false]),
            PushedTree =
                case is_tuple(LedgerTable) of
                    true ->
                        LedgerTable;
                    false ->
                        leveled_tree:from_orderedset(LedgerTable,
                                                        ?CACHE_TYPE)
                end,
            % Reply must happen after the table has been converted
            gen_server:reply(From, ok), 
            {noreply,
                update_levelzero(State#state.levelzero_size,
                                    {PushedTree, PushedIdx, MinSQN, MaxSQN},
                                    State#state.ledger_sqn,
                                    State#state.levelzero_cache,
                                    State)}
    end;
handle_call({fetch, Key, Hash}, _From, State) ->
    {R, HeadTimer} = timed_fetch_mem(Key,
                                        Hash,
                                        State#state.manifest,
                                        State#state.levelzero_cache,
                                        State#state.levelzero_index,
                                        State#state.head_timing),
    {reply, R, State#state{head_timing=HeadTimer}};
handle_call({check_sqn, Key, Hash, SQN}, _From, State) ->
    {reply,
        compare_to_sqn(plain_fetch_mem(Key,
                                        Hash,
                                        State#state.manifest,
                                        State#state.levelzero_cache,
                                        State#state.levelzero_index),
                        SQN),
        State};
handle_call({fetch_keys, StartKey, EndKey, AccFun, InitAcc, MaxKeys},
                _From,
                State=#state{snapshot_fully_loaded=Ready})
                                                        when Ready == true ->
    SW = os:timestamp(),
    L0AsList =
        case State#state.levelzero_astree of
            undefined ->
                leveled_pmem:merge_trees(StartKey,
                                            EndKey,
                                            State#state.levelzero_cache,
                                            leveled_tree:empty(?CACHE_TYPE));
            List ->
                List
        end,
    leveled_log:log_randomtimer("P0037",
                                [State#state.levelzero_size],
                                SW,
                                0.01),
    SetupFoldFun =
        fun(Level, Acc) ->
            Pointers = leveled_pmanifest:range_lookup(State#state.manifest,
                                                        Level,
                                                        StartKey,
                                                        EndKey),
            case Pointers of
                [] -> Acc;
                PL -> Acc ++ [{Level, PL}]
            end
        end,
    SSTiter = lists:foldl(SetupFoldFun, [], lists:seq(0, ?MAX_LEVELS - 1)),
    
    Acc = keyfolder({L0AsList, SSTiter},
                        {StartKey, EndKey},
                        {AccFun, InitAcc},
                        MaxKeys),
    
    {reply, Acc, State#state{levelzero_astree = L0AsList}};
handle_call(get_startup_sqn, _From, State) ->
    {reply, State#state.persisted_sqn, State};
handle_call({register_snapshot, Snapshot, Query, BookiesMem, LR}, _From, State) ->
    % Register and load a snapshot
    %
    % For setup of the snapshot to be efficient should pass a query
    % of (StartKey, EndKey) - this will avoid a fully copy of the penciller's
    % memory being required to be trasnferred to the clone.  However, this
    % will not be a valid clone for fetch
    Timeout = 
        case LR of
            true ->
                ?SNAPSHOT_TIMEOUT_LONG;
            false ->
                ?SNAPSHOT_TIMEOUT_SHORT
        end,

    Manifest0 = leveled_pmanifest:add_snapshot(State#state.manifest,
                                                Snapshot,
                                                Timeout),
    
    {BookieIncrTree, BookieIdx, MinSQN, MaxSQN} = BookiesMem,
    LM1Cache =
        case BookieIncrTree of
            empty_cache ->
                leveled_tree:empty(?CACHE_TYPE);
            _ ->
                BookieIncrTree
        end,

    CloneState = 
        case Query of
            no_lookup ->
                {UpdMaxSQN, UpdSize, L0Cache} =
                    leveled_pmem:add_to_cache(State#state.levelzero_size,
                                                {LM1Cache, MinSQN, MaxSQN},
                                                State#state.ledger_sqn,
                                                State#state.levelzero_cache),
                #state{levelzero_cache = L0Cache,
                        ledger_sqn = UpdMaxSQN,
                        levelzero_size = UpdSize,
                        persisted_sqn = State#state.persisted_sqn};
            {StartKey, EndKey} ->
                SW = os:timestamp(),
                L0AsTree =
                    leveled_pmem:merge_trees(StartKey,
                                                EndKey,
                                                State#state.levelzero_cache,
                                                LM1Cache),
                leveled_log:log_randomtimer("P0037",
                                            [State#state.levelzero_size],
                                            SW,
                                            0.1),
                #state{levelzero_astree = L0AsTree,
                        ledger_sqn = MaxSQN,
                        persisted_sqn = State#state.persisted_sqn};
            undefined ->
                {UpdMaxSQN, UpdSize, L0Cache} =
                    leveled_pmem:add_to_cache(State#state.levelzero_size,
                                                {LM1Cache, MinSQN, MaxSQN},
                                                State#state.ledger_sqn,
                                                State#state.levelzero_cache),
                L0Index =
                    case BookieIdx of
                        empty_index ->
                            State#state.levelzero_index;
                        _ ->
                            leveled_pmem:add_to_index(BookieIdx,
                                                        State#state.levelzero_index,
                                                        length(L0Cache))
                    end,
                #state{levelzero_cache = L0Cache,
                        levelzero_index = L0Index,
                        levelzero_size = UpdSize,
                        ledger_sqn = UpdMaxSQN,
                        persisted_sqn = State#state.persisted_sqn}
        end,
    ManifestClone = leveled_pmanifest:copy_manifest(State#state.manifest),
    {reply,
        {ok,
            CloneState#state{snapshot_fully_loaded=true,
                                manifest=ManifestClone}},
        State#state{manifest = Manifest0}};
handle_call({fetch_levelzero, Slot}, _From, State) ->
    {reply, lists:nth(Slot, State#state.levelzero_cache), State};
handle_call(close, _From, State) ->
    {stop, normal, ok, State};
handle_call(doom, _From, State) ->
    leveled_log:log("P0030", []),
    ManifestFP = State#state.root_path ++ "/" ++ ?MANIFEST_FP ++ "/",
    FilesFP = State#state.root_path ++ "/" ++ ?FILES_FP ++ "/",
    {stop, normal, {ok, [ManifestFP, FilesFP]}, State}.

handle_cast({manifest_change, NewManifest}, State) ->
    NewManSQN = leveled_pmanifest:get_manifest_sqn(NewManifest),
    ok = leveled_pclerk:clerk_promptdeletions(State#state.clerk, NewManSQN),
    UpdManifest = leveled_pmanifest:merge_snapshot(State#state.manifest,
                                                    NewManifest),
    {noreply, State#state{manifest = UpdManifest, work_ongoing=false}};
handle_cast({release_snapshot, Snapshot}, State) ->
    Manifest0 = leveled_pmanifest:release_snapshot(State#state.manifest,
                                                   Snapshot),
    leveled_log:log("P0003", [Snapshot]),
    {noreply, State#state{manifest=Manifest0}};
handle_cast({confirm_delete, Filename, FilePid}, State=#state{is_snapshot=Snap})
                                                        when Snap == false ->    
    case State#state.work_ongoing of 
        false ->
            R2D = leveled_pmanifest:ready_to_delete(State#state.manifest, 
                                                    Filename),
            case R2D of
                {true, M0} ->
                    leveled_log:log("P0005", [Filename]),
                    ok = leveled_sst:sst_deleteconfirmed(FilePid),
                    {noreply, State#state{manifest=M0}};
                {false, _M0} ->
                    {noreply, State}
            end;
        true ->
            % If there is ongoing work, then we can't safely update the pidmap
            % as any change will be reverted when the manifest is passed back
            % from the Clerk
            {noreply, State}
    end;
handle_cast({levelzero_complete, FN, StartKey, EndKey}, State) ->
    leveled_log:log("P0029", []),
    ManEntry = #manifest_entry{start_key=StartKey,
                                end_key=EndKey,
                                owner=State#state.levelzero_constructor,
                                filename=FN},
    ManifestSQN = leveled_pmanifest:get_manifest_sqn(State#state.manifest) + 1,
    UpdMan = leveled_pmanifest:insert_manifest_entry(State#state.manifest,
                                                    ManifestSQN,
                                                    0,
                                                    ManEntry),
    % Prompt clerk to ask about work - do this for every L0 roll
    UpdIndex = leveled_pmem:clear_index(State#state.levelzero_index),
    ok = leveled_pclerk:clerk_prompt(State#state.clerk),
    {noreply, State#state{levelzero_cache=[],
                            levelzero_index=UpdIndex,
                            levelzero_pending=false,
                            levelzero_constructor=undefined,
                            levelzero_size=0,
                            manifest=UpdMan,
                            persisted_sqn=State#state.ledger_sqn}};
handle_cast(work_for_clerk, State) ->
    case {State#state.levelzero_pending, State#state.work_ongoing} of
        {false, false} ->
            % TODO - as part of supervision tree and retry work:
            % Need to check for work_ongoing as well as levelzero_pending as
            % there may be a race that could lead to the clerk doing the same
            % thing twice.
            %
            % This has implications though if we auto-restart the pclerk in the
            % future, without altering this state - it may never be able to
            % request work due to ongoing work that crashed the previous clerk
            %
            % Perhaps the pclerk should not be restarted because of this, and
            % the failure should ripple up
            {WL, WC} = leveled_pmanifest:check_for_work(State#state.manifest,
                                                        ?LEVEL_SCALEFACTOR),
            case WC of
                0 ->
                    {noreply, State#state{work_backlog=false}};
                N when N > ?WORKQUEUE_BACKLOG_TOLERANCE ->
                    leveled_log:log("P0024", [N, true]),
                    [TL|_Tail] = WL,
                    ok = leveled_pclerk:clerk_push(State#state.clerk, 
                                                    {TL, State#state.manifest}),
                    {noreply,
                        State#state{work_backlog=true, work_ongoing=true}};
                N ->
                    leveled_log:log("P0024", [N, false]),
                    [TL|_Tail] = WL,
                    ok = leveled_pclerk:clerk_push(State#state.clerk, 
                                                    {TL, State#state.manifest}),
                    {noreply,
                        State#state{work_backlog=false, work_ongoing=true}}
            end;
        _ ->
            {noreply, State}
    end.


handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State=#state{is_snapshot=Snap}) when Snap == true ->
    ok = pcl_releasesnapshot(State#state.source_penciller, self()),
    leveled_log:log("P0007", [Reason]),   
    ok;
terminate(Reason, State) ->
    %% Level 0 files lie outside of the manifest, and so if there is no L0
    %% file present it is safe to write the current contents of memory.  If
    %% there is a L0 file present - then the memory can be dropped (it is
    %% recoverable from the ledger, and there should not be a lot to recover
    %% as presumably the ETS file has been recently flushed, hence the presence
    %% of a L0 file).
    %%
    %% The penciller should close each file in the manifest, and cast a close
    %% on the clerk.
    ok = leveled_pclerk:clerk_close(State#state.clerk),
    
    leveled_log:log("P0008", [Reason]),
    L0_Present = leveled_pmanifest:key_lookup(State#state.manifest, 0, all),
    L0_Left = State#state.levelzero_size > 0,
    case {State#state.levelzero_pending, L0_Present, L0_Left} of
        {false, false, true} ->
            L0Pid = roll_memory(State, true),
            ok = leveled_sst:sst_close(L0Pid);
        StatusTuple ->
            leveled_log:log("P0010", [StatusTuple])
    end,
    
    % Tidy shutdown of individual files
    EntryCloseFun =
        fun(ME) ->
            case is_record(ME, manifest_entry) of
                true ->
                    ok = leveled_sst:sst_close(ME#manifest_entry.owner);
                false ->
                    {_SK, ME0} = ME,
                    ok = leveled_sst:sst_close(ME0#manifest_entry.owner)
            end
        end,
    leveled_pmanifest:close_manifest(State#state.manifest, EntryCloseFun),
    leveled_log:log("P0011", []),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Path functions
%%%============================================================================

sst_rootpath(RootPath) ->
    FP = RootPath ++ "/" ++ ?FILES_FP,
    filelib:ensure_dir(FP ++ "/"),
    FP.

sst_filename(ManSQN, Level, Count) ->
    lists:flatten(io_lib:format("./~w_~w_~w.sst", [ManSQN, Level, Count])).
    

%%%============================================================================
%%% Internal functions
%%%============================================================================


start_from_file(PCLopts) ->
    RootPath = PCLopts#penciller_options.root_path,
    MaxTableSize = case PCLopts#penciller_options.max_inmemory_tablesize of
                        undefined ->
                            ?MAX_TABLESIZE;
                        M ->
                            M
                    end,
    
    {ok, MergeClerk} = leveled_pclerk:clerk_new(self(), RootPath),
    
    CoinToss = PCLopts#penciller_options.levelzero_cointoss,
    % Used to randomly defer the writing of L0 file.  Intended to help with
    % vnode syncronisation issues (e.g. stop them all by default merging to
    % level zero concurrently)
    
    InitState = #state{clerk=MergeClerk,
                        root_path=RootPath,
                        levelzero_maxcachesize=MaxTableSize,
                        levelzero_cointoss=CoinToss,
                        levelzero_index=leveled_pmem:new_index()},
    
    %% Open manifest
    Manifest0 = leveled_pmanifest:open_manifest(RootPath),
    OpenFun =
        fun(FN) ->
            {ok,
                Pid,
                {_FK, _LK}} = leveled_sst:sst_open(sst_rootpath(RootPath), FN),
            Pid
        end,
    SQNFun = fun leveled_sst:sst_getmaxsequencenumber/1,
    {MaxSQN, Manifest1} = leveled_pmanifest:load_manifest(Manifest0,
                                                            OpenFun,
                                                            SQNFun),
    leveled_log:log("P0014", [MaxSQN]),
    ManSQN = leveled_pmanifest:get_manifest_sqn(Manifest1),
    leveled_log:log("P0035", [ManSQN]),
    %% Find any L0 files
    L0FN = sst_filename(ManSQN + 1, 0, 0),
    case filelib:is_file(filename:join(sst_rootpath(RootPath), L0FN)) of
        true ->
            leveled_log:log("P0015", [L0FN]),
            L0Open = leveled_sst:sst_open(sst_rootpath(RootPath), L0FN),
            {ok, L0Pid, {L0StartKey, L0EndKey}} = L0Open,
            L0SQN = leveled_sst:sst_getmaxsequencenumber(L0Pid),
            L0Entry = #manifest_entry{start_key = L0StartKey,
                                        end_key = L0EndKey,
                                        filename = L0FN,
                                        owner = L0Pid},
            Manifest2 = leveled_pmanifest:insert_manifest_entry(Manifest1,
                                                                ManSQN + 1,
                                                                0,
                                                                L0Entry),
            leveled_log:log("P0016", [L0SQN]),
            LedgerSQN = max(MaxSQN, L0SQN),
            {ok,
                InitState#state{manifest = Manifest2,
                                    ledger_sqn = LedgerSQN,
                                    persisted_sqn = LedgerSQN}};
        false ->
            leveled_log:log("P0017", []),
            {ok,
                InitState#state{manifest = Manifest1,
                                    ledger_sqn = MaxSQN,
                                    persisted_sqn = MaxSQN}}
    end.


update_levelzero(L0Size, {PushedTree, PushedIdx, MinSQN, MaxSQN},
                                                LedgerSQN, L0Cache, State) ->
    SW = os:timestamp(),
    Update = leveled_pmem:add_to_cache(L0Size,
                                        {PushedTree, MinSQN, MaxSQN},
                                        LedgerSQN,
                                        L0Cache),
    UpdL0Index = leveled_pmem:add_to_index(PushedIdx,
                                            State#state.levelzero_index,
                                            length(L0Cache) + 1),
    
    {UpdMaxSQN, NewL0Size, UpdL0Cache} = Update,
    if
        UpdMaxSQN >= LedgerSQN ->
            UpdState = State#state{levelzero_cache=UpdL0Cache,
                                    levelzero_size=NewL0Size,
                                    levelzero_index=UpdL0Index,
                                    ledger_sqn=UpdMaxSQN},
            CacheTooBig = NewL0Size > State#state.levelzero_maxcachesize,
            CacheMuchTooBig = NewL0Size > ?SUPER_MAX_TABLE_SIZE,
            L0Free = not leveled_pmanifest:levelzero_present(State#state.manifest),
            RandomFactor =
                case State#state.levelzero_cointoss of
                    true ->
                        case leveled_rand:uniform(?COIN_SIDECOUNT) of
                            1 ->
                                true;
                            _ ->
                                false
                        end;
                    false ->
                        true
                end,
            NoPendingManifestChange = not State#state.work_ongoing,
            JitterCheck = RandomFactor or CacheMuchTooBig,
            case {CacheTooBig, L0Free, JitterCheck, NoPendingManifestChange} of
                {true, true, true, true}  ->
                    L0Constructor = roll_memory(UpdState, false),
                    leveled_log:log_timer("P0031", [], SW),
                    UpdState#state{levelzero_pending=true,
                                    levelzero_constructor=L0Constructor};
                _ ->
                    leveled_log:log_timer("P0031", [], SW),
                    UpdState
            end
    end.


%% Casting a large object (the levelzero cache) to the gen_server did not lead
%% to an immediate return as expected.  With 32K keys in the TreeList it could
%% take around 35-40ms.
%%
%% To avoid blocking this gen_server, the SST file can request each item of the
%% cache one at a time.
%%
%% The Wait is set to false to use a cast when calling this in normal operation
%% where as the Wait of true is used at shutdown

roll_memory(State, false) ->
    ManSQN = leveled_pmanifest:get_manifest_sqn(State#state.manifest) + 1,
    RootPath = sst_rootpath(State#state.root_path),
    FileName = sst_filename(ManSQN, 0, 0),
    leveled_log:log("P0019", [FileName, State#state.ledger_sqn]),
    PCL = self(),
    FetchFun = fun(Slot) -> pcl_fetchlevelzero(PCL, Slot) end,
    R = leveled_sst:sst_newlevelzero(RootPath,
                                        FileName,
                                        length(State#state.levelzero_cache),
                                        FetchFun,
                                        PCL,
                                        State#state.ledger_sqn),
    {ok, Constructor, _} = R,
    Constructor;
roll_memory(State, true) ->
    ManSQN = leveled_pmanifest:get_manifest_sqn(State#state.manifest) + 1,
    RootPath = sst_rootpath(State#state.root_path),
    FileName = sst_filename(ManSQN, 0, 0),
    FetchFun = fun(Slot) -> lists:nth(Slot, State#state.levelzero_cache) end,
    KVList = leveled_pmem:to_list(length(State#state.levelzero_cache),
                                    FetchFun),
    R = leveled_sst:sst_new(RootPath,
                            FileName,
                            0,
                            KVList,
                            State#state.ledger_sqn),
    {ok, Constructor, _} = R,
    Constructor.

timed_fetch_mem(Key, Hash, Manifest, L0Cache, L0Index, HeadTimer) ->
    SW = os:timestamp(),
    {R, Level} = fetch_mem(Key, Hash, Manifest, L0Cache, L0Index),
    UpdHeadTimer =
        case R of
            not_present ->
                leveled_log:head_timing(HeadTimer, SW, Level, not_present);
            _ ->
                leveled_log:head_timing(HeadTimer, SW, Level, found)
        end,
    {R, UpdHeadTimer}.

plain_fetch_mem(Key, Hash, Manifest, L0Cache, L0Index) ->
    R = fetch_mem(Key, Hash, Manifest, L0Cache, L0Index),
    element(1, R).

fetch_mem(Key, Hash, Manifest, L0Cache, L0Index) ->
    PosList = leveled_pmem:check_index(Hash, L0Index),
    L0Check = leveled_pmem:check_levelzero(Key, Hash, PosList, L0Cache),
    case L0Check of
        {false, not_found} ->
            fetch(Key, Hash, Manifest, 0, fun timed_sst_get/4);
        {true, KV} ->
            {KV, 0}
    end.

fetch(_Key, _Hash, _Manifest, ?MAX_LEVELS + 1, _FetchFun) ->
    {not_present, basement};
fetch(Key, Hash, Manifest, Level, FetchFun) ->
    case leveled_pmanifest:key_lookup(Manifest, Level, Key) of
        false ->
            fetch(Key, Hash, Manifest, Level + 1, FetchFun);
        FP ->
            case FetchFun(FP, Key, Hash, Level) of
                not_present ->
                    fetch(Key, Hash, Manifest, Level + 1, FetchFun);
                ObjectFound ->
                    {ObjectFound, Level}
            end
    end.
    
timed_sst_get(PID, Key, Hash, Level) ->
    SW = os:timestamp(),
    R = leveled_sst:sst_get(PID, Key, Hash),
    T0 = timer:now_diff(os:timestamp(), SW),
    log_slowfetch(T0, R, PID, Level, ?SLOW_FETCH).

log_slowfetch(T0, R, PID, Level, FetchTolerance) ->
    case {T0, R} of
        {T, R} when T < FetchTolerance ->
            R;
        {T, not_present} ->
            leveled_log:log("PC016", [PID, T, Level, not_present]),
            not_present;
        {T, R} ->
            leveled_log:log("PC016", [PID, T, Level, found]),
            R
    end.

compare_to_sqn(Obj, SQN) ->
    case Obj of
        not_present ->
            false;
        Obj ->
            SQNToCompare = leveled_codec:strip_to_seqonly(Obj),
            if
                SQNToCompare > SQN ->
                    false;
                true ->
                    true
            end
    end.


%% Looks to find the best choice for the next key across the levels (other
%% than in-memory table)
%% In finding the best choice, the next key in a given level may be a next
%% block or next file pointer which will need to be expanded

find_nextkey(QueryArray, StartKey, EndKey) ->
    find_nextkey(QueryArray,
                    0,
                    {null, null},
                    StartKey,
                    EndKey,
                    ?ITERATOR_SCANWIDTH).

find_nextkey(_QueryArray, LCnt, {null, null}, _StartKey, _EndKey, _Width)
                                            when LCnt > ?MAX_LEVELS ->
    % The array has been scanned wihtout finding a best key - must be
    % exhausted - respond to indicate no more keys to be found by the
    % iterator
    no_more_keys;
find_nextkey(QueryArray, LCnt, {BKL, BestKV}, _StartKey, _EndKey, _Width)
                                            when LCnt > ?MAX_LEVELS ->
    % All levels have been scanned, so need to remove the best result from
    % the array, and return that array along with the best key/sqn/status
    % combination
    {BKL, [BestKV|Tail]} = lists:keyfind(BKL, 1, QueryArray),
    {lists:keyreplace(BKL, 1, QueryArray, {BKL, Tail}), BestKV};
find_nextkey(QueryArray, LCnt, {BestKeyLevel, BestKV},
                                                StartKey, EndKey, Width) ->
    % Get the next key at this level
    {NextKey, RestOfKeys} = case lists:keyfind(LCnt, 1, QueryArray) of
                                    false ->
                                        {null, null};
                                    {LCnt, []} ->
                                        {null, null};
                                    {LCnt, [NK|ROfKs]} ->
                                        {NK, ROfKs}
                                end,
    % Compare the next key at this level with the best key
    case {NextKey, BestKeyLevel, BestKV} of
        {null, BKL, BKV} ->
            % There is no key at this level - go to the next level
            find_nextkey(QueryArray,
                            LCnt + 1,
                            {BKL, BKV},
                            StartKey, EndKey, Width);
        {{next, Owner, _SK}, BKL, BKV} ->
            % The first key at this level is pointer to a file - need to query
            % the file to expand this level out before proceeding
            Pointer = {next, Owner, StartKey, EndKey},
            UpdList = leveled_sst:expand_list_by_pointer(Pointer,
                                                            RestOfKeys,
                                                            Width),
            NewEntry = {LCnt, UpdList},
            % Need to loop around at this level (LCnt) as we have not yet
            % examined a real key at this level
            find_nextkey(lists:keyreplace(LCnt, 1, QueryArray, NewEntry),
                            LCnt,
                            {BKL, BKV},
                            StartKey, EndKey, Width);
        {{pointer, SSTPid, Slot, PSK, PEK}, BKL, BKV} ->
            % The first key at this level is pointer within a file  - need to
            % query the file to expand this level out before proceeding
            Pointer = {pointer, SSTPid, Slot, PSK, PEK},
            UpdList = leveled_sst:expand_list_by_pointer(Pointer,
                                                            RestOfKeys,
                                                            Width),
            NewEntry = {LCnt, UpdList},
            % Need to loop around at this level (LCnt) as we have not yet
            % examined a real key at this level
            find_nextkey(lists:keyreplace(LCnt, 1, QueryArray, NewEntry),
                            LCnt,
                            {BKL, BKV},
                            StartKey, EndKey, Width);
        {{Key, Val}, null, null} ->
            % No best key set - so can assume that this key is the best key,
            % and check the lower levels
            find_nextkey(QueryArray,
                            LCnt + 1,
                            {LCnt, {Key, Val}},
                            StartKey, EndKey, Width);
        {{Key, Val}, _BKL, {BestKey, _BestVal}} when Key < BestKey ->
            % There is a real key and a best key to compare, and the real key
            % at this level is before the best key, and so is now the new best
            % key
            % The QueryArray is not modified until we have checked all levels
            find_nextkey(QueryArray,
                            LCnt + 1,
                            {LCnt, {Key, Val}},
                            StartKey, EndKey, Width);
        {{Key, Val}, BKL, {BestKey, BestVal}} when Key == BestKey ->
            SQN = leveled_codec:strip_to_seqonly({Key, Val}),
            BestSQN = leveled_codec:strip_to_seqonly({BestKey, BestVal}),
            if
                SQN =< BestSQN ->
                    % This is a dominated key, so we need to skip over it
                    NewEntry = {LCnt, RestOfKeys},
                    find_nextkey(lists:keyreplace(LCnt, 1, QueryArray, NewEntry),
                                    LCnt + 1,
                                    {BKL, {BestKey, BestVal}},
                                    StartKey, EndKey, Width);
                SQN > BestSQN ->
                    % There is a real key at the front of this level and it has
                    % a higher SQN than the best key, so we should use this as
                    % the best key
                    % But we also need to remove the dominated key from the
                    % lower level in the query array
                    OldBestEntry = lists:keyfind(BKL, 1, QueryArray),
                    {BKL, [{BestKey, BestVal}|BestTail]} = OldBestEntry,
                    find_nextkey(lists:keyreplace(BKL,
                                                    1,
                                                    QueryArray,
                                                    {BKL, BestTail}),
                                    LCnt + 1,
                                    {LCnt, {Key, Val}},
                                    StartKey, EndKey, Width)
            end;
        {_, BKL, BKV} ->
            % This is not the best key
            find_nextkey(QueryArray,
                            LCnt + 1,
                            {BKL, BKV},
                            StartKey, EndKey, Width)
    end.


keyfolder(IMMiter, SSTiter, StartKey, EndKey, {AccFun, Acc}) ->
    keyfolder({IMMiter, SSTiter}, {StartKey, EndKey}, {AccFun, Acc}, -1).

keyfolder(_Iterators, _KeyRange, {_AccFun, Acc}, MaxKeys) when MaxKeys == 0 ->
    Acc;
keyfolder({[], SSTiter}, KeyRange, {AccFun, Acc}, MaxKeys) ->
    {StartKey, EndKey} = KeyRange,
    case find_nextkey(SSTiter, StartKey, EndKey) of
        no_more_keys ->
            Acc;
        {NxSSTiter, {SSTKey, SSTVal}} ->
            Acc1 = AccFun(SSTKey, SSTVal, Acc),
            keyfolder({[], NxSSTiter}, KeyRange, {AccFun, Acc1}, MaxKeys - 1)
    end;
keyfolder({[{IMMKey, IMMVal}|NxIMMiterator], SSTiterator}, KeyRange,
                                                    {AccFun, Acc}, MaxKeys) ->
    {StartKey, EndKey} = KeyRange,
    case {IMMKey < StartKey, leveled_codec:endkey_passed(EndKey, IMMKey)} of
        {true, _} ->
    
            % Normally everything is pre-filterd, but the IMM iterator can
            % be re-used and so may be behind the StartKey if the StartKey has
            % advanced from the previous use
            keyfolder({NxIMMiterator, SSTiterator},
                        KeyRange,
                        {AccFun, Acc},
                        MaxKeys);
        {false, true} ->
            % There are no more keys in-range in the in-memory
            % iterator, so take action as if this iterator is empty
            % (see above)
            keyfolder({[], SSTiterator},
                        KeyRange,
                        {AccFun, Acc},
                        MaxKeys);
        {false, false} ->
            case find_nextkey(SSTiterator, StartKey, EndKey) of
                no_more_keys ->
                    % No more keys in range in the persisted store, so use the
                    % in-memory KV as the next
                    Acc1 = AccFun(IMMKey, IMMVal, Acc),
                    keyfolder({NxIMMiterator, SSTiterator},
                                KeyRange,
                                {AccFun, Acc1},
                                MaxKeys - 1);
                {NxSSTiterator, {SSTKey, SSTVal}} ->
                    % There is a next key, so need to know which is the
                    % next key between the two (and handle two keys
                    % with different sequence numbers).  
                    case leveled_codec:key_dominates({IMMKey,
                                                            IMMVal},
                                                        {SSTKey,
                                                            SSTVal}) of
                        left_hand_first ->
                            Acc1 = AccFun(IMMKey, IMMVal, Acc),
                            keyfolder({NxIMMiterator, SSTiterator},
                                        KeyRange,
                                        {AccFun, Acc1},
                                        MaxKeys - 1);
                        right_hand_first ->
                            Acc1 = AccFun(SSTKey, SSTVal, Acc),
                            keyfolder({[{IMMKey, IMMVal}|NxIMMiterator],
                                            NxSSTiterator},
                                        KeyRange,
                                        {AccFun, Acc1},
                                        MaxKeys - 1);
                        left_hand_dominant ->
                            Acc1 = AccFun(IMMKey, IMMVal, Acc),
                            keyfolder({NxIMMiterator, NxSSTiterator},
                                        KeyRange,
                                        {AccFun, Acc1},
                                        MaxKeys - 1)
                    end
            end
    end.    


%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).


generate_randomkeys({Count, StartSQN}) ->
    generate_randomkeys(Count, StartSQN, []).

generate_randomkeys(0, _SQN, Acc) ->
    lists:reverse(Acc);
generate_randomkeys(Count, SQN, Acc) ->
    K = {o,
            lists:concat(["Bucket", leveled_rand:uniform(1024)]),
            lists:concat(["Key", leveled_rand:uniform(1024)]),
            null},
    RandKey = {K,
                {SQN,
                {active, infinity},
                leveled_codec:magic_hash(K),
                null}},
    generate_randomkeys(Count - 1, SQN + 1, [RandKey|Acc]).
    

clean_testdir(RootPath) ->
    clean_subdir(sst_rootpath(RootPath)),
    clean_subdir(filename:join(RootPath, ?MANIFEST_FP)).

clean_subdir(DirPath) ->
    case filelib:is_dir(DirPath) of
        true ->
            {ok, Files} = file:list_dir(DirPath),
            lists:foreach(fun(FN) ->
                                File = filename:join(DirPath, FN),
                                ok = file:delete(File),
                                io:format("Success deleting ~s~n", [File])
                                end,
                            Files);
        false ->
            ok
    end.


maybe_pause_push(PCL, KL) ->
    T0 = [],
    I0 = leveled_pmem:new_index(),
    T1 = lists:foldl(fun({K, V}, {AccSL, AccIdx, MinSQN, MaxSQN}) ->
                            UpdSL = [{K, V}|AccSL],
                            SQN = leveled_codec:strip_to_seqonly({K, V}),
                            H = leveled_codec:magic_hash(K),
                            UpdIdx = leveled_pmem:prepare_for_index(AccIdx, H),
                            {UpdSL, UpdIdx, min(SQN, MinSQN), max(SQN, MaxSQN)}
                            end,
                        {T0, I0, infinity, 0},
                        KL),
    SL = element(1, T1),
    Tree = leveled_tree:from_orderedlist(lists:ukeysort(1, SL), ?CACHE_TYPE),
    T2 = setelement(1, T1, Tree),
    case pcl_pushmem(PCL, T2) of
        returned ->
            timer:sleep(50),
            maybe_pause_push(PCL, KL);
        ok ->
            ok
    end.

%% old test data doesn't have the magic hash
add_missing_hash({K, {SQN, ST, MD}}) ->
    {K, {SQN, ST, leveled_codec:magic_hash(K), MD}}.


clean_dir_test() ->
    % Pointless gesture to test coverage
    RootPath = "../test/ledger",
    ?assertMatch(ok, file:write_file(RootPath ++ "/test.bob", "hello")),
    ok = clean_subdir(RootPath ++ "/test.bob"),
    ok = file:delete(RootPath ++ "/test.bob").

simple_server_test() ->
    RootPath = "../test/ledger",
    clean_testdir(RootPath),
    {ok, PCL} = pcl_start(#penciller_options{root_path=RootPath,
                                                max_inmemory_tablesize=1000}),
    Key1_Pre = {{o,"Bucket0001", "Key0001", null},
                    {1, {active, infinity}, null}},
    Key1 = add_missing_hash(Key1_Pre),
    KL1 = generate_randomkeys({1000, 2}),
    Key2_Pre = {{o,"Bucket0002", "Key0002", null},
                {1002, {active, infinity}, null}},
    Key2 = add_missing_hash(Key2_Pre),
    KL2 = generate_randomkeys({900, 1003}),
    % Keep below the max table size by having 900 not 1000
    Key3_Pre = {{o,"Bucket0003", "Key0003", null},
                {2003, {active, infinity}, null}},
    Key3 = add_missing_hash(Key3_Pre),
    KL3 = generate_randomkeys({1000, 2004}), 
    Key4_Pre = {{o,"Bucket0004", "Key0004", null},
                {3004, {active, infinity}, null}},
    Key4 = add_missing_hash(Key4_Pre),
    KL4 = generate_randomkeys({1000, 3005}),
    ok = maybe_pause_push(PCL, [Key1]),
    ?assertMatch(Key1, pcl_fetch(PCL, {o,"Bucket0001", "Key0001", null})),
    ok = maybe_pause_push(PCL, KL1),
    ?assertMatch(Key1, pcl_fetch(PCL, {o,"Bucket0001", "Key0001", null})),
    ok = maybe_pause_push(PCL, [Key2]),
    ?assertMatch(Key1, pcl_fetch(PCL, {o,"Bucket0001", "Key0001", null})),
    ?assertMatch(Key2, pcl_fetch(PCL, {o,"Bucket0002", "Key0002", null})),
    
    ok = maybe_pause_push(PCL, KL2),
    ?assertMatch(Key2, pcl_fetch(PCL, {o,"Bucket0002", "Key0002", null})),
    ok = maybe_pause_push(PCL, [Key3]),
    
    ?assertMatch(Key1, pcl_fetch(PCL, {o,"Bucket0001", "Key0001", null})),
    ?assertMatch(Key2, pcl_fetch(PCL, {o,"Bucket0002", "Key0002", null})),
    ?assertMatch(Key3, pcl_fetch(PCL, {o,"Bucket0003", "Key0003", null})),
    timer:sleep(200),
    % This sleep should make sure that the merge to L1 has occurred
    % This will free up the L0 slot for the remainder to be written in shutdown
    ok = pcl_close(PCL),
    
    {ok, PCLr} = pcl_start(#penciller_options{root_path=RootPath,
                                                max_inmemory_tablesize=1000}),
    ?assertMatch(2003, pcl_getstartupsequencenumber(PCLr)),
    % ok = maybe_pause_push(PCLr, [Key2] ++ KL2 ++ [Key3]),
    
    ?assertMatch(Key1, pcl_fetch(PCLr, {o,"Bucket0001", "Key0001", null})),
    ?assertMatch(Key2, pcl_fetch(PCLr, {o,"Bucket0002", "Key0002", null})),
    ?assertMatch(Key3, pcl_fetch(PCLr, {o,"Bucket0003", "Key0003", null})),
    ok = maybe_pause_push(PCLr, KL3),
    ok = maybe_pause_push(PCLr, [Key4]),
    ok = maybe_pause_push(PCLr, KL4),
    ?assertMatch(Key1, pcl_fetch(PCLr, {o,"Bucket0001", "Key0001", null})),
    ?assertMatch(Key2, pcl_fetch(PCLr, {o,"Bucket0002", "Key0002", null})),
    ?assertMatch(Key3, pcl_fetch(PCLr, {o,"Bucket0003", "Key0003", null})),
    ?assertMatch(Key4, pcl_fetch(PCLr, {o,"Bucket0004", "Key0004", null})),
    
    {ok, PclSnap, null} = 
        leveled_bookie:snapshot_store(leveled_bookie:empty_ledgercache(),
                                        PCLr,
                                        null,
                                        ledger,
                                        undefined),           
    
    ?assertMatch(Key1, pcl_fetch(PclSnap, {o,"Bucket0001", "Key0001", null})),
    ?assertMatch(Key2, pcl_fetch(PclSnap, {o,"Bucket0002", "Key0002", null})),
    ?assertMatch(Key3, pcl_fetch(PclSnap, {o,"Bucket0003", "Key0003", null})),
    ?assertMatch(Key4, pcl_fetch(PclSnap, {o,"Bucket0004", "Key0004", null})),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap,
                                                {o,
                                                    "Bucket0001",
                                                    "Key0001",
                                                    null},
                                                1)),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap,
                                                {o,
                                                    "Bucket0002",
                                                    "Key0002",
                                                    null},
                                                1002)),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap,
                                                {o,
                                                    "Bucket0003",
                                                    "Key0003",
                                                    null},
                                                2003)),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap,
                                                {o,
                                                    "Bucket0004",
                                                    "Key0004",
                                                    null},
                                                3004)),
    % Add some more keys and confirm that check sequence number still
    % sees the old version in the previous snapshot, but will see the new version
    % in a new snapshot
    
    Key1A_Pre = {{o,"Bucket0001", "Key0001", null},
                    {4005, {active, infinity}, null}},
    Key1A = add_missing_hash(Key1A_Pre),
    KL1A = generate_randomkeys({2000, 4006}),
    ok = maybe_pause_push(PCLr, [Key1A]),
    ok = maybe_pause_push(PCLr, KL1A),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap,
                                                {o,
                                                    "Bucket0001",
                                                    "Key0001",
                                                    null},
                                                1)),
    ok = pcl_close(PclSnap),
     
    {ok, PclSnap2, null} = 
        leveled_bookie:snapshot_store(leveled_bookie:empty_ledgercache(),
                                        PCLr,
                                        null,
                                        ledger,
                                        undefined),
    
    ?assertMatch(false, pcl_checksequencenumber(PclSnap2,
                                                {o,
                                                    "Bucket0001",
                                                    "Key0001",
                                                    null},
                                                1)),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap2,
                                                {o,
                                                    "Bucket0001",
                                                    "Key0001",
                                                    null},
                                                4005)),
    ?assertMatch(true, pcl_checksequencenumber(PclSnap2,
                                                {o,
                                                    "Bucket0002",
                                                    "Key0002",
                                                    null},
                                                1002)),
    ok = pcl_close(PclSnap2),
    ok = pcl_close(PCLr),
    clean_testdir(RootPath).


simple_findnextkey_test() ->
    QueryArray = [
    {2, [{{o, "Bucket1", "Key1"}, {5, {active, infinity}, null}},
            {{o, "Bucket1", "Key5"}, {4, {active, infinity}, null}}]},
    {3, [{{o, "Bucket1", "Key3"}, {3, {active, infinity}, null}}]},
    {5, [{{o, "Bucket1", "Key2"}, {2, {active, infinity}, null}}]}
    ],
    {Array2, KV1} = find_nextkey(QueryArray,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key1"}, {5, {active, infinity}, null}}, KV1),
    {Array3, KV2} = find_nextkey(Array2,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key2"}, {2, {active, infinity}, null}}, KV2),
    {Array4, KV3} = find_nextkey(Array3,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key3"}, {3, {active, infinity}, null}}, KV3),
    {Array5, KV4} = find_nextkey(Array4,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key5"}, {4, {active, infinity}, null}}, KV4),
    ER = find_nextkey(Array5,
                        {o, "Bucket1", "Key0"},
                        {o, "Bucket1", "Key5"}),
    ?assertMatch(no_more_keys, ER).

sqnoverlap_findnextkey_test() ->
    QueryArray = [
    {2, [{{o, "Bucket1", "Key1"}, {5, {active, infinity}, 0, null}},
            {{o, "Bucket1", "Key5"}, {4, {active, infinity}, 0, null}}]},
    {3, [{{o, "Bucket1", "Key3"}, {3, {active, infinity}, 0, null}}]},
    {5, [{{o, "Bucket1", "Key5"}, {2, {active, infinity}, 0, null}}]}
    ],
    {Array2, KV1} = find_nextkey(QueryArray,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key1"}, {5, {active, infinity}, 0, null}},
                    KV1),
    {Array3, KV2} = find_nextkey(Array2,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key3"}, {3, {active, infinity}, 0, null}},
                    KV2),
    {Array4, KV3} = find_nextkey(Array3,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key5"}, {4, {active, infinity}, 0, null}},
                    KV3),
    ER = find_nextkey(Array4,
                        {o, "Bucket1", "Key0"},
                        {o, "Bucket1", "Key5"}),
    ?assertMatch(no_more_keys, ER).

sqnoverlap_otherway_findnextkey_test() ->
    QueryArray = [
    {2, [{{o, "Bucket1", "Key1"}, {5, {active, infinity}, 0, null}},
            {{o, "Bucket1", "Key5"}, {1, {active, infinity}, 0, null}}]},
    {3, [{{o, "Bucket1", "Key3"}, {3, {active, infinity}, 0, null}}]},
    {5, [{{o, "Bucket1", "Key5"}, {2, {active, infinity}, 0, null}}]}
    ],
    {Array2, KV1} = find_nextkey(QueryArray,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key1"}, {5, {active, infinity}, 0, null}},
                    KV1),
    {Array3, KV2} = find_nextkey(Array2,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key3"}, {3, {active, infinity}, 0, null}},
                    KV2),
    {Array4, KV3} = find_nextkey(Array3,
                                    {o, "Bucket1", "Key0"},
                                    {o, "Bucket1", "Key5"}),
    ?assertMatch({{o, "Bucket1", "Key5"}, {2, {active, infinity}, 0, null}},
                    KV3),
    ER = find_nextkey(Array4,
                        {o, "Bucket1", "Key0"},
                        {o, "Bucket1", "Key5"}),
    ?assertMatch(no_more_keys, ER).

foldwithimm_simple_test() ->
    QueryArray = [
        {2, [{{o, "Bucket1", "Key1", null},
                    {5, {active, infinity}, 0, null}},
                {{o, "Bucket1", "Key5", null},
                    {1, {active, infinity}, 0, null}}]},
        {3, [{{o, "Bucket1", "Key3", null},
                {3, {active, infinity}, 0, null}}]},
        {5, [{{o, "Bucket1", "Key5", null},
                {2, {active, infinity}, 0, null}}]}
    ],
    KL1A = [{{o, "Bucket1", "Key6", null}, {7, {active, infinity}, 0, null}},
            {{o, "Bucket1", "Key1", null}, {8, {active, infinity}, 0, null}},
            {{o, "Bucket1", "Key8", null}, {9, {active, infinity}, 0, null}}],
    IMM2 = leveled_tree:from_orderedlist(lists:ukeysort(1, KL1A), ?CACHE_TYPE),
    IMMiter = leveled_tree:match_range({o, "Bucket1", "Key1", null},
                                        {o, null, null, null},
                                        IMM2),
    AccFun = fun(K, V, Acc) -> SQN = leveled_codec:strip_to_seqonly({K, V}),
                                Acc ++ [{K, SQN}] end,
    Acc = keyfolder(IMMiter,
                    QueryArray,
                    {o, "Bucket1", "Key1", null}, {o, "Bucket1", "Key6", null},
                    {AccFun, []}),
    ?assertMatch([{{o, "Bucket1", "Key1", null}, 8},
                    {{o, "Bucket1", "Key3", null}, 3},
                    {{o, "Bucket1", "Key5", null}, 2},
                    {{o, "Bucket1", "Key6", null}, 7}], Acc),
    
    IMMiterA = [{{o, "Bucket1", "Key1", null},
                    {8, {active, infinity}, 0, null}}],
    AccA = keyfolder(IMMiterA,
                        QueryArray,
                        {o, "Bucket1", "Key1", null}, {o, "Bucket1", "Key6", null},
                        {AccFun, []}),
    ?assertMatch([{{o, "Bucket1", "Key1", null}, 8},
                    {{o, "Bucket1", "Key3", null}, 3},
                    {{o, "Bucket1", "Key5", null}, 2}], AccA),
    
    KL1B = [{{o, "Bucket1", "Key4", null}, {10, {active, infinity}, 0, null}}|KL1A],
    IMM3 = leveled_tree:from_orderedlist(lists:ukeysort(1, KL1B), ?CACHE_TYPE),
    IMMiterB = leveled_tree:match_range({o, "Bucket1", "Key1", null},
                                        {o, null, null, null},
                                        IMM3),
    AccB = keyfolder(IMMiterB,
                    QueryArray,
                    {o, "Bucket1", "Key1", null}, {o, "Bucket1", "Key6", null},
                    {AccFun, []}),
    ?assertMatch([{{o, "Bucket1", "Key1", null}, 8},
                    {{o, "Bucket1", "Key3", null}, 3},
                    {{o, "Bucket1", "Key4", null}, 10},
                    {{o, "Bucket1", "Key5", null}, 2},
                    {{o, "Bucket1", "Key6", null}, 7}], AccB).

create_file_test() ->
    {RP, Filename} = {"../test/", "new_file.sst"},
    ok = file:write_file(filename:join(RP, Filename), term_to_binary("hello")),
    KVL = lists:usort(generate_randomkeys({10000, 0})),
    Tree = leveled_tree:from_orderedlist(KVL, ?CACHE_TYPE),
    FetchFun = fun(Slot) -> lists:nth(Slot, [Tree]) end,
    {ok,
        SP,
        noreply} = leveled_sst:sst_newlevelzero(RP,
                                                Filename,
                                                1,
                                                FetchFun,
                                                undefined,
                                                10000),
    lists:foreach(fun(X) ->
                        case checkready(SP) of
                            timeout ->
                                timer:sleep(X);
                            _ ->
                                ok
                        end end,
                    [50, 50, 50, 50, 50]),
    {ok, SrcFN, StartKey, EndKey} = checkready(SP),
    io:format("StartKey ~w EndKey ~w~n", [StartKey, EndKey]),
    ?assertMatch({o, _, _, _}, StartKey),
    ?assertMatch({o, _, _, _}, EndKey),
    ?assertMatch("./new_file.sst", SrcFN),
    ok = leveled_sst:sst_clear(SP),
    {ok, Bin} = file:read_file("../test/new_file.sst.discarded"),
    ?assertMatch("hello", binary_to_term(Bin)).

slow_fetch_test() ->
    ?assertMatch(not_present, log_slowfetch(2, not_present, "fake", 0, 1)).

checkready(Pid) ->
    try
        leveled_sst:sst_checkready(Pid)
    catch
        exit:{timeout, _} ->
            timeout
    end.

coverage_cheat_test() ->
    {noreply, _State0} = handle_info(timeout, #state{}),
    {ok, _State1} = code_change(null, #state{}, null).

-endif.
