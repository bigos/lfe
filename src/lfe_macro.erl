%% Copyright (c) 2008 Robert Virding. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.

%%% File    : lfe_macro.erl
%%% Author  : Robert Virding
%%% Purpose : Lisp Flavoured Erlang macro expander.

%%% Expand macros and record definitions (into macros), also handles
%%% quasiquote/backquote in an R6RS compatible way.

-module(lfe_macro).

-export([expand_form/1,expand_form/2,expand_forms/1,expand_forms/2,
	 macro_pass/2,expand_pass/2,
	 default_exps/0,def_syntax/2,qq_expand/1]).

-export([mbe_syntax_rules_proc/5,mbe_match_pat/3,
	 mbe_get_bindings/3,mbe_expand_pattern/3]).

-export([expand_macro/2,expand_macro_1/2]).

%% -compile([export_all]).

-import(lfe_lib, [new_env/0,add_fbinding/4,is_fbound/3,mbinding/3,
		  add_mbinding/3,is_mbound/2,mbinding/2,
		 is_proper_list/1]).

-import(lists, [any/2,all/2,map/2,foldl/3,foldr/3,mapfoldl/3,
		reverse/1,reverse/2,member/2]).
-import(orddict, [find/2,store/3]).

-define(Q(E), [quote,E]).			%We do a lot of quoting!

-record(mac, {vc=0}).				%Variable counter

default_exps() -> new_env().

%% [{'++',{'syntax-rules',
%% 	[{[],[]},
%% 	 {[e],e},
%% 	 {[e|es],
%% 	  [call,[quote,erlang],[quite,'++'],e,['++'|es]]}]}},
%%  {':',{'syntax-rules',
%%        [{[m,f|as],[call,[quote,m],[quote,f]|as]}]}},
%%  {'?',{'syntax-rules',
%%        [{[],['receive',[omega,omega]]}]}},
%%  {'andalso',{'syntax-rules',
%% 	     [{[e],e},
%% 	      {[e|es],
%% 	       ['case',e,
%% 		[[quote,true],['andalso'|es]],
%% 		[[quote,false],[quote,false]]]},
%% 	      {[],'true'}]}},
%%  {'cond',{'syntax-rules',
%% 	 [{[[[quote,'else']|b]],['begin'|b]},
%% 	  {[[[[quote,match],p,e]|b]|c],['case',e,[p|b],['_',['cond'|c]]]},
%% 	  {[[[[quote,match],p,g,e]|b]|c],['case',e,[p,g|b],['_',['cond'|c]]]},
%% 	  {[[t|b]|c],['if',t,['begin'|b],['cond'|c]]},
%% 	  {[],[quote,false]}]}},
%%  {'flet*',{'syntax-rules',
%% 	  [{[[fb|fbs]|b],['flet',[fb],['flet*',fbs|b]]},
%% 	   {[[]|b],['begin'|b]}]}},
%%  {'let*',{'syntax-rules',
%% 	  [{[[vb|vbs]|b],['let',[vb],['let*',vbs|b]]},
%% 	   {[[]|b],['begin'|b]}]}},
%%  {'orelse',{'syntax-rules',
%% 	    [{[e],e},
%% 	     {[e|es],['case',e,
%% 		      [[quote,true],[quote,true]],
%% 		      [[quote,false],['orelse'|es]]]},
%% 	     {[],'false'}]}}
%% ].    

%% expand_form(Form) -> Form.
%% expand_form(Form, Defs) -> Form.
%%  The first one is for users who do not expect themselves to handle
%%  macros.

expand_form(F) ->
    expand_form(F, default_exps()).

