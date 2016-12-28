%% -------- SST (Variant) ---------
%%
%% A FSM module intended to wrap a persisted, ordered view of Keys and Values
%%
%% The persisted view is built from a list (which may be created by merging
%% multiple lists).  The list is built first, then the view is created in bulk.
%%
%% -------- Slots ---------
%%
%% The view is built from sublists referred to as slot.  Each slot is up to 128
%% keys and values in size.  The slots are each themselves a gb_tree.  The
%% gb_tree is slightly slower than the skiplist at fetch time, and doesn't
%% support directly the useful to_range function.  However the from_orddict
%% capability is much faster than from_sortedlist in skiplist, saving on CPU
%% at sst build time:
%%
%% Skiplist:
%% build and serialise slot 3233 microseconds
%% de-serialise and check * 128 - 14669 microseconds
%% flatten back to list - 164 microseconds
%%
%% GBTree:
%% build and serialise tree 1433 microseconds
%% de-serialise and check * 128 - 15263 microseconds
%% flatten back to list - 175 microseconds
%%
%% The performance advantage at lookup time is no negligible as the time to
%% de-deserialise for each check is dominant.  This time grows linearly with
%% the size of the slot, wherease the serialisation time is relatively constant
%% with growth.  So bigger slots would be quicker to build, but the penalty for
%% that speed is too high at lookup time.
%%
%% -------- Blooms ---------
%%
%% There are two different tiny blooms for each table.  One is split by the
%% first byte of the hash, and consists of two hashes (derived from the
%% remainder of the hash).  This is the top bloom, and the size vaires by
%% level.
%% Level 0 has 8 bits per key - 0.05 fpr
%% Level 1 has 6 bits per key - 0.08 fpr
%% Other Levels have 4 bits per key - 0.15 fpr
%%
%% If this level is passed, then each slot has its own bloom based on the
%% same hash, but now split into three hashes and having a fixed 8 bit per
%% key size at all levels.
%% Slot Bloom has 8 bits per key - 0.03 fpr
%%
%% All blooms are based on the DJ Bernstein magic hash which proved to give
%% the predicted fpr in tests (unlike phash2 which has significantly higher
%% fpr).  Due to the cost of producing the magic hash, it is read from the
%% value not reproduced each time. If the value is set to no_lookup no bloom
%% entry is added, and if all hashes are no_lookup in the slot then no bloom
%% is produced.


-module(leveled_sst).

-behaviour(gen_fsm).

-include("include/leveled.hrl").

-define(SLOT_SIZE, 128).
-define(COMPRESSION_LEVEL, 1).
-define(LEVEL_BLOOM_SLOTS, [{0, 64}, {1, 48}, {default, 32}]).
-define(DISCARD_EXT, ".discarded").

-include_lib("eunit/include/eunit.hrl").

-export([init/1,
        handle_sync_event/4,
        handle_event/3,
        handle_info/3,
        terminate/3,
        code_change/4,
        starting/3,
        reader/3]).

-export([sst_new/3,
            sst_open/1,
            sst_get/2,
            sst_get/3,
            sst_getkvrange/4,
            sst_getslots/2,
            sst_close/1]).

-export([generate_randomkeys/1]).



-record(slot_index_value, {slot_id :: integer(),
                            bloom :: dict:dict(),
                            start_position :: integer(),
                            length :: integer()}).

-record(summary,    {first_key :: tuple(),
                        last_key :: tuple(),
                        index :: list(), % leveled_skiplist
                        bloom :: tuple(), % leveled_tinybloom
                        size :: integer()}).

-record(state,      {summary,
                        handle :: file:fd(),
                        sst_timings :: tuple(),
                        slot_lengths :: list(),
                        filename,
                        cache}).


%%%============================================================================
%%% API
%%%============================================================================

sst_open(Filename) ->
    {ok, Pid} = gen_fsm:start(?MODULE, [], []),
    case gen_fsm:sync_send_event(Pid, {sst_open, Filename}, infinity) of
        {ok, {SK, EK}} ->
            {ok, Pid, {SK, EK}}
    end.

