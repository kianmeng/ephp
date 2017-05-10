-module(ephp_interpr).
-author('manuel@altenwald.com').
-compile([warnings_as_errors]).

-export([
    process/2,
    process/3,
    run/2,
    run/3
]).

-include("ephp.hrl").

-spec process(context(), Statements :: [main_statement()]) ->
      {ok, binary() | return() | false}.

process(Context, Statements) ->
    Cover = ephp_cover:get_config(),
    process(Context, Statements, Cover).


-spec process(context(), Statements :: [main_statement()], Cover :: boolean()) ->
      {ok, binary() | return() | false}.

process(_Context, [], _Cover) ->
    {ok, <<>>};

process(Context, Statements, false) ->
    Value = lists:foldl(fun
        (Statement, false) ->
            run(Context, Statement, false);
        (_Statement, Return) ->
            Return
    end, false, Statements),
    {ok, Value};

process(Context, Statements, true) ->
    ok = ephp_cover:start_link(),
    Value = lists:foldl(fun
        (Statement, false) ->
            run(Context, Statement, true);
        (_Statement, Return) ->
            Return
    end, false, Statements),
    {ok, Value}.


-type break() :: break | {break, pos_integer()}.

-type flow_status() :: break() | continue | return() | false.

-spec run(context(), main_statement()) -> flow_status().

run(Context, Statement) ->
    Cover = ephp_cover:get_config(),
    run(Context, Statement, Cover).


-spec run(context(), main_statement(), Cover :: boolean()) -> flow_status().

