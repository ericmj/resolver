defmodule Resolver.FailureTest do
  use Resolver.Case, async: true

  alias Resolver.Failure
  alias Resolver.Registry.Process, as: Registry

  defp run(dependencies, locked \\ [], overrides \\ []) do
    assert {:error, incompatibility} =
             Resolver.Resolver.run(
               Registry,
               to_dependencies(dependencies),
               to_locked(locked),
               overrides
             )

    Failure.write(incompatibility)
  end

  test "conflicting constraints 1" do
    Registry.put("foo", "1.0.0", [{"bar", "~> 2.0"}])
    Registry.put("bar", "1.0.0", [])
    Registry.put("bar", "2.0.0", [])

    assert run([{"foo", "1.0.0"}, {"bar", "~> 1.0"}]) == """
           Because every version of foo depends on bar ~> 2.0 and myapp depends on bar ~> 1.0, no version of foo is allowed.
           So, because myapp depends on foo 1.0.0, version solving failed.\
           """
  end

  test "conflicting constraints 2" do
    Registry.put("bar", "1.0.0", [{"foo", "1.0.0"}])
    Registry.put("foo", "1.0.0", [])
    Registry.put("foo", "2.0.0", [])

    assert run([{"bar", "1.0.0"}, {"foo", "~> 2.0"}]) == """
           Because myapp depends on bar 1.0.0 which depends on foo 1.0.0, foo 1.0.0 is required.
           So, because myapp depends on foo ~> 2.0, version solving failed.\
           """
  end

  test "doesn't match any versions" do
    Registry.put("foo", "1.0.0", [{"bar", "~> 2.0"}])
    Registry.put("bar", "1.0.0", [])

    assert run([{"foo", "1.0.0"}]) == """
           Because every version of foo depends on bar ~> 2.0 which doesn't match any versions, no version of foo is allowed.
           So, because myapp depends on foo 1.0.0, version solving failed.\
           """
  end

  test "linear error reporting" do
    Registry.put("foo", "1.0.0", [{"bar", "~> 2.0"}])
    Registry.put("bar", "2.0.0", [{"baz", "~> 3.0"}])
    Registry.put("baz", "1.0.0", [])
    Registry.put("baz", "3.0.0", [])

    assert run([{"foo", "~> 1.0"}, {"baz", "~> 1.0"}]) == """
           Because every version of foo depends on bar ~> 2.0 which depends on baz ~> 3.0, foo requires baz ~> 3.0.
           And because myapp depends on baz ~> 1.0, no version of foo is allowed.
           So, because myapp depends on foo ~> 1.0, version solving failed.\
           """
  end

  test "branching error reporting" do
    Registry.put("foo", "1.0.0", [{"a", "~> 1.0"}, {"b", "~> 1.0"}])
    Registry.put("foo", "1.1.0", [{"x", "~> 1.0"}, {"y", "~> 1.0"}])
    Registry.put("a", "1.0.0", [{"b", "~> 2.0"}])
    Registry.put("b", "1.0.0", [])
    Registry.put("b", "2.0.0", [])
    Registry.put("x", "1.0.0", [{"y", "~> 2.0"}])
    Registry.put("y", "1.0.0", [])
    Registry.put("y", "2.0.0", [])

    assert run([{"foo", "~> 1.0"}]) == """
               Because foo < 1.1.0 depends on a ~> 1.0 which depends on b ~> 2.0, foo < 1.1.0 requires b ~> 2.0.
           (1) So, because foo < 1.1.0 depends on b ~> 1.0, foo < 1.1.0 is forbidden.

               Because foo >= 1.1.0 depends on x ~> 1.0 which depends on y ~> 2.0, foo >= 1.1.0 requires y ~> 2.0.
               And because foo >= 1.1.0 depends on y ~> 1.0, foo >= 1.1.0 is forbidden.
               And because foo < 1.1.0 is forbidden (1), no version of foo is allowed.
               So, because myapp depends on foo ~> 1.0, version solving failed.\
           """
  end

  test "locked" do
    Registry.put("foo", "1.0.0", [])
    Registry.put("foo", "2.0.0", [])

    assert run([{"foo", "~> 2.0"}], [{"foo", "1.0.0"}]) == """
           Because lock specifies foo 1.0.0, foo 1.0.0 is required.
           So, because myapp depends on foo ~> 2.0, version solving failed.\
           """
  end
end