sst_new(Filename, Level, KVList) ->
    {ok, Pid} = gen_fsm:start(?MODULE, [], []),
    case gen_fsm:sync_send_event(Pid,
                                    {sst_new, Filename, Level, KVList},
                                    infinity) of
        {ok, {SK, EK}} ->
            {ok, Pid, {SK, EK}}
    end.

%sft_newlevelzero(Filename, Slots, FetchFun, Wait, Penciller) ->
%    {ok, Pid} = gen_fsm:start(?MODULE, [], []),
%    case Wait of
%        true ->
%            KL1 = leveled_pmem:to_list(Slots, FetchFun),
%            Reply = gen_fsm:sync_send_event(Pid,
%                                            {sft_new,
%                                                Filename,
%                                                0,
%                                                KL1},
%                                            infinity),
%            {ok, Pid, Reply};
%        false ->
%            gen_fsm:send_event(Pid,
%                                {sft_newlevelzero,
%                                    Filename,
%                                    Slots,
%                                    FetchFun,
%                                    Penciller}),
%            {ok, Pid, noreply}
%    end.

sst_get(Pid, LedgerKey) ->
    sst_get(Pid, LedgerKey, leveled_codec:magic_hash(LedgerKey)).

sst_get(Pid, LedgerKey, Hash) ->
    gen_fsm:sync_send_event(Pid, {get_kv, LedgerKey, Hash}, infinity).

sst_getkvrange(Pid, StartKey, EndKey, ScanWidth) ->
    gen_fsm:sync_send_event(Pid,
                            {get_kvrange, StartKey, EndKey, ScanWidth},
                            infinity).

sst_getslots(Pid, SlotList) ->
    gen_fsm:sync_send_event(Pid, {get_slots, SlotList}, infinity).
    
sst_close(Pid) ->
    gen_fsm:sync_send_event(Pid, close, 2000).

%% Used in unit tests to force the printing of timings
sst_printtimings(Pid) ->
    gen_fsm:sync_send_event(Pid, print_timings, 1000).


