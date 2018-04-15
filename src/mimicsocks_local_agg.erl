%doc    aggregated communication
%author foldl@outlook.com
-module(mimicsocks_local_agg).

-include("mimicsocks.hrl").

-behaviour(gen_statem).

%% API
-export([start_link/1, stop/1, accept/2, socket_ready/2]).
-export([init/1, callback_mode/0, terminate/3, code_change/4]).

-import(mimicsocks_wormhole_local, [show_sock/1]).

% FSM States
-export([
         init/3,
         forward/3
        ]).

% utils
-export([parse_full/2, send_data/3]).

start_link(Args) ->
   gen_statem:start_link(?MODULE, Args, []).

accept(Pid, Socket) ->
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid ! {accept, Socket}.

socket_ready(Pid, LSock) when is_pid(Pid), is_port(LSock) ->
    gen_tcp:controlling_process(LSock, Pid),
    gen_statem:cast(Pid, {socket_ready, LSock}).

stop(Pid) -> gen_statem:stop(Pid).

callback_mode() ->
    state_functions.

-record(state,
        {
            channel,

            t_s2i,
            t_i2s,

            wormhole,

            buf = <<>>
        }
       ).

%% callback funcitons
init([reverse, RemoteIp, RemotePort, Key]) ->
    RemoteServerArgs = [RemoteIp, RemotePort, mimicsocks_local_agg, {agg, self()}],
    RemoteMain = #{
        start => {mimicsocks_tcp_listener, start_link, [RemoteServerArgs]},
        restart => permanent,
        shutdown => brutal_kill
    },
    supervisor:start_child(mimicsocks_sup, RemoteMain),
    init0(mimicsocks_wormhole_remote, init, [Key]);
init(Args) ->
    init0(mimicsocks_wormhole_local, forward, Args).

init0(Mod, InitState, Args) ->
    case Mod:start_link([self() | Args]) of
        {ok, Channel} ->
            {ok, InitState, #state{channel = Channel,
                      t_i2s = ets:new(tablei2s, []),
                      t_s2i = ets:new(tables2i, []),
                      wormhole = Mod
                      }};
        {error, Reason} -> {stop, Reason}
    end.

init(cast, {socket_ready, Socket}, #state{channel = Channel, wormhole = Mod} = State) when is_port(Socket) ->
    Mod:socket_ready(Channel, Socket),
    {next_state, forward, State};
init(info, Msg, StateData) -> handle_info(Msg, init, StateData).

forward(info, Info, State) -> handle_info(Info, forward, State).

handle_info({accept, Socket}, _StateName, #state{t_i2s = Ti2s, t_s2i = Ts2i,
                                                 channel = Channel, wormhole = Mod} = State) ->
    case {inet:setopts(Socket, [{active, true}]), inet:peername(Socket)} of
        {ok, {ok, {_Addr, Port}}} ->
            ets:insert(Ti2s, {Port, Socket}),
            ets:insert(Ts2i, {Socket, Port}),
            Mod:suspend_mimic(Channel, 5000),
            Mod:recv(Channel, <<?AGG_CMD_NEW_SOCKET, Port:16/big>>);
        Error -> 
            ?ERROR("can't get port ~p~n", [Error]),
            gen_tcp:close(Socket)
    end,
    {keep_state, State};
