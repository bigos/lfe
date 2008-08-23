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

%% File    : lfe_parse.erl
%% Author  : Robert Virding
%% Purpose : A simple Sexpr parser.
%% A simple sexpr parser. It is not re-entrant but does return excess tokens.

-module(lfe_parse).

-export([parse/1]).

-import(lists, [reverse/1,reverse/2]).

%% parse(Tokens) -> {ok,Line,Sexpr,RestTokens}.

parse([T|_]=Ts) ->
    L = line(T),
    try
	{Sexpr,R} = sexpr(Ts),
	{ok,L,Sexpr,R}
    catch
	throw: {error,E,Rest} ->
	    {error,{L,lfe_parse,E},Rest}
    end.

%% Atoms.
sexpr([{symbol,_,S}|Ts]) -> {S,Ts};
sexpr([{number,_,N}|Ts]) -> {N,Ts};
sexpr([{string,_,S}|Ts]) -> {S,Ts};
%% Lists.
sexpr([{'(',_},{')',_}|Ts]) -> {[],Ts};
sexpr([{'(',_}|Ts0]) ->
    {S,Ts1} = sexpr(Ts0),
    case list_tail(Ts1, ')', []) of
	{Tail,[{')',_}|Ts2]} -> {[S|Tail],Ts2};
	{_,Ts2} -> throw({error,{missing,')'},Ts2})
    end;
sexpr([{'[',_},{']',_}|Ts]) -> {[],Ts};
sexpr([{'[',_}|Ts0]) ->
    {S,Ts1} = sexpr(Ts0),
    case list_tail(Ts1, ']', []) of
	{Tail,[{']',_}|Ts2]} -> {[S|Tail],Ts2};
	{_,Ts2} -> throw({error,{missing,']'},Ts2})
    end;
%% Tuple constants (using vector constant syntax).
sexpr([{'#(',_}|Ts0]) ->
    case proper_list(Ts0) of
	{List,[{')',_}|Ts1]} -> {list_to_tuple(List),Ts1};
	{_,Ts1} -> throw({error,{missing,')'},Ts1})
    end;
%% Binaries and bitstrings constants (our own special syntax).
sexpr([{'#B(',_}|Ts0]) ->
    case proper_list(Ts0) of
	{List,[{')',_}|Ts1]} ->
	    %% {[binary|List],Ts1};
	    case catch {ok,list_to_binary(List)} of
		{ok,Bin} -> {Bin,Ts1};
		_ -> throw({error,{illegal,binary},Ts1})
	    end;
	{_,Ts1} -> throw({error,{missing,')'},Ts1})
    end;
%% Quotes.
sexpr([{'\'',_}|Ts0]) ->			%Quote
    {S,Ts1} = sexpr(Ts0),
    {[quote,S],Ts1};
sexpr([{'`',_}|Ts0]) ->				%Backquote
    {S,Ts1} = sexpr(Ts0),
    {[quasiquote,S],Ts1};
sexpr([{',',_}|Ts0]) ->				%Unquote
    {S,Ts1} = sexpr(Ts0),
    {[unquote,S],Ts1};
sexpr([{',@',_}|Ts0]) ->			%Unquote splicing
    {S,Ts1} = sexpr(Ts0),
    {['unquote-splicing',S],Ts1};
%% Error cases.
sexpr([T|_]) ->
    throw({error,{illegal,op(T)},[]});
sexpr([]) ->
    throw({error,{missing,token},[]}).

list_tail([{End,_}|_]=Ts, End, Es) -> {reverse(Es),Ts};
list_tail([{'.',_}|Ts0], _, Es) ->
    {T,Ts1} = sexpr(Ts0),
    {reverse(Es, T),Ts1};
list_tail(Ts0, End, Es) ->
    {E,Ts1} = sexpr(Ts0),
    list_tail(Ts1, End, [E|Es]).

proper_list(Ts) -> proper_list(Ts, []).

proper_list([{')',_}|_]=Ts, Es) -> {reverse(Es),Ts};
proper_list(Ts0, Es) ->
    {E,Ts1} = sexpr(Ts0),
    proper_list(Ts1, [E|Es]).

%% Utilities.
op(T) -> element(1, T).
line(T) -> element(2, T).
val(T) -> element(3, T).
