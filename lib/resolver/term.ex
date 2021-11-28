defmodule Resolver.Term do
  alias Resolver.{Constraint, PackageRange, Term}
  alias Resolver.Constraints.Empty

  require Logger

  defstruct positive: true,
            package_range: nil,
            optional: false

  def relation(%Term{} = left, %Term{} = right) do
    true = compatible_package?(left, right)

    left_constraint = constraint(left)
    right_constraint = constraint(right)

    cond do
      right.positive and left.positive ->
        cond do
          Constraint.allows_all?(right_constraint, left_constraint) -> :subset
          not Constraint.allows_any?(left_constraint, right_constraint) -> :disjoint
          true -> :overlapping
        end

      right.positive and not left.positive ->
        cond do
          Constraint.allows_all?(left_constraint, right_constraint) -> :disjoint
          true -> :overlapping
        end

      not right.positive and left.positive ->
        cond do
          not Constraint.allows_any?(right_constraint, left_constraint) -> :subset
          Constraint.allows_all?(right_constraint, left_constraint) -> :disjoint
          true -> :overlapping
        end

      not right.positive and not left.positive ->
        cond do
          Constraint.allows_all?(left_constraint, right_constraint) -> :subset
          true -> :overlapping
        end
    end
  end

  def intersect(%Term{} = left, %Term{} = right) do
    true = compatible_package?(left, right)

    cond do
      left.positive != right.positive ->
        positive = if left.positive, do: left, else: right
        negative = if left.positive, do: right, else: left

        constraint = Constraint.difference(constraint(positive), constraint(negative))
        non_empty_term(left, constraint, true)

      left.positive and right.positive ->
        constraint = Constraint.intersect(constraint(left), constraint(right))
        non_empty_term(left, constraint, true)

      not left.positive and not right.positive ->
        constraint = Constraint.union(constraint(left), constraint(right))
        non_empty_term(left, constraint, false)
    end
  end

  def difference(%Term{} = left, %Term{} = right) do
    intersect(left, inverse(right))
  end

  def satisfies?(%Term{} = left, %Term{} = right) do
    compatible_package?(left, right) and relation(left, right) == :subset
  end

  def inverse(%Term{} = term) do
    %{term | positive: not term.positive}
  end

  def compatible_package?(%Term{} = left, %Term{} = right) do
    left.package_range.name == right.package_range.name
  end

  defp constraint(%Term{package_range: %PackageRange{constraint: constraint}}) do
    constraint
  end

  defp non_empty_term(_term, %Empty{}, _positive) do
    nil
  end

  defp non_empty_term(term, constraint, positive) do
    %Term{
      package_range: %{term.package_range | constraint: constraint},
      positive: positive
    }
  end

  def to_string(%Term{package_range: package_range, positive: positive}) do
    "#{positive(positive)}#{package_range}"
  end

  defp positive(true), do: ""
  defp positive(false), do: "not "

  defimpl String.Chars do
    defdelegate to_string(term), to: Resolver.Term
  end

  defimpl Inspect do
    def inspect(
          %Term{package_range: package_range, positive: positive, optional: optional},
          _opts
        ) do
      "#Term<#{positive(positive)}#{package_range}#{optional(optional)}>"
    end

    defp positive(true), do: ""
    defp positive(false), do: "not "

    defp optional(true), do: " (optional)"
    defp optional(false), do: ""
  end
end
