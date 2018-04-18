-module(hbbft_cc).

-export([init/4, get_coin/1, handle_msg/3]).

-record(cc_data, {
          state = waiting :: waiting | done,
          sk :: tpke_privkey:privkey(),
          sid :: erlang_pbc:element(),
          n :: pos_integer(),
          f :: non_neg_integer(),
          shares = sets:new()
         }).

-type cc_data() :: #cc_data{}.
-type share_msg() :: {share, tpke_privkey:share()}.

-export_type([cc_data/0, share_msg/0]).

-spec init(tpke_privkey:privkey(), binary() | erlang_pbc:element(), pos_integer(), non_neg_integer()) -> cc_data().
init(SecretKeyShard, Bin, N, F) when is_binary(Bin) ->
    Sid = tpke_pubkey:hash_message(tpke_privkey:public_key(SecretKeyShard), Bin),
    init(SecretKeyShard, Sid, N, F);
init(SecretKeyShard, Sid, N, F) ->
    #cc_data{sk=SecretKeyShard, n=N, f=F, sid=Sid}.

-spec get_coin(cc_data()) -> {cc_data(), ok | {send, [hbbft_utils:multicast(share_msg())]}}.
get_coin(Data = #cc_data{state=done}) ->
    {Data, ok};
get_coin(Data) ->
    Share = tpke_privkey:sign(Data#cc_data.sk, Data#cc_data.sid),
    {Data, {send, [{multicast, {share, Share}}]}}.

%% TODO: more specific return type than an integer?
-spec handle_msg(cc_data(), non_neg_integer(), share_msg()) -> {cc_data(), ok | {result, integer()}}.
handle_msg(Data, J, {share, Share}) ->
    share(Data, J, Share).

%% TODO: more specific return type than an integer?
-spec share(cc_data(), non_neg_integer(), tpke_privkey:share()) -> {cc_data(), ok | {result, integer()}}.
share(Data = #cc_data{state=done}, _J, _Share) ->
    {Data, ok};
share(Data, _J, Share) ->
    case sets:is_element(Share, Data#cc_data.shares) of
        false ->
            case tpke_pubkey:verify_signature_share(tpke_privkey:public_key(Data#cc_data.sk), Share, Data#cc_data.sid) of
                true ->
                    NewData = Data#cc_data{shares=sets:add_element(Share, Data#cc_data.shares)},
                    %% check if we have at least f+1 shares
                    case sets:size(NewData#cc_data.shares) > Data#cc_data.f of
                        true ->
                            %% combine shares
                            Sig = tpke_pubkey:combine_signature_shares(tpke_privkey:public_key(NewData#cc_data.sk), sets:to_list(NewData#cc_data.shares)),
                            %% check if the signature is valid
                            case tpke_pubkey:verify_signature(tpke_privkey:public_key(NewData#cc_data.sk), Sig, NewData#cc_data.sid) of
                                true ->
                                    %% TODO do something better here!
                                    <<Val:32/integer, _/binary>> = erlang_pbc:element_to_binary(Sig),
                                    {NewData#cc_data{state=done}, {result, Val}};
                                false ->
                                    {NewData, ok}
                            end;
                        false ->
                            {NewData, ok}
                    end;
                false ->
                    %% XXX bad share can be proof of malfeasance
                    {Data, ok}
            end;
        true ->
            {Data, ok}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

kill(Data) ->
    Data#cc_data{state=done}.

init_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),
    States = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, length(States) - 1), States),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    %% everyone should converge
    ?assertEqual(N, sets:size(ConvergedResults)),
    ok.

one_dead_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),
    [S0, S1, S2, S3, S4] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, kill(S2), S3, S4]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    %% everyone but one should converge
    ?assertEqual(N - 1, sets:size(ConvergedResults)),
    %% everyone should have the same value
    DistinctResults = lists:usort([ Sig || {result, {_J, Sig}} <- sets:to_list(ConvergedResults) ]),
    ?assertEqual(1, length(DistinctResults)),
    ok.

two_dead_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),
    [S0, S1, S2, S3, S4] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, kill(S2), S3, kill(S4)]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    %% everyone but two should converge
    ?assertEqual(N - 2, sets:size(ConvergedResults)),
    %% everyone should have the same value
    DistinctResults = lists:usort([ Sig || {result, {_J, Sig}} <- sets:to_list(ConvergedResults) ]),
    ?assertEqual(1, length(DistinctResults)),
    ok.

too_many_dead_test() ->
    N = 5,
    F = 4,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    gen_server:stop(dealer),
    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),
    [S0, S1, S2, S3, S4] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- PrivateKeys],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, kill(S2), S3, kill(S4)]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    %% nobody should converge
    ?assertEqual(0, sets:size(ConvergedResults)),
    ok.

key_mismatch_f1_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    {ok, _, PrivateKeys2} = dealer:deal(),
    gen_server:stop(dealer),
    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),
    [S0, S1, S2, S3, S4] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- lists:sublist(PrivateKeys, 3) ++ lists:sublist(PrivateKeys2, 2)],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, S2, S3, S4]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    io:format("Results ~p~n", [ConvergedResults]),
    %% all 5 should converge, but there should be 2 distinct results
    ?assertEqual(5, sets:size(ConvergedResults)),
    DistinctResults = lists:usort([ Sig || {result, {_J, Sig}} <- sets:to_list(ConvergedResults) ]),
    ?assertEqual(2, length(DistinctResults)),
    ok.