expand_form(F, Env) ->
    {Ef,_} = expand(F, Env, #mac{}),
    Ef.

%% expand_forms(FileForms) -> FileForms.
%% expand_forms(FileForms, Env) -> {FileForms,Env}.
%%  Expand forms in "file format", {Form,LineNumber}. When we pass an
%%  environment in we get back an updated one. The macro handling is
%%  done in two passes, the macro_pass which collects macro
%%  definitions and the expand_pass which macro expands all remaining
%%  forms.

expand_forms(Fs0) ->
    {Fs1,_} = expand_forms(Fs0, default_exps()),
    Fs1.

expand_forms(Fs0, Env0) ->
    {Fs1,Env1,St1} = pass1(Fs0, Env0, #mac{}),
    {Fs2,Env2,_} = pass2(Fs1, Env1, St1),
    {Fs2,Env2}.

%% macro_pass(Forms, Env) -> {Forms,Env}.
%%  Collect, and remove, all macro definitions in a list of forms. All
%%  top level macro calls are also expanded and any new macro
%%  definitions are collected.

macro_pass(Fs0, Env0) ->
    {Fs1,Env1,_} = pass1(Fs0, Env0, #mac{}),
    {Fs1,Env1}.

%% expand_pass(Forms, Env) -> {Forms,Env}.
%%  Completely expand_all macros calls in Forms using the macro
%%  definitions in Env.

expand_pass(Fs0, Env0) ->
    {Fs1,Env1,_} = pass2(Fs0, Env0, #mac{}),
    {Fs1,Env1}.

pass1([{['define-syntax'|Def]=F,L}|Fs0], Env0, St0) ->
    case def_syntax(Def, Env0, St0) of
	{yes,Env1,St1} -> pass1(Fs0, Env1, St1);
	no ->
	    %% Ignore it and pass it on to generate error later.
	    {Fs1,Env1,St1} = pass1(Fs0, Env0, St0),
	    {[{F,L}|Fs1],Env1,St1}
    end;
pass1([{['begin'|Bfs0],L}|Fs0], Env0, St0) ->
    {Bfs1,Env1,St1} = pass1_begin(Bfs0, L, Env0, St0),
    {Fs1,Env2,St2} = pass1(Fs0, Env1, St1),
    {[{['begin'|Bfs1],L}|Fs1],Env2,St2};
pass1([{F,L}|Fs0], Env0, St0) ->
    case expand_macro(F, Env0) of
	{yes,Exp} -> pass1([{Exp,L}|Fs0], Env0, St0);
	no -> 
	    {Fs1,Env1,St1} = pass1(Fs0, Env0, St0),
	    {[{F,L}|Fs1],Env1,St1}
    end;
pass1([], Env, St) -> {[],Env,St}.

pass1_begin([['define-syntax'|Def]=F|Fs0], L, Env0, St0) ->
    case def_syntax(Def, Env0, St0) of
	{yes,Env1,St1} -> pass1_begin(Fs0, L, Env1, St1);
	no ->
	    %% Ignore it and pass it on to generate error later.
	    {Fs1,Env1,St1} = pass1_begin(Fs0, L, Env0, St0),
	    {[F|Fs1],Env1,St1}
    end;
pass1_begin([['begin'|Bfs0]|Fs0], L, Env0, St0) ->
    {Bfs1,Env1,St1} = pass1_begin(Bfs0, L, Env0, St0),
    {Fs1,Env2,St2} = pass1_begin(Fs0, L, Env1, St1),
    {[['begin'|Bfs1]|Fs1],Env2,St2};
pass1_begin([F|Fs0], L, Env0, St0) ->
    case expand_macro(F, Env0) of
	{yes,Exp} -> pass1_begin([Exp|Fs0], L, Env0, St0);
	no -> 
	    {Fs1,Env1,St1} = pass1_begin(Fs0, L, Env0, St0),
	    {[F|Fs1],Env1,St1}
    end;
pass1_begin([], _, Env, St) -> {[],Env,St}.

pass2([{['begin'|Bfs0],L}|Fs0], Env0, St0) ->
    {Bfs1,Env1,St1} = pass2_begin(Bfs0, L, Env0, St0),
    {Fs1,Env2,St2} = pass2(Fs0, Env1, St1),
    {[{['begin'|Bfs1],L}|Fs1],Env2,St2};
pass2([{F,L}|Fs0], Env0, St0) ->
    {Exp,St1} = expand(F, Env0, St0),
    {Fs1,Env1,St2} = pass2(Fs0, Env0, St1),
    {[{Exp,L}|Fs1],Env1,St2};
pass2([], Env, St) -> {[],Env,St}.

pass2_begin([['begin'|Bfs0]|Fs0], L, Env0, St0) ->
    {Bfs1,Env1,St1} = pass2_begin(Bfs0, L, Env0, St0),
    {Fs1,Env2,St2} = pass2_begin(Fs0, L, Env1, St1),
    {[['begin'|Bfs1]|Fs1],Env2,St2};
pass2_begin([F|Fs0], L, Env0, St0) ->
    {Exp,St1} = expand(F, Env0, St0),
    {Fs1,Env1,St2} = pass2_begin(Fs0, L, Env0, St1),
    {[Exp|Fs1],Env1,St2};
pass2_begin([], _, Env, St) -> {[],Env,St}.

def_syntax([Name,Def], Env) ->
    def_syntax(Name, Def, Env, #mac{}).

def_syntax([Name,Def], Env, St) ->
    def_syntax(Name, Def, Env, St).

def_syntax(Name, ['syntax-rules'|_]=Def, Env, St) ->
    {yes,add_mbinding(Name, Def, Env),St};
%% Different versions here.
%%     try
%% 	{Macro,St1} = expand_syntax_rules(Name, Rules, St0),
%% 	{yes,St#mac{defs=store(Name, {macro,Macro}, St#mac.defs)}}
%% 	Defs = map(fun ([Pat,Exp]) -> {Pat,Exp} end, Rules),
%% 	{yes,St#mac{defs=store(Name, {'syntax-rules',Defs}, St#mac.defs)}}
%%     catch
%% 	_ -> no
%%     end;
def_syntax(Name, [macro|_]=Def, Env, St) ->
    %%{Ecls,Env1,St1} = expand_clauses(Cls, Env0, St0),
    {yes,add_mbinding(Name, Def, Env),St};
%%     try
%% 	{Ecls,St1} = expand_clauses(Cls, St0),
%% 	{yes,St1#mac{defs=store(Name, {macro,Ecls}, St1#mac.defs)}}
%%     catch
%% 	_ -> no
%%     end;
def_syntax(_, _, _, _) -> no.

%% def_record([Name|Fields], Env, State) -> {Def,State}.
%% def_record(Name, Fields, Env, State) -> {Def,State}.
%%  Define a VERY simple record by generating macros for all accesses.
%%  (define-record point x y)
%%    => make-point, is-point, match-point,
%%       point-x, set-point-x, point-y, set-point-y.

def_record([Name|Fields], Env, St) -> def_record(Name, Fields, Env, St).

def_record(Name, Fields, Env, St0) ->
    %% Make names for record creator/tester/match.
    Make = list_to_atom(lists:concat(['make-', Name])),
    Test = list_to_atom(lists:concat(['is-', Name])),
    Match = list_to_atom(lists:concat(['match-', Name])),
    {Fdef,St1} = def_rec_fields(Fields, Name, 2, St0), %Name is element 1!
    Def = ['begin',
	   ['define-syntax',
	    Make,['syntax-rules',
		  [Fields,[tuple,[quote,Name]|Fields]]]],
	   ['define-syntax',
	    Test,['syntax-rules',
		  [[rec],['is_record',rec,[quote,Name],length(Fields)+1]]]],
	   ['define-syntax',
	    Match,['syntax-rules',
		  [Fields,[tuple,[quote,Name]|Fields]]]]
	   |
	   Fdef],
    {Def,Env,St1}.

def_rec_fields([F|Fs], Name, N, St0) ->
    {Fds,St1} = def_rec_fields(Fs, Name, N+1, St0),
    Get = list_to_atom(lists:concat([Name,'-',F])),
    Set = list_to_atom(lists:concat(['set-',Name,'-',F])),
    {[['define-syntax',
       Get,['syntax-rules',[[rec],[element,N,rec]]]],
      ['define-syntax',
       Set,['syntax-rules',[[rec,new],[setelement,N,rec,new]]]]|
      Fds],
     St1};
def_rec_fields([], _, _, St) -> {[],St}.

%% expand(Form, Env, State) -> {Form,State}.
%% Expand a form using expansions in Env and defaults. N.B. builtin
%% core forms cannot be overidden and are handled here first. The core
%% forms also are particular about how their bodies are to be
%% expanded.

%% Known Core forms which cannot be overidden.
expand([quasiquote,Qq], Env, St) ->
    %% This is actually correct!
    expand(qq_expand(Qq), Env, St);
expand([quote,_]=Q, _, St) -> {Q,St};
expand([cons,H0,T0], Env, St0) ->
    {H1,St1} = expand(H0, Env, St0),
    {T1,St2} = expand(T0, Env, St1),
    {[cons,H1,T1],St2};
expand([car,E0], Env, St0) ->			%Catch these to prevent
    {E1,St1} = expand(E0, Env, St0),		%redefining them
    {[car,E1],St1};
expand([cdr,E0], Env, St0) ->
    {E1,St1} = expand(E0, Env, St0),
    {[cdr,E1],St1};
expand([list|As0], Env, St0) ->
    {As1,St1} = expand_tail(As0, Env, St0),
    {[list|As1],St1};
expand([tuple|As0], Env, St0) ->
    {As1,St1} = expand_tail(As0, Env, St0),
    {[tuple|As1],St1};
expand([binary|As0], Env, St0) ->
    {As1,St1} = expand_tail(As0, Env, St0),
    {[binary|As1],St1};
expand(['lambda',Head|B0], Env, St0) ->
    {B1,St1} = expand_tail(B0, Env, St0),
    {['lambda',Head|B1],St1};
expand(['match-lambda'|B0], Env, St0) ->
    {B1,St1} = expand_ml_clauses(B0, Env, St0),
    {['match-lambda'|B1],St1};
expand(['let',Vbs0|B0], Env, St0) ->
    %% We don't really have to syntax check very strongly here so we
    %% can use normal clause expansion. Lint will catch errors.
    {Vbs1,St1} = expand_clauses(Vbs0, Env, St0),
    {B1,St2} = expand_tail(B0, Env, St1),
    {['let',Vbs1|B1],St2};
expand(['flet',Fbs|B], Env, St) ->
    expand_flet(Fbs, B, Env, St);
expand(['fletrec',Fbs|B], Env, St) ->
    expand_fletrec(Fbs, B, Env, St);
expand(['let-syntax',Mbs|B], Env, St) ->
    expand_let_syntax(Mbs, B, Env, St);
expand(['begin'|B0], Env, St0)->
    {B1,St1} = expand_tail(B0, Env, St0),
    {['begin'|B1],St1};
expand(['if'|B0], Env, St0) ->
    {B1,St1} = expand_tail(B0, Env, St0),
    {['if'|B1],St1};
expand(['case',E0|Cls0], Env, St0) ->
    {E1,St1} = expand(E0, Env, St0),
    {Cls1,St2} = expand_clauses(Cls0, Env, St1),
    {['case',E1|Cls1],St2};
expand(['receive'|Cls0], Env, St0) ->
    {Cls1,St1} = expand_clauses(Cls0, Env, St0),
    {['receive'|Cls1],St1};
expand(['catch'|B0], Env, St0) ->
    {B1,St1} = expand_tail(B0, Env, St0),
    {['catch'|B1],St1};
expand(['try',E|B], Env, St) ->
    expand_try(E, B, Env, St);
expand(['funcall'|As0], Env, St0) ->
    {As1,St1} = expand_tail(As0, Env, St0),
    {['funcall'|As1],St1};
expand(['call'|As0], Env, St0) ->
    {As1,St1} = expand_tail(As0, Env, St0),
    {['call'|As1],St1};
expand(['define',Head|B0], Env, St0) ->
    %% Needs to be handled specially to protect Head.
    %% Covers both (define (a b c) ...) and (define a ...).
    {B1,St1} = expand_tail(B0, Env, St0),
    {[define,Head|B1],St1};
%% Now the case where we can have macros.
expand([Fun|_]=Call, Env, St) when is_atom(Fun) ->
    case mbinding(Fun, Env) of
	{yes,['syntax-rules'|Defs]} ->
	    syntax_rules(Call, Defs, Env, St);	%Try to match expansion.
	{yes,[macro|Body]} ->
	    macro(Call, Body, Env, St);		%Try to match expansion.
	no ->
	    %% Not there then use defaults.
	    case default1(Call, Env, St) of
		{yes,Exp,St1} -> expand(Exp, Env, St1);
		no -> expand_tail(Call, Env, St)
	    end
    end;
expand([_|_]=Call, Env, St) -> expand_tail(Call, Env, St);
expand(Tup, _, St) when is_tuple(Tup) ->
    %% Should we expand this? We assume implicit quote here.
    {Tup,St};
%% Everything else is atomic.
expand(F, _, St) -> {F,St}.			%Atomic

%% expand_list(Exprs, Env, State) -> {Exps,State}.
%% Expand a proper list of exprs.

expand_list(Es, Env, St) ->
    mapfoldl(fun (E, S) -> expand(E, Env, S) end, St, Es).

%% expand_tail(Tail, Env, State) -> {Etail,State}.
%% expand_tail(ExpFun, Tail, Env, State) -> {Etail,State}.
%% Expand the tail of a list, need not be a proper list.

expand_tail(Tail, Env, St) ->
    expand_tail(fun expand/3, Tail, Env, St).

expand_tail(Fun, [E0|Es0], Env, St0) ->
    {E1,St1} = Fun(E0, Env, St0),
    {Es1,St2} = expand_tail(Fun, Es0, Env, St1),
    {[E1|Es1],St2};
expand_tail(_, [], _, St) -> {[],St};
expand_tail(Fun, E, Env, St) -> Fun(E, Env, St). %Same on improper tail.

%% expand_clauses(Clauses, Env, State) -> {ExpCls,State}.
%% expand_ml_clauses(Clauses, Env, State) -> {ExpCls,State}.
%%  Expand macros in clause patterns, guards and body. Must handle
%%  match-lambda clauses differently as pattern is an explicit list of
%%  patterns *NOT* a pattern which is a list. This will affect what is
%%  detected a macro call.

expand_clauses(Cls, Env, St) ->
    expand_tail(fun expand_clause/3, Cls, Env, St).

expand_clause([P0,['when',G0]|B0], Env, St0) ->
    {P1,St1} = expand(P0, Env, St0),
    {G1,St2} = expand(G0, Env, St1),
    {B1,St3} = expand_tail(B0, Env, St2),
    {[P1,['when',G1]|B1],St3};
expand_clause([P0|B0], Env, St0) ->
    {P1,St1} = expand(P0, Env, St0),
    {B1,St2} = expand_tail(B0, Env, St1),
    {[P1|B1],St2};
expand_clause(Other, Env, St) -> expand(Other, Env, St).

expand_ml_clauses(Cls, Env, St) ->
    expand_tail(fun expand_ml_clause/3, Cls, Env, St).

expand_ml_clause([Ps0,['when',G0]|B0], Env, St0) ->
    {Ps1,St1} = expand_tail(Ps0, Env, St0),
    {G1,St2} = expand(G0, Env, St1),
    {B1,St3} = expand_tail(B0, Env, St2),
    {[Ps1,['when',G1]|B1],St3};
expand_ml_clause([Ps0|B0], Env, St0) ->
    {Ps1,St1} = expand_tail(Ps0, Env, St0),
    {B1,St2} = expand_tail(B0, Env, St1),
    {[Ps1|B1],St2};
expand_ml_clause(Other, Env, St) -> expand(Other, Env, St).

%% expand_flet(FuncBindings, Body, Env, State) -> {Expansion,State}.
%% expand_fletrec(FuncBindings, Body, Env, State) -> {Expansion,State}.
%%  Expand a flet/fletrec. Here we are only interested in marking
%%  functions as bound in the env and not what they are bound to, we
%%  will not be calling them. We only want to shadow macros of the
%%  same name.

expand_flet(Fbs0, B0, Env, St0) ->
    {Fbs1,B1,St1} = do_expand_flet(Fbs0, B0, Env, St0),
    {['flet',Fbs1|B1],St1}.

expand_fletrec(Fbs0, B0, Env, St0) ->
    {Fbs1,B1,St1} = do_expand_flet(Fbs0, B0, Env, St0),
    {['fletrec',Fbs1|B1],St1}.

do_expand_flet(Fbs0, B0, Env0, St0) ->
    %% Only very limited syntax checking here (see above).
    Env1 = foldl(fun ([V,['lambda',Args|_]], Env) when is_atom(V) ->
			 case is_proper_list(Args) of
			     true -> add_fbinding(V, length(Args), dummy, Env);
			     false -> Env
			 end;
		     ([V,['match-lambda',[Pats|_]|_]], Env) when is_atom(V) ->
			 case is_proper_list(Pats) of
			     true -> add_fbinding(V, length(Pats), dummy, Env);
			     false -> Env
			 end;
		     (_, Env) -> Env
		 end, Env0, Fbs0),
    {Fbs1,St1} = expand_clauses(Fbs0, Env1, St0),
    {B1,St2} = expand_tail(B0, Env1, St1),
    {Fbs1,B1,St2}.

%% expand_let_syntax(MacroBindings, Body, Env, State) -> {Expansion,State}.
%%  Expand a let_syntax. We add the actual macro binding to the env as
%%  we may need them while expanding the body.

expand_let_syntax(Mbs, B0, Env0, St0) ->
    %% Add the macro defs from expansion and return body in a begin.
    Env1 = foldl(fun ([Name,['syntax-rules'|_]=Def], Env) when is_atom(Name) ->
			 add_mbinding(Name, Def, Env);
		     ([Name,['macro'|_]=Def], Env) when is_atom(Name) ->
			 add_mbinding(Name, Def, Env);
		     (_, Env) -> Env		%Ignore mistakes
		 end, Env0, Mbs),
    {B1,St1} = expand_tail(B0, Env1, St0),	%Expand the body
    {['begin'|B1],St1}.

expand_try(E0, B0, Env, St0) ->
    {E1,St1} = expand(E0, Env, St0),
    {B1,St2} = expand_tail(fun (['case'|Cls0], E, Sta) ->
				   {Cls1,Stb} = expand_clauses(Cls0, E, Sta),
				   {['case'|Cls1],Stb};
			       (['catch'|Cls0], E, Sta) ->
				   {Cls1,Stb} = expand_clauses(Cls0, E, Sta),
				   {['catch'|Cls1],Stb};
			       (['after'|A0], E, Sta) ->
				   {A1,Stb} = expand_tail(A0, E, Sta),
				   {['after'|A1],Stb};
			       (Other, _, St) -> {Other,St}
			   end, B0, Env, St1),
    {['try',E1|B1],St2}.

%% syntax_rules(Call, Rules, Env, State) -> {Exp,State}.
%% Expand if possible using patterns/expansions in Rules.
%% We present 3 different ways of doing it, 2 using MBE which can
%% almost handle ... ellipsis properly  and one na�ve way which just
%% does simple substitutions.

syntax_rules([Name|As], Rules, Env, St) ->
    %% Expand directly to resultant expression.
    expand(mbe_syntax_rules_proc(Name, [], Rules, As), Env, St).

%% syntax_rules([Name|_]=Call, Rules, Env, St0) ->
%%     %% Expand to macro then call macro expander to handle.
%%     {Macro,St1} = expand_syntax_rules(Name, Rules, St0),
%%     macro(Call, Macro, Env, St1).

%% syntax_rules([_|As]=Call, [{Pat,Exp}|Rules], Env, St) ->
%%     %% io:fwrite("s-r: ~p\n" ,[{Call,{Pat,Exp}}]),
%%     case match(Pat, As) of
%% 	{yes,Bs} ->
%% 	    expand(subst(Exp, Bs), Env, St);
%% 	no -> syntax_rules(Call, Rules, Env, St)
%%     end;
%% syntax_rules([F|As], [], Env, St0) ->
%%     {Eas,St1} = expand_tail(As, Env, St0),
%%     {[F|Eas],St1}.

%% expand_syntax_rules(Name, Rules, St) ->
%%     %% Unlikely local variables!
%%     Ssym = '|-syn-|',
%%     Ksym = '|-kw-|',
%%     %% No keywords, use quote in pattern instead.
%%     Kw = [],					%Kw = hd(Rules),
%%     Cls = Rules,				%Cls = tl(Rules),
%%     {[[Ssym,mbe_syntax_rules_proc(Name, Kw, Cls, Ssym, Ksym)]],St}.    

%% subst(Expr, Bindings) -> Expr.
%% Substitute Bindings into Expr at all levels. N.B. this goes
%% straight through quotes and everything.

%% subst([E|Es], Bs) ->
%%     [subst(E, Bs)|subst(Es, Bs)];
%% subst(Tup, Bs) when is_tuple(Tup) ->
%%     list_to_tuple(subst_list(tuple_to_list(Tup), Bs));
%% subst(Symb, Bs) when is_atom(Symb) ->
%%     case find(Symb, Bs) of
%% 	{ok,Val} -> Val;
%% 	error -> Symb
%%     end;
%% subst(Atomic, _) -> Atomic.

%% subst_list(Es, Bs) ->
%%     map(fun (E) -> subst(E, Bs) end, Es).

%% match(Pattern, Data) -> {yes,Bindings} | no.
%% Try to match Pattern against Data returning bindings. Bindings is
%% an orddict.

%% match(Pat, Dat) -> lfe_eval:match(Pat, Dat, lfe_lib:new_env()).

%% macro(Call, Body, Env, State) -> {Exp,State}.
%%  Evaluate the macro body by applying it to the call args. Use the
%%  macro clauses as clauses to a case to handle that the arguments
%%  are really ONE pattern to match against.

macro([_|As], Cls, Env, St) ->
    {C1,St1} = expand(['case',[quote,As]|Cls], Env, St),
    Ev = lfe_eval:eval(C1, As),
    expand(Ev, Env, St1).

%%     io:fwrite("macro: ~p\n" ,[{Call,Cls,St}]),
%%     %% {lfe_eval:eval(['case',[quote,As]|Cls], As), St}.
%%     %% expand(lfe_eval:eval(['case',[quote,As]|Cls], As), St).
%%     {C1,St1} = expand(['case',[quote,As]|Cls], Env, St),
%%     io:fwrite("  1 => ~p\n", [{C1}]),
%%     Ev = lfe_eval:eval(C1, As),
%%     io:fwrite("  2 => ~p\n", [{Ev}]),
%%     {Exp,St2} = expand(Ev, Env, St1),
%%     io:fwrite("  3 => ~p\n", [{Exp,Env,St2}]),
%%     {Exp,St2}.

%% default1(Form, Env, State) -> {yes,Form,State} | no.
%%  Handle the builtin default expansions but only at top-level.
%%  Expand must be called on result to fully expand macro. This is
%%  basically doing exactly the same as if they were user defined.

%% Builtin default macro expansions.
default1(['++'|Abody], _, St) ->
    case Abody of
	[E] -> {yes,E,St};
	[E|Es] -> {yes,[call,?Q(erlang),?Q('++'),E,['++'|Es]],St};
	[] -> {yes,[],St}
    end;
default1([':',M,F|As], _, St) ->
    {yes,['call',?Q(M),?Q(F)|As], St};
default1(['?'], _, St) ->
    {yes,['receive',['omega','omega']], St};
default1(['let*'|Lbody], _, St) ->
    case Lbody of
	[[Vb|Vbs]|B] -> {yes,['let',[Vb],['let*',Vbs|B]], St};
	[[]|B] -> {yes,['begin'|B], St};
	[Vb|B] -> {yes,['let',Vb|B], St}	%Pass error to let for lint.
    end;
default1(['flet*'|Lbody], _, St) ->
    case Lbody of
	[[Vb|Vbs]|B] -> {yes,['flet',[Vb],['flet*',Vbs|B]], St};
	[[]|B] -> {yes,['begin'|B], St};
	[Vb|B] -> {yes,['flet',Vb|B], St}	%Pass error to flet for lint.
    end;
default1(['cond'|Cbody], _, St) ->
    case Cbody of
	[['else'|B]] -> {yes,['begin'|B], St};
	[[['?=',P,E]|B]|Cond] ->
	    {yes,['case',E,[P|B],['_',['cond'|Cond]]], St};
	[[['?=',P,['when',_]=G,E]|B]|Cond] ->
	    {yes,['case',E,[P,G|B],['_',['cond'|Cond]]], St};
	[[Test|B]|Cond] ->
	    {yes,['if',Test,['begin'|B],['cond'|Cond]], St};
	[] -> {yes,?Q(false),St}
    end;
default1(['do'|Dbody], _, St0) ->
    %% (do ((v i c) ...) (test val) . body) but of limited use as it
    %% stands as we have to everything in new values.
    [Pars,[Test,Ret]|B] = Dbody,		%Check syntax
    {Vs,Is,Cs} = foldr(fun ([V,I,C], {Vs,Is,Cs}) -> {[V|Vs],[I|Is],[C|Cs]} end,
		       {[],[],[]}, Pars),
    {Fun,St1} = new_fun_name("do", St0),
    Exp = ['fletrec',
	   [[Fun,[lambda,Vs,
		  ['if',Test,Ret,
		   ['begin'] ++ B ++ [[Fun|Cs]]]]]],
	   [Fun|Is]],
    {yes,Exp,St1};
default1([lc|Lbody], _, St0) ->
    %% (lc (qual ...) e ...)
    [Qs|E] = Lbody,
    {Exp,St1} = lc_te(E, Qs, St0),
    {yes,Exp,St1};
default1([bc|Lbody], _, St0) ->
    %% (bc (qual ...) e ...)
    [Qs|E] = Lbody,
    {Exp,St1} = bc_te(E, Qs, St0),
    {yes,Exp,St1};
default1(['andalso'|Abody], _, St) ->
    case Abody of
	[E] -> {yes,E,St};
	[E|Es] ->
	    Exp = ['case',E,[?Q(true),['andalso'|Es]],[?Q(false),?Q(false)]],
	    {yes,Exp,St};
	[] -> {yes,?Q(true),St}
    end;
default1(['orelse'|Obody], _, St) ->
    case Obody of
	[E] -> {yes,E,St};			%Let user check last call
	[E|Es] ->
	    Exp = ['case',E,[?Q(true),?Q(true)],[?Q(false),['orelse'|Es]]],
	    {yes,Exp,St};
	[] -> {yes,?Q(false),St}
    end;
default1(['fun',F,Ar], _, St0) when is_atom(F), is_integer(Ar), Ar >= 0 ->
    {Vs,St1} = new_symbs(Ar, St0),
    {yes,['lambda',Vs,[F|Vs]],St1};
default1(['fun',M,F,Ar], _, St0)
  when is_atom(M), is_atom(F), is_integer(Ar), Ar >= 0 ->
    {Vs,St1} = new_symbs(Ar, St0),
    {yes,['lambda',Vs,['call',?Q(M),?Q(F)|Vs]],St1};
default1(['define-record'|Def], Env0, St0) ->
    {Rec,_,St1} = def_record(Def, Env0, St0),
    {yes,Rec,St1};
default1(['include-file'|Ibody], _, St) ->
    %% This is a VERY simple include file macro!
    [F] = Ibody,
    Fs = lfe_io:read_file(F),
    {yes,['begin'|Fs],St};
%% This was not a call to a predefined macro.
default1(_, _, _) -> no.

new_symb(St) ->
    C = St#mac.vc,
    {list_to_atom("|-" ++ integer_to_list(C) ++ "-|"),St#mac{vc=C+1}}.

new_symbs(N, St) -> new_symbs(N, St, []).

new_symbs(N, St0, Vs) when N > 0 ->
    {V,St1} = new_symb(St0),
    new_symbs(N-1, St1, [V|Vs]);
new_symbs(0, St, Vs) -> {Vs,St}.    

new_fun_name(Pre, St) ->
    C = St#mac.vc,
    {list_to_atom(Pre ++ "$^" ++ integer_to_list(C)),St#mac{vc=C+1}}.

%%  By Andr� van Tonder
%%  Unoptimized.  See Dybvig source for optimized version.
%%  Resembles one by Richard Kelsey and Jonathan Rees.
%%   (define-syntax quasiquote
%%     (lambda (s)
%%       (define (qq-expand x level)
%%         (syntax-case x (quasiquote unquote unquote-splicing)
%%           (`x   (quasisyntax (list 'quasiquote
%%                                    #,(qq-expand (syntax x) (+ level 1)))))
%%           (,x (> level 0)
%%                 (quasisyntax (cons 'unquote
%%                                    #,(qq-expand (syntax x) (- level 1)))))
%%           (,@x (> level 0)
%%                 (quasisyntax (cons 'unquote-splicing
%%                                    #,(qq-expand (syntax x) (- level 1)))))
%%           (,x (= level 0)
%%                 (syntax x))
%%           (((unquote x ...) . y)
%%            (= level 0)
%%                 (quasisyntax (append (list x ...)
%%                                      #,(qq-expand (syntax y) 0))))
%%           (((unquote-splicing x ...) . y)
%%            (= level 0)
%%                 (quasisyntax (append (append x ...)
%%                                      #,(qq-expand (syntax y) 0))))
%%           ((x . y)
%%                 (quasisyntax (cons  #,(qq-expand (syntax x) level)
%%                                     #,(qq-expand (syntax y) level))))
%%           (#(x ...)
%%                 (quasisyntax (list->vector #,(qq-expand (syntax (x ...))    
%%                                                         level))))
%%           (x    (syntax 'x)))) 
%%       (syntax-case s ()
%%         ((_ x) (qq-expand (syntax x) 0)))))

%% qq_expand(Exp) -> Exp.
%%  Not very efficient quasiquote expander, but very compact code.  Is
%%  R6RS compliant and can handle unquote and unquote-splicing with
%%  more than one argument properly.  Actually with simple cons/append
%%  optimisers code now quite good.

qq_expand(Exp) -> qq_expand(Exp, 0).

qq_expand([quasiquote,X], N) ->
    [list,[quote,quasiquote],qq_expand(X, N+1)];
qq_expand([unquote|X], N) when N > 0 ->
    qq_cons([quote,unquote], qq_expand(X, N-1));
qq_expand([unquote,X], 0) -> X;
qq_expand(['unquote-splicing'|X], N) when N > 0 ->
    qq_cons([quote,'unquote-splicing'], qq_expand(X, N-1));
%% Next 2 handle case of splicing into a list.
qq_expand([[unquote|X]|Y], 0) ->
    qq_append([list|X], qq_expand(Y, 0));
qq_expand([['unquote-splicing'|X]|Y], 0) ->
    qq_append(['++'|X], qq_expand(Y, 0));
qq_expand([X|Y], N) ->
    qq_cons(qq_expand(X, N), qq_expand(Y, N));
qq_expand(X, N) when is_tuple(X) ->
%%     [list_to_tuple,qq_expand(tuple_to_list(X), N)];
    [tuple|tl(qq_expand(tuple_to_list(X), N))];
qq_expand(X, _) when is_atom(X) -> [quote,X];
qq_expand(X, _) -> X.

qq_append(['++',L], R) -> qq_append(L, R);	%Catch single unquote-splice
qq_append([], R) -> R;
qq_append(L, []) -> L;
%% Will these 2 cases move code errors illegally?
qq_append([list,L], [list|R]) -> [list,L|R];
qq_append([list,L], R) -> [cons,L,R];
%%qq_append(['++'|L], R) -> ['++'|L ++ [R]];
%%qq_append(L, ['++'|R]) -> ['++',L|R];
qq_append(L, R) -> ['++',L,R].

qq_cons([quote,L], [quote,R]) -> [quote,[L|R]];
qq_cons(L, [list|R]) -> [list,L|R];
qq_cons(L, []) -> [list,L];
qq_cons(L, R) -> [cons,L,R].


%% Macro by Example
%% Proper syntax-rules which can handle ... ellipsis by Dorai Sitaram.
%%
%% While we extend patterns to include tuples and binaries as in
%% normal LFE we leave the keyword handling in even though it is
%% subsumed by quotes and not really used.

%% To make it more lispy!
-define(car(L), hd(L)).
-define(cdr(L), tl(L)).
-define(cadr(L), hd(tl(L))).
-define(cddr(L), tl(tl(L))).

-define(mbe_ellipsis(Car, Cddr), [Car,'...'|Cddr]).

is_mbe_symbol(S) ->
    is_atom(S) andalso (S /= true) andalso (S /= false).

%% Tests if ellipsis pattern, (p ... . rest)
is_mbe_ellipsis(?mbe_ellipsis(_, _)) -> true;
is_mbe_ellipsis(_) -> false.

%% mbe_match_pat(Pat, E, K) ->
%%     io:fwrite("mmp: ~p\n", [{Pat,E,K}]),
%%     Res = mbe_match_pat_1(Pat, E, K),
%%     io:fwrite("  => ~p\n", [Res]),
%%     Res.

mbe_match_pat([quote,P], E, _) -> P =:= E;
mbe_match_pat([tuple|Ps], [tuple|Es], K) ->	%Match tuple constructor
    mbe_match_pat(Ps, Es, K);
mbe_match_pat([tuple|Ps], E, K) ->		%Match literal tuple
    case is_tuple(E) of
	true -> mbe_match_pat(Ps, tuple_to_list(E), K);
	false -> false
    end;
mbe_match_pat(?mbe_ellipsis(Pcar, _), E, K) ->
    case is_proper_list(E) of
	true ->
	    all(fun (X) -> mbe_match_pat(Pcar, X, K) end, E);
	false -> false
    end;
mbe_match_pat([Pcar|Pcdr], E, K) ->    
    case E of
	[Ecar|Ecdr] ->
	    mbe_match_pat(Pcar, Ecar, K) andalso
		mbe_match_pat(Pcdr, Ecdr, K);
	_ -> false
    end;
mbe_match_pat(Pat, E, K) ->    
    case is_mbe_symbol(Pat) of
	true ->
	    case member(Pat, K) of
		true -> Pat =:= E;
		false -> true
	    end;
	false -> Pat =:= E
    end.

%% mbe_get_ellipsis_nestings(Pat, K) ->
%%     io:fwrite("mgen: ~p\n", [{Pat,K}]),
%%     Res = m_g_e_n(Pat, K),
%%     io:fwrite("   => ~p\n", [Res]),
%%     Res.

mbe_get_ellipsis_nestings(Pat, K) ->
    m_g_e_n(Pat, K).

m_g_e_n([quote,_], _) -> [];
m_g_e_n([tuple|Ps], K) -> m_g_e_n(Ps, K);
m_g_e_n(?mbe_ellipsis(Pcar, Pcddr), K) ->
    [m_g_e_n(Pcar, K)|m_g_e_n(Pcddr, K)];
m_g_e_n([Pcar|Pcdr], K) ->
    m_g_e_n(Pcar, K) ++ m_g_e_n(Pcdr, K);
m_g_e_n(Pat, K) ->
    case is_mbe_symbol(Pat) of
	true ->
	    case member(Pat, K) of
		true -> [];
		false -> [Pat]
	    end;
	false -> []
    end.

%% mbe_ellipsis_sub_envs(Nestings, R) ->
%%     io:fwrite("mese:  ~p\n", [{Nestings,R}]),
%%     Res = mbe_ellipsis_sub_envs_1(Nestings, R),
%%     io:fwrite("mese=> ~p\n", [Res]),
%%     Res.

mbe_ellipsis_sub_envs(Nestings, R) ->
    ormap(fun (C) ->
		  case mbe_intersect(Nestings, ?car(C)) of
		      true -> ?cdr(C);
		      false -> false
		  end end, R).

%% Return first value of F applied to elements in list which is not false.
ormap(F, [H|T]) ->
    case F(H) of
	false -> ormap(F, T);
	V -> V
    end;
ormap(_, []) -> [].
    

%% mbe_intersect(V, Y) ->
%%     io:fwrite("mi: ~p\n", [{V,Y}]),
%%     Res = mbe_intersect_1(V, Y),
%%     io:fwrite("  => ~p\n", [Res]),
%%     Res.

mbe_intersect(V, Y) ->
    case is_mbe_symbol(V) orelse is_mbe_symbol(Y) of
	true -> V =:= Y;
	false ->
	    any(fun (V0) ->
			any(fun (Y0) -> mbe_intersect(V0, Y0) end, Y)
		end, V)
    end.

%% mbe_get_bindings(Pattern, Expression, Keywords) -> Bindings.

%% mbe_get_bindings(Pat, E, K) ->
%%     io:fwrite("mgb:  ~p\n", [{Pat,E,K}]),
%%     Res = mbe_get_bindings_1(Pat, E, K),
%%     io:fwrite("mgb=> ~p\n", [Res]),
%%     Res.

mbe_get_bindings([quote,_], _, _) -> [];
mbe_get_bindings([tuple|Ps], [tuple|Es], K) ->	%Tuple constructor
    mbe_get_bindings(Ps, Es, K);
mbe_get_bindings([tuple|Ps], E, K) ->		%Literal tuple
    mbe_get_bindings(Ps, tuple_to_list(E), K);
mbe_get_bindings(?mbe_ellipsis(Pcar, _), E, K) ->
    [[mbe_get_ellipsis_nestings(Pcar, K) |
      map(fun (X) -> mbe_get_bindings(Pcar, X, K) end, E)]];
mbe_get_bindings([Pcar|Pcdr], [Ecar|Ecdr], K) ->
    mbe_get_bindings(Pcar, Ecar, K) ++
	mbe_get_bindings(Pcdr, Ecdr, K);
mbe_get_bindings(Pat, E, K) ->
    case is_mbe_symbol(Pat) of
	true ->
	    case member(Pat, K) of
		true -> [];
		false -> [[Pat|E]]
	    end;
	false -> []
    end.

%% mbe_expand_pattern(Pattern, Bindings, Keywords) -> Form.

%% mbe_expand_pattern(Pat, R, K) ->
%%     io:fwrite("mep:  ~p\n", [{Pat,R,K}]),
%%     Res = mbe_expand_pattern_1(Pat, R, K),
%%     io:fwrite("mep=> ~p\n", [Res]),
%%     Res.

mbe_expand_pattern([quote,P], R, K) ->
    [quote,mbe_expand_pattern(P, R, K)];
mbe_expand_pattern([tuple|Ps], R, K) ->
    [tuple|mbe_expand_pattern(Ps, R, K)];
mbe_expand_pattern(?mbe_ellipsis(Pcar, Pcddr), R, K) ->
    Nestings = mbe_get_ellipsis_nestings(Pcar, K),
    Rr = mbe_ellipsis_sub_envs(Nestings, R),
    map(fun (R0) -> mbe_expand_pattern(Pcar, R0 ++ R, K) end, Rr) ++
		mbe_expand_pattern(Pcddr, R, K);
mbe_expand_pattern([Pcar|Pcdr], R, K) ->
    [mbe_expand_pattern(Pcar, R, K)|
     mbe_expand_pattern(Pcdr, R, K)];
mbe_expand_pattern(Pat, R, K) ->
    case is_mbe_symbol(Pat) of
	true ->
	    case member(Pat, K) of
		true -> Pat;
		false ->
		    case assoc(Pat, R) of
			[_|Cdr] -> Cdr;
			[] -> Pat
		    end
	    end;
	false -> Pat
    end.

assoc(P, [[P|_]=Pair|_]) -> Pair;
assoc(P, [_|L]) -> assoc(P, L);
assoc(_, []) -> [].

%% mbe_syntax_rules_proc(Name, Keywords, Rules, Argsym, Keywordsym) ->
%%      Sexpr.
%%  Generate the sexpr to evaluate in a macro from Name and
%%  Rules. When the sexpr is applied to arguments (in Argsym) and
%%  evaluated then expansion is returned.

%% mbe_syntax_rules_proc(Name, Ks0, Cls, Argsym, Ksym) ->
%%     io:fwrite("msrp: ~p\n", [{Name,Ks0,Cls,Argsym,Ksym}]),
%%     Res = mbe_syntax_rules_proc_1(Name, Ks0, Cls, Argsym, Ksym),
%%     io:fwrite("   => ~p\n", [Res]),
%%     Res.

%% Return sexpr to evaluate.
mbe_syntax_rules_proc(Name, Ks0, Cls, Argsym, Ksym) ->
    Ks = [Name|Ks0],
    %% Don't prepend the macro name to the arguments!
    ['let',[[Ksym,[quote,Ks]]],
     ['cond'] ++
     map(fun (C) ->
		 Inpat = hd(C),
		 Outpat = hd(tl(C)),
		 [[':',lfe_macro,mbe_match_pat,[quote,Inpat], Argsym, Ksym],
		  ['let',
		   [[r,[':',lfe_macro,mbe_get_bindings,
			[quote,Inpat],Argsym,Ksym]]],
		   [':',lfe_macro,mbe_expand_pattern,[quote,Outpat],r,Ksym]]]
	 end, Cls) ++
    [[[quote,true],[exit,[tuple,[quote,macro_clause],[quote,Name]]]]]].

%% Do it all directly.
mbe_syntax_rules_proc(Name, Ks0, Cls, Args) ->
    Ks = [Name|Ks0],
    case ormap(fun ([Pat,Exp]) ->
		       case mbe_match_pat(Pat, Args, Ks) of
			   true ->
			       R = mbe_get_bindings(Pat, Args, Ks),
			       [mbe_expand_pattern(Exp, R, Ks)];
			   false -> false
		       end
	       end, Cls) of
	[Res] -> Res;
	false -> exit({macro_clause,Name})
    end.

%% lc_te(Exprs, Qualifiers, State) -> {Exp,State}.
%% bc_te(Exprs, Qualifiers, State) -> {Exp,State}.
%%  Expand a list/binary comprehension. Algorithm straight out of
%%  Simon PJs book.

%% lc_te(Es, Qs, St) -> lc_tq(Es, Qs, [], St).
lc_te(Es, Qs, St) ->
    c_tq(fun (L, S) -> {[cons,['begin'|Es],L],S} end, Qs, [], St).

%%bc_te(Es, Qs, St) -> bc_tq(Es, Qs, <<>>, St).
bc_te(Es, Qs, St) ->
    c_tq(fun (L, S) ->
		 case reverse(Es) of
		     [R] -> {[binary,R,[L,bitstring]],S};
		     [R|Rs] -> {['begin'|reverse(Rs)] ++
				[[binary,R,[L,bitstring]]],S};
		     [] -> {L,S}
		 end
	 end, Qs, <<>>, St).
    
c_tq(Exp, [['<-',P,G]|Qs], L, St0) ->		%List generator
    {H,St1} = new_fun_name("lc", St0),		%Function name
    {Us,St2} = new_symb(St1),			%Tail variable
    {Rest,St3} = c_tq(Exp, Qs, [H,Us], St2),	%Do rest of qualifiers
    {['fletrec',
      [[H,['match-lambda',
	   [[[P|Us]],Rest],			%Matches pattern
	   [[['_'|Us]],[H,Us]],			%No match
	   [[[]],L]]]],				%End of list
      [H,G]],St3};
c_tq(Exp, [['<=',P,G]|Qs], L, St0) ->		%Bits generator
    {H,St1} = new_fun_name("bc", St0),		%Function name
    {B,St2} = new_symb(St1),			%Bin variable
    {Rest,St3} = c_tq(Exp, Qs, [H,B], St2),	%Do rest of qualifiers
    Brest = [B,bitstring,'big-endian',unsigned,[unit,1]], %,[size,all]
    {['fletrec',
      [[H,['match-lambda',
	   [[[binary,P,Brest]],Rest],		%Matches pattern
%%	   [[[binary,Brest]],[H,B]]]]],		%No match
	   [[[binary,Brest]],L]]]],		%No match
      [H,G]],St3};
c_tq(Exp, [['?=',P,E]|Qs], L, St0) ->
    {Rest,St1} = c_tq(Exp, Qs, L, St0),
    {['case',E,[P,Rest],['_',L]],St1};
c_tq(Exp, [['?=',P,['when',_]=G,E]|Qs], L, St0) ->
    {Rest,St1} = c_tq(Exp, Qs, L, St0),
    {['case',E,[P,G,Rest],['_',L]],St1};
c_tq(Exp, [T|Qs], L, St0) ->
    {Rest,St1} = c_tq(Exp, Qs, L, St0),
    {['if',T,Rest,L],St1};
c_tq(Exp, [], L, St) ->
    Exp(L, St).

%% expand_macro_1(Form, Env) -> {yes,Exp} | no.
%% expand_macro(Form, Env) -> {yes,Exp} | no.
%%  User functions for testing macro expansions, either one expansion
%%  or as far as it can go.

expand_macro(Form, Env) ->
    case expand_macro_1(Form, Env) of
	{yes,Exp} -> {yes,expand_macro_loop(Exp, Env)};
	no -> no
    end.

expand_macro_loop(Form, Env) ->
    case expand_macro_1(Form, Env) of
	{yes,Exp} -> expand_macro_loop(Exp, Env);
	no -> Form
    end.

expand_macro_1([Name|Args]=Call, Env) when is_atom(Name) ->
    case lfe_lib:is_core_form(Name) of
	true -> no;				%Don't expand core forms
	false ->
	    case mbinding(Name, Env) of		%User macro bindings
		{yes,['syntax-rules'|Rules]} ->
		    {yes,mbe_syntax_rules_proc(Name, [], Rules, Args)};
		{yes,[macro|Cls]} ->
		    %% We have to expand and evaluate the macro.
		    {Exp,_} = expand(['case',[quote,Args]|Cls], Env, #mac{}),
		    Ev = lfe_eval:eval(Exp, Env),
		    {yes,Ev};
		no ->
		    %% Default macro bindings
		    case default1(Call, Env, #mac{}) of
			{yes,Exp,_} -> {yes,Exp};
			no -> no
		    end
	    end
	end;
expand_macro_1(_, _) -> no.