run(Context, #print_text{text=Text, line=Line}, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:set_output(Context, Text),
    false;

run(Context, #print{expression=Expr, line=Line}, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    Result = ephp_context:solve(Context, Expr),
    ephp_context:set_output(Context, ephp_data:to_bin(Context, Line, Result)),
    false;

run(Context, #eval{statements=Statements, line=Line}, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    lists:foldl(fun(Statement, State) ->
        run_depth(Context, Statement, State, Cover)
    end, false, Statements).

-spec run_depth(context(), statement(), flow_status(),
                Cover :: boolean()) -> flow_status().

run_depth(Context, #eval{}=Eval, false, Cover) ->
    run(Context, Eval, Cover);

run_depth(Context, #assign{line=Line}=Assign, Return, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:solve(Context, Assign),
    Return;

run_depth(Context, #if_block{conditions=Cond,line=Line}=IfBlock, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    #if_block{true_block = TrueBlock, false_block = FalseBlock} = IfBlock,
    case ephp_data:to_boolean(ephp_context:solve(Context, Cond)) of
        true when is_list(TrueBlock) ->
            run(Context, #eval{statements = TrueBlock}, Cover);
        true ->
            run(Context, #eval{statements = [TrueBlock]}, Cover);
        false when is_list(FalseBlock) ->
            run(Context, #eval{statements = FalseBlock}, Cover);
        false when FalseBlock =:= undefined ->
            false;
        false ->
            run(Context, #eval{statements = [FalseBlock]}, Cover)
    end;

run_depth(Context, #switch{condition=Cond, cases=Cases, line=Line},
          false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    case run_switch(Context, Cond, Cases, Cover) of
        {seek, false} ->
            {_, Return} = run_switch(Context, default, Cases, Cover),
            Return;
        {_, Return} ->
            Return
    end,
    case Return of
        false -> false;
        {return, R} -> {return, R};
        break -> false;
        {break, 0} -> false;
        {break, N} -> {break, N-1}
    end;

run_depth(Context, #for{init = Init,
                        conditions = Cond,
                        update = Update,
                        loop_block = LB,
                        line = Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    run(Context, #eval{statements = Init}, Cover),
    LoopBlock = if
        is_tuple(LB) -> [LB];
        is_list(LB) -> LB;
        LB =:= undefined -> [];
        is_atom(LB) -> [LB]
    end,
    run_loop(pre, Context, Cond, LoopBlock ++ Update, Cover);

run_depth(Context, #foreach{kiter = Key,
                            iter = Var,
                            elements = RawElements,
                            loop_block = LB,
                            line = Line} = FE, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    LoopBlock = if
        is_tuple(LB) -> [LB];
        is_list(LB) -> LB;
        LB =:= undefined -> [];
        is_atom(LB) -> [LB]
    end,
    case ephp_context:solve(Context, RawElements) of
        ProcElements when ?IS_ARRAY(ProcElements) ->
            Elements = ephp_array:to_list(ProcElements),
            run_foreach(Context, Key, Var, Elements, LoopBlock, Cover);
        _ ->
            Line = FE#foreach.line,
            File = ephp_context:get_active_file(Context),
            Data = {<<"foreach">>},
            Error = {error, eargsupplied, Line, File, ?E_WARNING, Data},
            ephp_error:handle_error(Context, Error),
            false
    end;

run_depth(Context, #while{type=Type,conditions=Cond,loop_block=LB,line=Line},
          false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    LoopBlock = if
        is_tuple(LB) -> [LB];
        is_list(LB) -> LB;
        LB =:= undefined -> [];
        is_atom(LB) -> [LB]
    end,
    run_loop(Type, Context, Cond, LoopBlock, Cover);

run_depth(Context, #print_text{text=Text, line=Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:set_output(Context, Text),
    false;

run_depth(Context, #print{expression=Expr, line=Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    Result = ephp_context:solve(Context, Expr),
    ResText = ephp_data:to_bin(Context, Line, Result),
    ephp_context:set_output(Context, ResText),
    false;

run_depth(Context, #call{line=Line}=Call, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_func:run(Context, Call);

run_depth(Context, {Op, _Var, Line}=MonoArith, false, Cover) when
        Op =:= pre_incr orelse
        Op =:= pre_decr orelse
        Op =:= post_incr orelse
        Op =:= post_decr ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:solve(Context, MonoArith),
    false;

run_depth(Context, #operation{line=Line}=Op, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:solve(Context, Op),
    false;

run_depth(Context, #class{line=Line}=Class, Return, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:register_class(Context, Class),
    Return;

run_depth(Context, #function{name=Name, args=Args, code=Code, line=Line},
          Return, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:register_func(Context, Name, Args, Code, undefined),
    Return;

run_depth(Context, {global, GlobalVar, Line}, Return, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:solve(Context, {global, GlobalVar, Line}),
    Return;

run_depth(_Context, break, false, _Cover) ->
    break;

run_depth(_Context, continue, false, _Cover) ->
    continue;

run_depth(Context, {return, Value, Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    {return, ephp_context:solve(Context, Value)};

run_depth(_Context, {return,Value}, false, _Cover) ->
    {return, Value};

run_depth(_Context, {break, N}, false, _Cover) ->
    {break, N-1};

run_depth(_Context, Boolean, false, _Cover) when is_boolean(Boolean) ->
    false;

run_depth(Context, #int{line=Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    false;

run_depth(Context, #float{line=Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    false;

run_depth(Context, #text{line=Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    false;

run_depth(Context, #text_to_process{line=Line}=TP, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    ephp_context:solve(Context, TP),
    false;

run_depth(Context, #variable{idx=[{object,#call{},_}]}=Var, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Var#variable.line),
    ephp_context:solve(Context, Var),
    false;

run_depth(Context, #constant{type=define,name=Name,value=Expr,line=Line},
          false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    Value = ephp_context:solve(Context, Expr),
    ephp_context:register_const(Context, Name, Value),
    false;

run_depth(Context, #constant{line=Line}, false, Cover) ->
    ok = ephp_cover:store(Cover, Context, Line),
    false;

run_depth(Context, {silent, Statement}, false, Cover) ->
    ephp_error:run_quiet(ephp_context:get_errors_id(Context), fun() ->
        run_depth(Context, Statement, false, Cover)
    end);

run_depth(_Context, die, false, _Cover) ->
    throw(die);

run_depth(_Context, Statement, false, _Cover) ->
    ephp_error:error({error, eunknownst, undefined, ?E_CORE_ERROR, Statement}),
    break;

run_depth(_Context, _Statement, Break, _Cover) ->
    Break.

exit_cond({return, Ret}) -> {return, Ret};
exit_cond({break, 0}) -> false;
exit_cond({break, N}) -> {break, N-1};
exit_cond(false) -> false.

-spec run_loop(
    PrePost :: (pre | post),
    Context :: context(),
    Cond :: condition(),
    Statements :: [statement()],
    Cover :: boolean()) ->
        break() | continue | return() | false.

run_loop(pre, Context, Cond, Statements, Cover) ->
    case ephp_data:to_bool(ephp_context:solve(Context, Cond)) of
        true ->
            case run(Context, #eval{statements=Statements}, Cover) of
                false ->
                    run_loop(pre, Context, Cond, Statements, Cover);
                Return ->
                    exit_cond(Return)
            end;
        false ->
            false
    end;

run_loop(post, Context, Cond, Statements, Cover) ->
    case run(Context, #eval{statements=Statements}, Cover) of
        false ->
            case ephp_data:to_bool(ephp_context:solve(Context, Cond)) of
                true ->
                    run_loop(post, Context, Cond, Statements, Cover);
                false ->
                    false
            end;
        Return ->
            exit_cond(Return)
    end.

-spec run_foreach(
    Context :: context(),
    Key :: variable(),
    Var :: variable(),
    Elements :: mixed(),
    Statements :: [statement()],
    Cover :: boolean()) -> break() | return() | false.

run_foreach(_Context, _Key, _Var, [], _Statements, _Cover) ->
    false;

run_foreach(Context, Key, Var, [{KeyVal,VarVal}|Elements], Statements, Cover) ->
    case Key of
        undefined -> ok;
        _ -> ephp_context:set(Context, Key, KeyVal)
    end,
    ephp_context:set(Context, Var, VarVal),
    Break = run(Context, #eval{statements=Statements}, Cover),
    if
        Break =/= break andalso not is_tuple(Break) ->
            run_foreach(Context, Key, Var, Elements, Statements, Cover);
        true ->
            case Break of
                {return,Ret} -> {return,Ret};
                {break,0} -> false;
                {break,N} -> {break,N-1};
                _ -> false
            end
    end.

-type switch_flow() :: seek | run | exit.

-spec run_switch(context(), condition() | default, [switch_case()],
                 Cover :: boolean()) ->
      {switch_flow(), break() | return() | false}.

run_switch(Context, default, Cases, Cover) ->
    lists:foldl(fun
        (_SwitchCase, {exit, Return}) ->
            {exit, Return};
        (#switch_case{label=default, code_block=Code, line=Line},
         {seek, false}) ->
            ok = ephp_cover:store(Cover, Context, Line),
            case run(Context, #eval{statements=Code}, Cover) of
                break -> {exit, false};
                {break, 0} -> {exit, false};
                {break, N} -> {exit, {break, N-1}};
                {return, R} -> {exit, {return, R}};
                false -> {run, false}
            end;
        (_Case, {seek, false}) ->
            {seek, false};
        (Case, {run, false}) ->
            Break = run(Context,
                        #eval{statements=Case#switch_case.code_block},
                        Cover),
            case Break of
                break -> {exit, false};
                {break, 0} -> {exit, false};
                {break, N} -> {exit, {break, N-1}};
                {return, R} -> {exit, {return, R}};
                false -> {run, false}
            end
    end, {seek, false}, Cases);


run_switch(Context, Cond, Cases, Cover) ->
    MatchValue = ephp_context:solve(Context, Cond),
    lists:foldl(fun
        (_SwitchCase, {exit, Return}) ->
            {exit, Return};
        (Case, {run, false}) ->
            Break = run(Context,
                        #eval{statements=Case#switch_case.code_block},
                        Cover),
            case Break of
                break -> {exit, false};
                {break, 0} -> {exit, false};
                {break, N} -> {exit, {break, N-1}};
                {return, R} -> {exit, {return, R}};
                false -> {run, false}
            end;
        (#switch_case{label=default, line=Line}, {seek, false}) ->
            ok = ephp_cover:store(Cover, Context, Line),
            {seek, false};
        (#switch_case{label=LabelValue, line=Line}=Case, {seek, false}) ->
            ok = ephp_cover:store(Cover, Context, Line),
            Op = #operation{
                type = <<"==">>,
                expression_left=MatchValue,
                expression_right=LabelValue},
            case ephp_context:solve(Context, Op) of
            true ->
                Break = run(Context,
                            #eval{statements=Case#switch_case.code_block},
                            Cover),
                case Break of
                    break -> {exit, false};
                    {break, 0} -> {exit, false};
                    {break, N} -> {exit, {break, N-1}};
                    {return, R} -> {exit, {return, R}};
                    false -> {run, false}
                end;
            false ->
                {seek, false}
            end
    end, {seek, false}, Cases).