%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([]) ->
    {ok, starting, #state{}}.

starting({sst_open, Filename}, _From, State) ->
    UpdState = read_file(Filename, State),
    Summary = UpdState#state.summary,
    {reply,
        {ok, {Summary#summary.first_key, Summary#summary.last_key}},
        reader,
        UpdState};
starting({sst_new, Filename, Level, KVList}, _From, State) ->
    {FirstKey, L, SlotIndex, AllHashes, SlotsBin} = build_all_slots(KVList),
    SummaryBin = build_table_summary(SlotIndex, AllHashes, Level, FirstKey, L),
    ActualFilename = write_file(Filename, SummaryBin, SlotsBin),
    UpdState = read_file(ActualFilename,
                            State#state{filename=ActualFilename}),
    Summary = UpdState#state.summary,
    {reply,
        {ok, {Summary#summary.first_key, Summary#summary.last_key}},
        reader,
        UpdState}.

reader({get_kv, LedgerKey, Hash}, _From, State) ->
    SW = os:timestamp(),
    {Result, Stage, SlotID} = fetch(LedgerKey, Hash, State),
    UpdTimings = leveled_log:sst_timing(State#state.sst_timings, SW, Stage),
    case {Result, Stage} of
        {not_present, slot_crc_wonky} ->
            leveled_log:log("SST02", [State#state.filename, SlotID]),
            {reply, Result, reader, State#state{sst_timings = UpdTimings}};
        {not_present, _} ->
            {reply, Result, reader, State#state{sst_timings = UpdTimings}};
        {KV, slot_lookup_hit} ->
            UpdCache = array:set(SlotID, KV, State#state.cache),
            {reply, Result, reader, State#state{cache = UpdCache,
                                                sst_timings = UpdTimings}};
        _ ->
            {reply, Result, reader, State#state{sst_timings = UpdTimings}}
    end;
reader({get_kvrange, StartKey, EndKey, ScanWidth}, _From, State) ->
    {reply,
        fetch_range(StartKey, EndKey, ScanWidth, State),
        reader,
        State};
reader({get_slots, SlotList}, _From, State) ->
    Handle = State#state.handle,
    FetchFun =
        fun({pointer, S, SK, EK}, Acc) ->
            Acc ++ trim_slot({pointer, Handle, S}, SK, EK) end,
    {reply,
        lists:foldl(FetchFun, [], SlotList),
        reader,
        State};
reader(print_timings, _From, State) ->
    io:format(user, "Timings of ~w~n", [State#state.sst_timings]),
    {reply, ok, reader, State#state{sst_timings = undefined}};
reader(close, _From, State) ->
    ok = file:close(State#state.handle),
    {stop, normal, ok, State}.

handle_sync_event(_Msg, _From, StateName, State) ->
    {reply, undefined, StateName, State}.

handle_event(_Msg, StateName, State) ->
    {next_state, StateName, State}.

handle_info(_Msg, StateName, State) ->
    {next_state, StateName, State}.

terminate(Reason, _StateName, State) ->
    leveled_log:log("SST04", [Reason, State#state.filename]).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.


%%%============================================================================
%%% Internal Functions
%%%============================================================================

fetch(LedgerKey, Hash, State) ->
    Summary = State#state.summary,
    case leveled_tinybloom:check({hash, Hash}, Summary#summary.bloom) of
        false ->
            {not_present, summary_bloom, null};
        true ->
            Slot = lookup_slot(LedgerKey, Summary#summary.index),
            SlotBloom = Slot#slot_index_value.bloom,
            case is_check_slot_required({hash, Hash}, SlotBloom) of
                false ->
                    {not_present, slot_bloom, null};
                true ->
                    CacheEntry = array:get(Slot#slot_index_value.slot_id,
                                    State#state.cache),
                    case CacheEntry of
                        {LedgerKey, CachedValue} ->
                            {{LedgerKey, CachedValue}, cache_entry, null};
                        _ ->
                            SlotLook = lookup_in_slot(LedgerKey,
                                                        {pointer,
                                                            State#state.handle,
                                                            Slot}),
                            case SlotLook of
                                crc_wonky ->
                                    {not_present,
                                        slot_crc_wonky,
                                        Slot#slot_index_value.slot_id};    
                                none ->
                                    {not_present,
                                        slot_lookup_miss,
                                        null};
                                {value, V} ->
                                    {{LedgerKey, V},
                                        slot_lookup_hit,
                                        Slot#slot_index_value.slot_id}
                            end
                    end
            end
    end.

fetch_range(StartKey, EndKey, ScanWidth, State) ->
    Summary = State#state.summary,
    Handle = State#state.handle,
    {Slots, LTrim, RTrim} = lookup_slots(StartKey,
                                            EndKey,
                                            Summary#summary.index),
    Self = self(),
    SL = length(Slots),
    ExpandedSlots = 
        case SL of
            0 ->
                [];
            1 ->
                [Slot] = Slots,
                case {LTrim, RTrim} of
                    {true, true} ->
                        [{pointer, Self, Slot, StartKey, EndKey}];
                    {true, false} ->
                        [{pointer, Self, Slot, StartKey, all}];
                    {false, true} ->
                        [{pointer, Self, Slot, all, EndKey}];
                    {false, false} ->
                        [{pointer, Self, Slot, all, all}]
                end;
            N ->
                {LSlot, MidSlots, RSlot} = 
                    case N of
                        2 ->
                            [Slot1, Slot2] = Slots,
                            {Slot1, [], Slot2};
                        N ->
                            [Slot1|_Rest] = Slots,
                            SlotN = lists:last(Slots),
                            {Slot1, lists:sublist(Slots, 2, N - 2), SlotN}
                    end,
                MidSlotPointers = lists:map(fun(S) ->
                                                {pointer, Self, S, all, all}
                                                end,
                                            MidSlots),
                case {LTrim, RTrim} of
                    {true, true} ->
                        [{pointer, Self, LSlot, StartKey, all}] ++
                            MidSlotPointers ++
                            [{pointer, Self, RSlot, all, EndKey}];
                    {true, false} ->
                        [{pointer, Self, LSlot, StartKey, all}] ++
                            MidSlotPointers ++
                            [{pointer, Self, RSlot, all, all}];
                    {false, true} ->
                        [{pointer, Self, LSlot, all, all}] ++
                            MidSlotPointers ++
                            [{pointer, Self, RSlot, all, EndKey}];
                    {false, false} ->
                        [{pointer, Self, LSlot, all, all}] ++
                            MidSlotPointers ++
                            [{pointer, Self, RSlot, all, all}]
                end
        end,
    {SlotsToFetch, SlotsToPoint} = 
        case ScanWidth of
            SW when SW >= SL ->
                {ExpandedSlots, []};
            _ ->
                lists:split(ScanWidth, ExpandedSlots)
        end,
    FetchFun =
        fun({pointer, _Self, S, SK, EK}, Acc) ->
            Acc ++ trim_slot({pointer, Handle, S}, SK, EK) end,
    lists:foldl(FetchFun, [], SlotsToFetch) ++ SlotsToPoint.


write_file(Filename, SummaryBin, SlotsBin) ->
    SummaryLength = byte_size(SummaryBin),
    SlotsLength = byte_size(SlotsBin),
    {PendingName, FinalName} = generate_filenames(Filename),
    file:write_file(PendingName,
                    <<SlotsLength:32/integer,
                        SummaryLength:32/integer,    
                        SlotsBin/binary,
                        SummaryBin/binary>>,
                    [raw]),
    case filelib:is_file(FinalName) of
        true ->
            AltName = filename:join(filename:dirname(FinalName),
                                    filename:basename(FinalName))
                        ++ ?DISCARD_EXT,
            leveled_log:log("SST05", [FinalName, AltName]),
            ok = file:rename(FinalName, AltName);
        false ->
            ok
    end,
    file:rename(PendingName, FinalName),
    FinalName.

read_file(Filename, State) ->
    {Handle, SummaryBin} = open_reader(Filename),
    Summary = read_table_summary(SummaryBin),
    SlotLengthFetchFun =
        fun({_K, V}, Acc) ->
                [{V#slot_index_value.slot_id,
                    V#slot_index_value.length}|Acc]
        end,
    SlotLengths = lists:foldr(SlotLengthFetchFun, [], Summary#summary.index),
    SlotCount = length(SlotLengths),
    SkipL = leveled_skiplist:from_sortedlist(Summary#summary.index),
    UpdSummary = Summary#summary{index = SkipL},
    leveled_log:log("SST03", [Filename, Summary#summary.size, SlotCount]),
    State#state{summary = UpdSummary,
                slot_lengths = SlotLengths,
                handle = Handle,
                cache = array:new({size, SlotCount + 1})}.

open_reader(Filename) ->
    {ok, Handle} = file:open(Filename, [binary, raw, read]),
    {ok, Lengths} = file:pread(Handle, 0, 8),
    <<SlotsLength:32/integer, SummaryLength:32/integer>> = Lengths,
    {ok, SummaryBin} = file:pread(Handle, SlotsLength + 8, SummaryLength),
    {Handle, SummaryBin}.

build_table_summary(SlotIndex, AllHashes, Level, FirstKey, L) ->
    BloomSlots =
        case lists:keyfind(Level, 1, ?LEVEL_BLOOM_SLOTS) of
            {Level, N} ->
                N;
            false ->
                element(2, lists:keyfind(default, 1, ?LEVEL_BLOOM_SLOTS))
        end,
    Bloom = lists:foldr(fun leveled_tinybloom:enter/2,
                            leveled_tinybloom:empty(BloomSlots),
                            AllHashes),
    [{LastKey, _LastV}|_Rest] = SlotIndex,
    Summary = #summary{first_key = FirstKey,
                        last_key = LastKey,
                        size = L,
                        index = lists:reverse(SlotIndex),
                        bloom = Bloom},
    SummBin = term_to_binary(Summary, [{compressed, ?COMPRESSION_LEVEL}]),
    SummCRC = erlang:crc32(SummBin),
    <<SummCRC:32/integer, SummBin/binary>>.

read_table_summary(BinWithCheck) ->
    <<SummCRC:32/integer, SummBin/binary>> = BinWithCheck,
    CRCCheck = erlang:crc32(SummBin),
    if
        CRCCheck == SummCRC ->
            % If not might it might be possible to rebuild from all the slots
            binary_to_term(SummBin)
    end.

build_all_slots(KVList) ->
    L = length(KVList),
    % The length is not a constant time command and the list may be large,
    % but otherwise length must be called each iteration to avoid exception
    % on split or sublist
    [{FirstKey, _FirstV}|_Rest] = KVList,
    SlotCount = L div ?SLOT_SIZE,
    {SlotIndex, AllHashes, SlotsBin} = build_all_slots(KVList,
                                                        SlotCount,
                                                        8,
                                                        [],
                                                        1,
                                                        [],
                                                        <<>>),
    {FirstKey, L, SlotIndex, AllHashes, SlotsBin}.

build_all_slots([], _Count, _Start, AllHashes, _SlotID, SlotIndex, SlotsBin) ->
    {SlotIndex, AllHashes, SlotsBin};
build_all_slots(KVL, Count, Start, AllHashes, SlotID, SlotIndex, SlotsBin) ->
    {SlotList, KVRem} =
        case Count of
            0 ->
                {lists:sublist(KVL, ?SLOT_SIZE), []};
            _N ->
                lists:split(?SLOT_SIZE, KVL)
        end,
    {LastKey, _V} = lists:last(SlotList),
    ExtractHashFun =
        fun({K, V}, Acc) ->
            {_SQN, H} = leveled_codec:strip_to_seqnhashonly({K, V}),
            case H of
                no_lookup ->
                    Acc;
                H ->
                    [{hash, H}|Acc]
            end
            end,
    HashList = lists:foldr(ExtractHashFun, [], SlotList),
    {SlotBin, Bloom} = build_slot(SlotList, HashList),
    SlotCRC = erlang:crc32(SlotBin),
    Length = byte_size(SlotBin) + 4,
    SlotIndexV = #slot_index_value{slot_id = SlotID,
                                    bloom = Bloom,
                                    start_position = Start,
                                    length = Length},
    build_all_slots(KVRem,
                    Count - 1,
                    Start + Length,
                    HashList ++ AllHashes,
                    SlotID + 1,
                    [{LastKey, SlotIndexV}|SlotIndex],
                    <<SlotsBin/binary, SlotCRC:32/integer, SlotBin/binary>>).


build_slot(KVList, HashList) ->
    Tree = gb_trees:from_orddict(KVList),
    Bloom = lists:foldr(fun leveled_tinybloom:tiny_enter/2,
                        leveled_tinybloom:tiny_empty(),
                        HashList),
    SlotBin = term_to_binary(Tree, [{compressed, ?COMPRESSION_LEVEL}]),
    {SlotBin, Bloom}.

is_check_slot_required(_Hash, none) ->
    true;
is_check_slot_required(Hash, Bloom) ->
    leveled_tinybloom:tiny_check(Hash, Bloom).

%% Returns a section from the summary index and two booleans to indicate if
%% the first slot needs trimming, or the last slot
lookup_slots(StartKey, EndKey, SkipList) ->
    SlotsOnlyFun = fun({_K, V}) -> V end,
    {KSL, LTrim, RTrim} = lookup_slots_int(StartKey, EndKey, SkipList),
    {lists:map(SlotsOnlyFun, KSL), LTrim, RTrim}.

lookup_slots_int(all, all, SkipList) ->
    {leveled_skiplist:to_list(SkipList), false, false};
lookup_slots_int(StartKey, all, SkipList) ->
    L = leveled_skiplist:to_list(SkipList),
    LTrimFun = fun({K, _V}) -> K < StartKey end,
    {_LDrop, RKeep0} = lists:splitwith(LTrimFun, L),
    [{FirstKey, _V}|_Rest] = RKeep0,
    LTrim = FirstKey < StartKey,
    {RKeep0, LTrim, false};
lookup_slots_int(StartKey, EndKey, SkipList) ->
    L0 = leveled_skiplist:to_range(SkipList, StartKey, EndKey),
    {LastKey, _LastVal} = lists:last(L0),
    case LastKey of
        EndKey ->
            {L0, true, false};
        _ ->
            LTail = leveled_skiplist:key_above(SkipList, EndKey),
            {L0 ++ [LTail], true, true}
    end.
        

lookup_slot(Key, SkipList) ->
    {_Mark, Slot} = leveled_skiplist:key_above(SkipList, Key),
    Slot.

lookup_in_slot(Key, {pointer, Handle, Slot}) ->
    SlotBin = read_slot(Handle, Slot),
    case SlotBin of
        crc_wonky ->
            crc_wonky;
        _ ->
            lookup_in_slot(Key, SlotBin)
    end;
lookup_in_slot(Key, SlotBin) ->
    Tree = binary_to_term(SlotBin),
    gb_trees:lookup(Key, Tree).

read_slot(Handle, Slot) ->
    {ok, SlotBin} = file:pread(Handle,
                                Slot#slot_index_value.start_position,
                                Slot#slot_index_value.length),
    <<SlotCRC:32/integer, SlotNoCRC/binary>> = SlotBin,
    case erlang:crc32(SlotNoCRC) of
        SlotCRC ->
            SlotNoCRC;
        _ ->
            crc_wonky
    end.

trim_slot({pointer, Handle, Slot}, all, all) ->
    case read_slot(Handle, Slot) of
        crc_wonky ->
            [];
        SlotBin ->
            trim_slot(SlotBin, all, all)
    end;
trim_slot(SlotBinary, all, all) ->
    Tree = binary_to_term(SlotBinary),
    gb_trees:to_list(Tree);
trim_slot({pointer, Handle, Slot}, StartKey, EndKey) ->
    case read_slot(Handle, Slot) of
        crc_wonky ->
            [];
        SlotBin ->
            trim_slot(SlotBin, StartKey, EndKey)
    end;
trim_slot(SlotBinary, StartKey, EndKey) ->
    Tree = binary_to_term(SlotBinary),
    L = gb_trees:to_list(Tree),
    LTrimFun = fun({K, _V}) ->
                        K < StartKey end,
    RTrimFun = fun({K, _V}) -> 
                        not leveled_codec:endkey_passed(EndKey, K) end,
    LTrimL =
        case StartKey of
            all ->
                L;
            _ ->
                {_LDrop, RKeep} = lists:splitwith(LTrimFun, L),
                RKeep
        end,
    RTrimL =
        case EndKey of
            all ->
                LTrimL;
            _ ->
                {LKeep, _RDrop} = lists:splitwith(RTrimFun, L),
                LKeep
        end,
    RTrimL.


generate_filenames(RootFilename) ->
    Ext = filename:extension(RootFilename),
    Components = filename:split(RootFilename),
    case Ext of
        [] ->
            {filename:join(Components) ++ ".pnd",
                filename:join(Components) ++ ".sst"};
        Ext ->
            DN = filename:dirname(RootFilename),
            FP_NOEXT = filename:basename(RootFilename, Ext),
            {filename:join(DN, FP_NOEXT) ++ ".pnd",
                filename:join(DN, FP_NOEXT) ++ ".sst"}
    end.    


%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

generate_randomkeys({Count, StartSQN}) ->
    BucketNumber = random:uniform(1024),
    generate_randomkeys(Count, StartSQN, [], BucketNumber, BucketNumber);
generate_randomkeys(Count) ->
    BucketNumber = random:uniform(1024),
    generate_randomkeys(Count, 0, [], BucketNumber, BucketNumber).

generate_randomkeys(Seqn, Count, BucketRangeLow, BucketRangeHigh) ->
    generate_randomkeys(Seqn,
                        Count,
                        [],
                        BucketRangeLow,
                        BucketRangeHigh).

generate_randomkeys(_Seqn, 0, Acc, _BucketLow, _BucketHigh) ->
    Acc;
generate_randomkeys(Seqn, Count, Acc, BucketLow, BRange) ->
    BNumber =
        case BRange of
            0 ->
                string:right(integer_to_list(BucketLow), 4, $0);
            _ ->
                BRand = random:uniform(BRange),
                string:right(integer_to_list(BucketLow + BRand), 4, $0)
        end,
    KNumber = string:right(integer_to_list(random:uniform(1000)), 6, $0),
    LedgerKey = leveled_codec:to_ledgerkey("Bucket" ++ BNumber,
                                            "Key" ++ KNumber,
                                            o),
    {_B, _K, KV} = leveled_codec:generate_ledgerkv(LedgerKey,
                                                    Seqn,
                                                    crypto:rand_bytes(64),
                                                    64,
                                                    infinity),
    generate_randomkeys(Seqn + 1,
                        Count - 1,
                        [KV|Acc],
                        BucketLow,
                        BRange).


simple_slotbin_test() ->
    KVList0 = generate_randomkeys(1, ?SLOT_SIZE * 2, 1, 4),
    KVList1 = lists:sublist(lists:ukeysort(1, KVList0), 1, ?SLOT_SIZE),
    ExtractHashFun =
        fun({K, V}) ->
            {_SQN, H} = leveled_codec:strip_to_seqnhashonly({K, V}),
            {hash, H} end,
    HashList = lists:map(ExtractHashFun, KVList1),
    SW0 = os:timestamp(),
    {SlotBin0, Bloom0} = build_slot(KVList1, HashList),
    io:format(user, "Slot built in ~w microseconds with size ~w~n",
                [timer:now_diff(os:timestamp(), SW0), byte_size(SlotBin0)]),
    
    SW1 = os:timestamp(),
    lists:foreach(fun(H) -> ?assertMatch(true,
                                            is_check_slot_required(H, Bloom0))
                                            end,
                    HashList),
    lists:foreach(fun({K, V}) ->
                            ?assertMatch({value, V},
                                            lookup_in_slot(K, SlotBin0))
                                            end,
                    KVList1),
    io:format(user, "Slot checked for all keys in ~w microseconds~n",
                [timer:now_diff(os:timestamp(), SW1)]),
    SW2 = os:timestamp(),
    ?assertMatch(KVList1, trim_slot(SlotBin0, all, all)),
    io:format(user, "Slot flattened in ~w microseconds~n",
                [timer:now_diff(os:timestamp(), SW2)]).
    

simple_slotbinsummary_test() ->
    KVList0 = generate_randomkeys(1, ?SLOT_SIZE * 8 + 100, 1, 4),
    KVList1 = lists:ukeysort(1, KVList0),
    [{FirstKey, _V}|_Rest] = KVList1,
    {FirstKey, _L, SlotIndex, AllHashes, SlotsBin} = build_all_slots(KVList1),
    SummaryBin = build_table_summary(SlotIndex,
                                        AllHashes,
                                        2,
                                        FirstKey,
                                        length(KVList1)),
    Summary = read_table_summary(SummaryBin),
    SummaryIndex = leveled_skiplist:from_sortedlist(Summary#summary.index),
    FetchFun =
        fun({Key, Value}) ->
            Slot = lookup_slot(Key, SummaryIndex),
            StartPos = Slot#slot_index_value.start_position,
            Length = Slot#slot_index_value.length,
            io:format("lookup slot id ~w from ~w length ~w~n",
                        [Slot#slot_index_value.slot_id, StartPos, Length]),
            <<_Pre:StartPos/binary,
                SlotBin:Length/binary,
                _Post/binary>> = <<0:64/integer, SlotsBin/binary>>,
            <<SlotCRC:32/integer, SlotBinNoCRC/binary>> = SlotBin,
            ?assertMatch(SlotCRC, erlang:crc32(SlotBinNoCRC)),
            {value, V} = lookup_in_slot(Key, SlotBinNoCRC),
            ?assertMatch(Value, V)
            end,
    SW = os:timestamp(),
    lists:foreach(FetchFun, KVList1),
    io:format(user,
                "Checking for ~w keys in slots took ~w microseconds~n",
                [length(KVList1), timer:now_diff(os:timestamp(), SW)]).

simple_persisted_test() ->
    Filename = "../test/simple_test",
    KVList0 = generate_randomkeys(1, ?SLOT_SIZE * 16, 1, 20),
    KVList1 = lists:ukeysort(1, KVList0),
    [{FirstKey, _FV}|_Rest] = KVList1,
    {LastKey, _LV} = lists:last(KVList1),
    {ok, Pid, {FirstKey, LastKey}} = sst_new(Filename, 1, KVList1),
    SW1 = os:timestamp(),
    lists:foreach(fun({K, V}) ->
                        ?assertMatch({K, V}, sst_get(Pid, K)),
                        ?assertMatch({K, V}, sst_get(Pid, K))
                        end,
                    KVList1),
    io:format(user,
                "Checking for ~w keys (twice) in file with cache hit took ~w "
                    ++ "microseconds~n",
                [length(KVList1), timer:now_diff(os:timestamp(), SW1)]),
    ok = sst_printtimings(Pid),
    KVList2 = generate_randomkeys(1, ?SLOT_SIZE * 16, 1, 20),
    MapFun =
        fun({K, V}, Acc) ->
            In = lists:keymember(K, 1, KVList1),
            case {K > FirstKey, LastKey > K, In} of
                {true, true, false} ->
                    [{K, leveled_codec:magic_hash(K), V}|Acc];
                _ ->
                    Acc
            end
        end,
    KVList3 = lists:foldl(MapFun, [], KVList2),
    SW2 = os:timestamp(),
    lists:foreach(fun({K, H, _V}) ->
                        ?assertMatch(not_present, sst_get(Pid, K, H))
                        end,
                    KVList3),
    io:format(user,
                "Checking for ~w missing keys took ~w microseconds~n",
                [length(KVList3), timer:now_diff(os:timestamp(), SW2)]),
    ok = sst_printtimings(Pid),
    FetchList1 = sst_getkvrange(Pid, all, all, 2),
    FoldFun = fun(X, Acc) ->
                    case X of
                        {pointer, P, S, SK, EK} ->
                            Acc ++ sst_getslots(P, [{pointer, S, SK, EK}]);
                        _ ->
                            Acc ++ [X]
                    end end,
    FetchedList1 = lists:foldl(FoldFun, [], FetchList1),
    ?assertMatch(KVList1, FetchedList1),
    
    {TenthKey, _v10} = lists:nth(10, KVList1),
    {Three000Key, _v300} = lists:nth(300, KVList1),
    io:format("Looking for 291 elements between ~s ~s and ~s ~s~n",
                [element(2, TenthKey),
                    element(3, TenthKey),
                    element(2, Three000Key),
                    element(3, Three000Key)]),
    SubKVList1 = lists:sublist(KVList1, 10, 291),
    SubKVList1L = length(SubKVList1),
    FetchList2 = sst_getkvrange(Pid, TenthKey, Three000Key, 2),
    FetchedList2 = lists:foldl(FoldFun, [], FetchList2),
    io:format("Found elements between ~s ~s and ~s ~s~n",
                [element(2, element(1, lists:nth(1, FetchedList2))),
                    element(3, element(1, lists:nth(1, FetchedList2))),
                    element(2, element(1, lists:last(FetchedList2))),
                    element(3, element(1, lists:last(FetchedList2)))]),
    ?assertMatch(SubKVList1L, length(FetchedList2)),
    ?assertMatch(SubKVList1, FetchedList2),
    
    ok = sst_close(Pid),
    ok = file:delete(Filename ++ ".sst").

-endif.