-module(ephp_interpr).
-compile([export_all, warnings_as_errors]).

-include("ephp.hrl").

-spec process(Context :: context(), Statements :: [main_statement()]) -> 
    {ok, binary()}.

process(_Context, []) ->
    {ok, <<>>};

process(Context, Statements) ->
    {ok, lists:foldl(fun(Statement, Text) ->
        Result = run(Context, Statement),
        <<Text/binary, Result/binary>>
    end, <<>>, Statements)}.

-spec run(Context :: context(), Statements :: main_statement()) ->
    binary().

run(_Context, #print_text{text=Text}) ->
    Text;

run(Context, #print{expression=Expr}) ->
    Result = ephp_context:solve(Context, Expr),
    ephp_util:to_bin(Result);

run(Context, #eval{statements=Statements}) ->
    lists:foldl(fun
        (#assign{}=Assign, GenText) ->
            ephp_context:solve(Context, Assign),
            GenText;
        (#if_block{conditions=Cond}=IfBlock, GenText) ->
            case ephp_context:solve(Context, Cond) of
            true ->
                Result = run(Context, 
                    #eval{statements=IfBlock#if_block.true_block}),
                <<GenText/binary, Result/binary>>;
            false ->
                Result = run(Context, 
                    #eval{statements=IfBlock#if_block.false_block}),
                <<GenText/binary, Result/binary>>
            end; 
        (#for{init=Init,conditions=Cond,
                update=Update,loop_block=LB}, GenText) ->
            run(Context, #eval{statements=Init}),
            LoopBlock = if
                is_tuple(LB) -> [LB];
                is_list(LB) -> LB;
                LB =:= undefined -> []
            end,
            run_loop(pre, Context, Cond, LoopBlock ++ Update, GenText);
        (#foreach{kiter=Key,iter=Var,elements=Elements,loop_block=LB}, GenText) ->
            LoopBlock = if
                is_tuple(LB) -> [LB];
                is_list(LB) -> LB;
                LB =:= undefined -> []
            end,
            run_foreach(Context, Key,Var,Elements,LoopBlock,GenText);
        (#while{type=Type,conditions=Cond,loop_block=LB}, GenText) ->
            LoopBlock = if
                is_tuple(LB) -> [LB];
                is_list(LB) -> LB;
                LB =:= undefined -> []
            end, 
            run_loop(Type, Context, Cond, LoopBlock, GenText);
        (#print_text{text=Text}, GenText) ->
            <<GenText/binary, Text/binary>>;
        (#print{expression=Expr}, GenText) ->
            Result = ephp_context:solve(Context, Expr),
            Output = ephp_context:get_output(Context),
            ResText = ephp_util:to_bin(Result),
            <<GenText/binary, Output/binary, ResText/binary>>;
        (#call{}=Call, GenText) ->
            ephp_context:solve(Context, Call), 
            Output = ephp_context:get_output(Context),
            <<GenText/binary, Output/binary>>;
        ({Op, _Var}=MonoArith, GenText) when 
                Op =:= pre_incr orelse 
                Op =:= pre_decr orelse
                Op =:= post_incr orelse
                Op =:= post_decr ->
            ephp_context:solve(Context, MonoArith),
            GenText;
        (_Statement, _GenText) ->
            throw(eunknownst)
    end, <<>>, Statements).

-spec run_loop(
    PrePost :: (pre | post),
    Context :: context(),
    Cond :: condition(),
    Statements :: [statement()],
    GenText :: binary()) -> binary().

run_loop(PrePost, Context, Cond, Statements, GenText) ->
    case PrePost =:= post orelse ephp_context:solve(Context, Cond) of
    true -> 
        NewGenText = lists:foldl(fun(Statement, Text) ->
            ResText = run(Context, #eval{statements=[Statement]}),
            <<Text/binary, ResText/binary>> 
        end, GenText, Statements),
        case ephp_context:solve(Context, Cond) of
        true ->
            run_loop(PrePost, Context, Cond, Statements, NewGenText);
        false ->
            NewGenText
        end;
    false ->
        GenText
    end.

-spec run_foreach(
    Context :: context(),
    Key :: variable(),
    Var :: variable(),
    Elements :: variable(),
    Statements :: [statement()],
    GenText :: binary()) -> binary().

run_foreach(Context, Key, Var, Elements, Statements, GenText) ->
    ?DICT:fold(fun(KeyVal, VarVal, Text) ->
        case Key of 
            undefined -> ok;
            _ -> ephp_context:set(Context, Key, KeyVal)
        end,
        ephp_context:set(Context, Var, VarVal),
        lists:foldl(fun(Statement, AText) ->
            ResText = run(Context, #eval{statements=[Statement]}),
            <<AText/binary, ResText/binary>>
        end, Text, Statements)
    end, GenText, ephp_context:get(Context, Elements)).
