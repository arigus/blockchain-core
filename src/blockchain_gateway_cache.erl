-module(blockchain_gateway_cache).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         get/2, get/3,
         bulk_put/2,
         stats/0
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
                height = 1 :: pos_integer(),
                cache :: undefined | ets:tid()
               }).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec get(GwAddr :: libp2p_crypto:pubkey_bin(),
          Ledger :: blockchain_ledger_v1:ledger()) ->
                 ok | {error, _}.
get(Addr, Ledger) ->
    get(Addr, Ledger, true).

-spec get(GwAddr :: libp2p_crypto:pubkey_bin(),
          Ledger :: blockchain_ledger_v1:ledger(),
          CacheRead :: boolean()) ->
                 ok | {error, _}.
get(Addr, Ledger, false) ->
    ets:update_counter(?MODULE, total, 1, {total, 0}),
    blockchain_ledger_v1:find_gateway_info(Addr, Ledger);
get(Addr, Ledger, true) ->
    ets:update_counter(?MODULE, total, 1, {total, 0}),
    try
        {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
        case cache_get(Addr, Ledger) of
            {ok, _} = Result ->
                ets:update_counter(?MODULE, hit, 1, {hit, 0}),
                lager:debug("get ~p at ~p hit", [Addr, Height]),
                Result;
            _ ->
                case blockchain_ledger_v1:find_gateway_info(Addr, Ledger) of
                    {ok, Gw} = Result2 ->
                        lager:debug("get ~p at ~p miss writeback", [Addr, Height]),
                        cache_put(Addr, Gw, Ledger),
                        Result2;
                    Else ->
                        lager:debug("get ~p at ~p miss err", [Addr, Height]),
                        Else
                end
        end
    catch _:_ ->
            ets:update_counter(?MODULE, error, 1, {error, 0}),
            blockchain_ledger_v1:find_gateway_info(Addr, Ledger)
    end.

stats() ->
    case ets:lookup(?MODULE, total) of
        [] -> 0;
        [{_, Tot}] ->
            HitRate =
                case ets:lookup(?MODULE, hit) of
                    [] -> no_hits;
                    [{_, Hits}] ->
                        Hits / Tot
                end,
            Err = case ets:lookup(?MODULE, error) of
                      [] -> 0;
                      [{_, E}] -> E
                  end,
            {Tot, HitRate, Err}
    end.

bulk_put(Height, List) ->
    gen_server:call(?MODULE, {bulk_put, Height, List}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    %% register for blocks here
    %% start the cache
    Cache = ets:new(?MODULE,
                    [named_table,
                     public,
                     {write_concurrency, true},
                     {read_concurrency, true}]),
    case application:get_env(blockchain, disable_gateway_cache, false) of
        false ->
            try blockchain_worker:blockchain() of
                undefined ->
                    erlang:send_after(500, self(), chain_init),
                    {ok, #state{cache = Cache}};
                Chain ->
                    ok = blockchain_event:add_handler(self()),
                    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
                    {ok, #state{height = Height, cache = Cache}}
            catch _:_ ->
                      erlang:send_after(500, self(), chain_init),
                      {ok, #state{cache = Cache}}
            end;
        _ ->
            {ok, #state{cache=Cache}}
    end.

handle_call({bulk_put, Height, List}, _From, State) ->
    lists:foreach(
      fun({Addr, SerGw}) ->
              Gw = blockchain_ledger_gateway_v1:deserialize(SerGw),
              lager:debug("bulk ~p", [Addr]),
              ets:insert(?MODULE, {Addr, Height}),
              ets:insert(?MODULE, {{Addr, Height}, Gw})
      end, List),
    ets:insert(?MODULE, {curr_height, Height}),
    lager:debug("bulk_add at ~p ~p", [Height, length(List)]),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    lager:warning("unexpected call ~p from ~p", [_Request, _From]),
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    lager:warning("unexpected cast ~p", [_Msg]),
    {noreply, State}.

handle_info({blockchain_event, {add_block, _Hash, _Sync, Ledger}}, State) ->
    %% sweep here
    case blockchain_ledger_v1:current_height(Ledger) of
        {ok, Height} ->
            lager:debug("sweeping at ~p", [Height]),
            ets:select_delete(?MODULE, [{{{'_','$1'},'_'},[{'<','$1', Height - 51}],[true]}]),
            {noreply, State#state{height = Height}};
        {error, _Err} ->
            {noreply, State}
    end;
handle_info({blockchain_event, {new_chain, NC}}, State) ->
    ets:delete_all_objects(?MODULE),
    {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(NC)),
    {noreply, State#state{height = Height}};
handle_info(chain_init, State) ->
    try blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), chain_init),
            {noreply, State};
        Chain ->
            ok = blockchain_event:add_handler(self()),
            {ok, Height} = blockchain_ledger_v1:current_height(blockchain:ledger(Chain)),
            {noreply, State#state{height = Height}}
    catch _:_ ->
              erlang:send_after(500, self(), chain_init),
              {noreply, State}
    end;
handle_info(_Info, State) ->
    lager:warning("unexpected message ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

cache_get(Addr, Ledger) ->
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    case ets:lookup(?MODULE, Addr) of
        [] -> {error, not_found};
        [{_, LastUpdate}] ->  % TODO check if storing a list of these
                              % is worth the effort
            case Height >= LastUpdate of
                true ->
                    case ets:lookup(?MODULE, {Addr, LastUpdate}) of
                        [] ->
                            {error, not_found};
                        [{_, Res}] ->
                            lager:debug("lastupdate ~p ~p ~p", [Addr, LastUpdate, Height]),
                            {ok, Res}
                    end;
                false ->
                    %% this is less likely to work but still worth a try?
                    case ets:lookup(?MODULE, {Addr, Height}) of
                        [] ->
                            {error, not_found};
                        [{_, Res}] ->
                            lager:debug("no lastupdate ~p ~p ~p", [Addr, LastUpdate, Height]),
                            {ok, Res}
                    end
            end
    end.

cache_put(Addr, Gw, Ledger) ->
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    case ets:lookup(?MODULE, curr_height) of
        [{_, CurrHeight}] ->
            case Height == CurrHeight of
                %% because of speculative absorbs, we cannot accept these, as
                %% they may be affected by transactions that will never land
                true ->
                    ok;
                false ->
                    case ets:lookup(?MODULE, Addr) of
                        [] ->
                            ets:insert(?MODULE, {Addr, Height});
                        [{_, LastUpdate}] ->
                            case Height > LastUpdate of
                                true ->
                                    ets:insert(?MODULE, {Addr, Height});
                                false ->
                                    ok
                            end
                    end,
                    ets:insert(?MODULE, {{Addr, Height}, Gw}),
                    ok
            end;
        [] ->
            %% not sure that it's safe to do anything here
            ok
    end.