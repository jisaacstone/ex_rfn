# Recursive Anonymous Functions in Elixir
### A Tale of Combinators and Macros

## 1. Recursion

Recursion is the core of Elixir and Erlang code. But it is missing from anonymous functions.

```
iex(9)> sum = fn [] -> 0; [h|t] -> h + sum.(t) end
** (CompileError) iex:9: undefined function sum/0
		(stdlib) lists.erl:1353: :lists.mapfoldl/3
		(stdlib) lists.erl:1354: :lists.mapfoldl/3
```

Why? In a match expression the right hand side is evaluated first, then matched to the left.
So the variable `sum` has not yet been assigned a value when `fn [] -> 0; [h|t] -> h + sum.(t) end` is evaluated.

## 2. Erlang R17

Recursive anonymous functions were added to Erlang in R17. Elixir solved the match
problem by including a name in the right hand side of the match expression.

From [Joe Armstrong's Announcement](http://joearms.github.io/2014/02/01/big-changes-to-erlang.html):

```erlang
F = fun Fact(0) -> 1; 
		Fact(N) -> N * Fact(N - 1) 
	end.
```

But elixir core team has not yet finalized if or how they will include the same functionality.

But there's no need to wait; using macros we can extend elixir syntax (almost) however we'd like.

## 3. Combinators

Mathematicians and computer scientists have solved the problem of implementing recursion: [the fixed-point combinator](https://en.wikipedia.org/wiki/Fixed-point_combinator)

I am not a mathematician or a computer scientist but thanks to [The Little Schemer](https://mitpress.mit.edu/index.php?q=books/little-schemer) I know a bit
about combinators anyway. And fortunatly others have already written some in elixir. [Here is a Y combinator](http://stackoverflow.com/a/25829932/579260), and [here is a Z combinator](https://github.com/Dkendal/exyz/blob/master/lib/exyz.ex)

`exyz` is [available on hex](https://hex.pm/packages/exyz) and works like this:
```elixir
factorial = Exyz.z_combinator fn(f) ->
  fn
    (1) -> 1
    (n) -> n * f.(n - 1)
  end
end

factorial.(5) == 120
```

Beautiful. But it is limited: it can only handle functions with an arity of 1.

(This is not really a limitation. Using a list or tuple argument is natural and easy. But I wanted to try and improve it
anyway)

## 4. Plan

I want to build a macro that can handle all functions, regardless of arity. This is the syntax I want:

```elixir
f = rfn count, fn
  (_, [], c) -> c
  (x, [x|t], c) -> count.(x, t, c + 1)
  (x, [_|t], c) -> count.(x, t, c)
end

f.(:a, [:a, :b, :b, :a], 0) == 2
```

I will be building off of the Z combinator in `exyz`:

```elixir
def z_combinator f do
	combinator = fn(x) ->
		f.(fn(y) -> x.(x).(y) end)
	end
	combinator.(combinator)
end
```

After staring at it for a half hour I determined I'd need to change all occurrences
of `y` to `y0, y1 ... yN` where `N == arity(f)`

## 5. Quote

Lets take a look at the abstract syntax tree of an `fn`

```elixir
iex> quote do fn(a, b) -> :ok end end
{:fn, [], [{:->, [], [[{:a, [], Elixir}, {:b, [], Elixir}], :ok]}]}
```

I can see where args `a` and `b` are. So I'll need 3 functions. On to count the number of
args in a `fn`, one to generate n args, and one to create an abstract syntax tree with those args.

Generating args is simple. We can use [`Macro.var/2`](http://elixir-lang.org/docs/v1.2/elixir/Macro.html#var/2)

```elixir
def gen_args(0, args), do: args
def gen_args(n, args) do
	n_args(n - 1, [Macro.var(:"arg_#{n - 1}", __MODULE__) | args])
end
```

Testing it out:

```elixir
iex> args = gen_args(2, [])
[{:arg0, [], Rfn}, {:arg1, [], Rfn}]

iex> ast = quote do fn unquote(args) -> :ok end end
{:fn, [], [{:->, [], [[[{:arg0, [], Rfn}, {:arg1, [], Rfn}]], :ok]}]}

iex> Macro.to_string(ast)
"fn [arg0, arg1] -> :ok end"
```

That didn't quite work. Instead of a `fn` with arity 2, I generated a function with 
arity 1 that matched against a 2 element list.

So here's where I get a bit tricky. While I would never use this in production, nothing
is preventing me from hand-rolling an abstract syntax tree.

```elixir
defp fn_ast(vars, meta, body) do
	{:fn, meta, [{:->, meta, [vars, body]}]}
end
```

Testing it out:

```elixir
iex> args = gen_args(2, [])
[{:arg0, [], Rfn}, {:arg1, [], Rfn}]

iex> ast = fn_ast(args, [], :ok)
{:fn, [], [{:->, [], [[{:arg0, [], Rfn}, {:arg1, [], Rfn}], :ok]}]}

iex> Macro.to_string(ast)
"fn arg0, arg1 -> :ok end"
```

Much better.

Finally a function to count the number of args. Reverse the `fn_ast` code above and tweak it a bit.

voilà

```elixir
defp num_args({:->, _, [args | _body]}) do
	length(args)
end
```

## 5. Putting it together

Now we have a way to genereate a `fn` with arity `n` we can improve the z combinator from before to handle `fn`s of any arity!

```elixir
defmacro rfn(var, {:fn, meta, [c|_clauses]} = f) do
	n = num_args(c)
	args = gen_args(n, [])
	namedf = quote do
		fn (unquote(var)) -> unquote(f) end
	end
	combinator_fun = combinator_ast(namedf, args, meta)
	quote do
		combinator = unquote(combinator_fun)
		combinator.(combinator)
	end
end

defp combinator_ast(namedf, args, meta) do
	xvar = Macro.var(:x, __MODULE__)
	# fn (args...) -> xvar.(xvar).(args...) end
	inner = fn_ast(args, {
		{ :., meta,
			[ { {:., meta, [xvar]}, meta,
					[xvar] } ] },
		meta, args }, meta )

	# fn (xvar) -> var.(inner) end
	quote do
		fn unquote(xvar) -> unquote(namedf).(unquote(inner)) end
	end
end
```

testing it out:

```elixir
iex> import Rfn
nil
iex> f = rfn count, fn
...>   (_, [], c) -> c
...>   (x, [x|t], c) -> count.(x, t, c + 1)
...>   (x, [_|t], c) -> count.(x, t, c)
...> end
#Function<18.54118792/3 in :erl_eval.expr/5>
iex> f.(:a, [:a, :b, :b, :a], 0) == 2
true
```

It works!

## 6. Caution

Macros are hard. Even harder is manipulation the elixir abstract syntax tree. There is no guarentee the ast will not change
in different environments and different platforms. I already know many situations where the code given here will fail.
For example it does not handle guard clauses.

The first setp to writing relable macros is not to write them. If you really feel compelled you still should use `quote` and
`unquote` instead for hand-rolling an abstract syntax tree.