key_mismatch_f2_test() ->
    N = 5,
    F = 2,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    {ok, _, PrivateKeys2} = dealer:deal(),
    gen_server:stop(dealer),
    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),
    [S0, S1, S2, S3, S4] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- lists:sublist(PrivateKeys, 3) ++ lists:sublist(PrivateKeys2, 2)],
    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, S2, S3, S4]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),
    io:format("Results ~p~n", [ConvergedResults]),
    %% the 3 with the right keys should converge to the same value
    ?assertEqual(3, sets:size(ConvergedResults)),
    DistinctResults = lists:usort([ Sig || {result, {_J, Sig}} <- sets:to_list(ConvergedResults) ]),
    ?assertEqual(1, length(DistinctResults)),
    ok.

mixed_keys_test() ->
    N = 5,
    F = 1,
    dealer:start_link(N, F+1, 'SS512'),
    {ok, PubKey, PrivateKeys} = dealer:deal(),
    {ok, _, PrivateKeys2} = dealer:deal(),
    gen_server:stop(dealer),

    Sid = tpke_pubkey:hash_message(PubKey, crypto:strong_rand_bytes(32)),

    [S0, S1, S2, _, _] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- PrivateKeys],
    [_, _, _, S3, S4] = [hbbft_cc:init(Sk, Sid, N, F) || Sk <- PrivateKeys2],

    StatesWithId = lists:zip(lists:seq(0, N - 1), [S0, S1, S2, S3, S4]),
    %% all valid members should call get_coin
    Res = lists:map(fun({J, State}) ->
                            {NewState, Result} = get_coin(State),
                            {{J, NewState}, {J, Result}}
                    end, StatesWithId),
    {NewStates, Results} = lists:unzip(Res),
    {_, ConvergedResults} = hbbft_test_utils:do_send_outer(?MODULE, Results, NewStates, sets:new()),

    DistinctCoins = sets:from_list([Coin || {result, {_, Coin}} <- sets:to_list(ConvergedResults)]),
    io:format("DistinctCoins: ~p~n", [sets:to_list(DistinctCoins)]),
    %% two distinct sets have converged with different coins each
    ?assertEqual(2, sets:size(DistinctCoins)),

    %% io:format("ConvergedResults: ~p~n", [sets:to_list(ConvergedResults)]),
    %% everyone but two should converge
    ?assertEqual(N, sets:size(ConvergedResults)),
    ok.
-endif.