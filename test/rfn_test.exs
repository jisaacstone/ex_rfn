defmodule RfnTest do
  use ExUnit.Case
  import Rfn

  test "the truth" do
    sum = rfn :s, fn
      [] -> 0
      [h|t] -> h + s.(t)
    end
    assert sum.([1,2,3]) == 6
  end

  test "bubbles" do
    bubbles = rfn :bubbles, fn
      (l, n) when is_list(l) and n > 0 ->
        bubbles.(hd(l), n - 1)
      (x, y) ->
        {y, x}
    end
    assert bubbles.([[[:a], :b]], 7) == {4, :a}
  end
end