handle_info({tcp, Socket, Bin}, _StateName, #state{t_s2i = Ts2i, channel = Channel} = State) ->
    case ets:lookup(Ts2i, Socket) of
        [{Socket, Id}] -> 
            send_data(Channel, Id, Bin);
        _ -> ?ERROR("socket (~s) not is db", [show_sock(Socket)])
    end,
    {keep_state, State};
handle_info({tcp_closed, Socket}, _StateName, #state{t_s2i = Ts2i, t_i2s = Ti2s, channel = Channel} = State) ->
    case ets:lookup(Ts2i, Socket) of
        [{Socket, ID}] -> 
            Channel ! {recv, self(), <<?AGG_CMD_CLOSE_SOCKET, ID:16/big>>},
            ets:match_delete(Ts2i, {Socket, '_'}),
            ets:match_delete(Ti2s, {ID, '_'});
        _ -> ok
    end,
    {keep_state, State};
handle_info({recv, Channel, Bin}, _StateName, #state{channel = Channel, buf = Buf} = State) ->
    All = <<Buf/binary, Bin/binary>>,
    {ok, Frames, Rem} = parse_full(All, []),
    State10 = lists:foldl(fun handle_cmd/2, State, Frames),
    NewState = State10#state{buf = Rem},
    {keep_state, NewState};
handle_info({tcp_error, Socket, _Reason}, _StateName, #state{t_s2i = Ts2i, t_i2s = Ti2s, channel = Channel} = State) ->
    case ets:lookup(Ts2i, Socket) of
        [{Socket, ID}] -> 
            Channel ! {recv, self(), <<?AGG_CMD_CLOSE_SOCKET, ID:16/big>>},
            ets:match_delete(Ts2i, {Socket, '_'}),
            ets:match_delete(Ti2s, {ID, '_'});
        _ -> ok
    end,
    {keep_state, State};
handle_info(stop, _StateName, State) -> 
    {stop, normal, State};
handle_info(Info, _StateName, State) ->
    ?WARNING("unexpected msg: ~p", [Info]),
    {keep_state, State}.

terminate(_Reason, _StateName, #state{channel = Channel, t_i2s = T1, t_s2i = T2, wormhole = Mod} =
            _State) ->
    (catch Mod:stop(Channel)),
    (catch ets:delete(T1)),
    (catch ets:delete(T2)),
    normal.

code_change(_OldVsn, OldStateName, OldStateData, _Extra) ->
    {ok, OldStateName, OldStateData}.

%helpers
send_data(Send, Id, List) when is_list(List) ->
    lists:foreach(fun (X) -> send_data(Send, Id, X) end, List);
send_data(_Send, _Id, <<>>) -> ok;
send_data(Send, Id, Bin) when size(Bin) < 256 ->
    Len = size(Bin),
    Send ! {recv, self(), <<?AGG_CMD_SMALL_DATA, Id:16/big, Len, Bin/binary>>};
send_data(Send, Id, Bin) when size(Bin) < 65536 ->
    Len = size(Bin),
    Send ! {recv, self(), <<?AGG_CMD_DATA, Id:16/big, Len:16/big, Bin/binary>>};
send_data(Send, Id, Bin) ->
    <<This:65535/binary, Rem/binary>> = Bin,
    Send ! {recv, self(), <<?AGG_CMD_DATA, Id:16/big, 65535:16/big, This/binary>>},
    send_data(Send, Id, Rem).

parse_data(<<>>) -> incomplete;
parse_data(<<?AGG_CMD_NOP, Rem/binary>>) ->
    case Rem of
        <<_Reserved:16/big, Len, _Dummy:Len/binary, Rem10/binary>> ->
            {?AGG_CMD_NOP, Rem10};
        _ -> incomplete
    end;
parse_data(<<?AGG_CMD_NEW_SOCKET, Rem/binary>>) ->
    case Rem of
        <<Id:16/big, Rem10/binary>> ->
            {{?AGG_CMD_NEW_SOCKET, Id}, Rem10};
        _ -> incomplete
    end;
parse_data(<<?AGG_CMD_CLOSE_SOCKET, Rem/binary>>) ->
    case Rem of
        <<Id:16/big, Rem10/binary>> ->
            {{?AGG_CMD_CLOSE_SOCKET, Id}, Rem10};
        _ -> incomplete
    end;
parse_data(<<?AGG_CMD_DATA, Rem/binary>>) ->
    case Rem of
        <<Id:16/big, Len:16/big, Data:Len/binary, Rem10/binary>> ->
            {{?AGG_CMD_DATA, Id, Data}, Rem10};
        _ -> incomplete
    end;
parse_data(<<?AGG_CMD_SMALL_DATA, Rem/binary>>) ->
    case Rem of
        <<Id:16/big, Len, Data:Len/binary, Rem10/binary>> ->
            {{?AGG_CMD_DATA, Id, Data}, Rem10};
        _ -> incomplete
    end;
parse_data(<<Cmd, _/binary>>) ->
    {bad_command, Cmd}.

parse_full(Data, Acc) ->
    case parse_data(Data) of
        incomplete -> {ok, lists:reverse(Acc), Data};
        {bad_command, Value} -> {{bad_command, Value}, Acc, Data};
        {Frame, Rem} -> parse_full(Rem, [Frame | Acc])
    end.

handle_cmd(?AGG_CMD_NOP, State) -> State;
handle_cmd({?AGG_CMD_NEW_SOCKET, _Id}, State) ->
    ?ERROR("unexpected ?AGG_CMD_NEW_SOCKET", []),
    State;
handle_cmd({?AGG_CMD_CLOSE_SOCKET, Id}, #state{t_s2i = Ts2i, t_i2s = Ti2s} = State) ->
    case ets:lookup(Ti2s, Id) of
        [{ID, Socket}] -> 
            ets:match_delete(Ts2i, {Socket, '_'}),
            ets:match_delete(Ti2s, {ID, '_'});
        _ -> ok
    end,
    State;
handle_cmd({?AGG_CMD_DATA, Id, Data}, #state{t_i2s = Ti2s} = State) ->
    case ets:lookup(Ti2s, Id) of
        [{Id, Socket}] -> 
            gen_tcp:send(Socket, Data);
        _ -> ok
    end,
    State.
