defmodule Resolver.PackageLister do
  alias Resolver.{Constraint, Incompatibility, PackageLister, PackageRange, Term}
  alias Resolver.Constraints.{Range, Version}

  defstruct registry: nil,
            root_dependencies: [],
            locked: [],
            overrides: [],
            already_returned: %{}

  # Prefer packages with few remaining versions so that if there is conflict
  # later it will be forced quickly
  def pick_package(lister, package_ranges) do
    package_range_versions =
      Enum.map(package_ranges, fn package_range ->
        case versions(lister, package_range.name) do
          {:ok, versions} ->
            allowed = Enum.filter(versions, &Constraint.allows?(package_range.constraint, &1))
            {package_range, allowed}

          :error ->
            throw({__MODULE__, :minimal_versions, package_range.name})
        end
      end)

    {package_range, versions} =
      Enum.min_by(package_range_versions, fn {_package_range, versions} -> length(versions) end)

    {:ok, package_range, List.first(Enum.sort(versions, &Version.prioritize/2))}
  catch
    :throw, {__MODULE__, :minimal_versions, name} ->
      {:error, name}
  end

  def dependencies_as_incompatibilities(
        %PackageLister{
          already_returned: already_returned,
          overrides: overrides
        } = lister,
        package,
        version
      ) do
    {:ok, versions} = versions(lister, package)
    already_returned = Map.get(already_returned, package, %{})

    versions_dependencies =
      Enum.map(versions, fn version ->
        {:ok, dependencies} = dependencies(lister, package, version)
        {version, Map.new(dependencies)}
      end)

    {_version, dependencies} = List.keyfind(versions_dependencies, version, 0)

    incompatibilities =
      dependencies
      |> Enum.sort()
      |> Enum.reject(fn {dependency, _} -> dependency in overrides and package != "$root" end)
      |> Enum.reject(fn {dependency, _} ->
        case Map.fetch(already_returned, dependency) do
          {:ok, returned_constraint} -> Constraint.allows?(returned_constraint, version)
          :error -> false
        end
      end)
      |> Enum.map(fn {dependency, {constraint, optional}} ->
        version_constraints =
          Enum.map(versions_dependencies, fn {version, dependencies} ->
            {version, dependencies[dependency]}
          end)

        # Find range of versions around the current version for which the
        # constraint is the same to create an incompatibility based on a
        # larger set of versions for the parent package.
        # This optimization let us skip many versions during conflict resolution.
        lower = lower_bound(Enum.reverse(version_constraints), version, {constraint, optional})
        upper = upper_bound(version_constraints, version, {constraint, optional})

        range = %Range{min: lower, max: upper, include_min: !!lower}
        package_range = %PackageRange{name: package, constraint: range}
        dependency_range = %PackageRange{name: dependency, constraint: constraint}
        package_term = %Term{positive: true, package_range: package_range}

        dependency_term = %Term{
          positive: false,
          package_range: dependency_range,
          optional: optional
        }

        Incompatibility.new([package_term, dependency_term], :dependency)
      end)

    already_returned =
      Enum.reduce(incompatibilities, already_returned, fn incompatibility, acc ->
        [package_term, dependency_term] =
          case incompatibility do
            %Incompatibility{terms: [single]} -> [single, single]
            %Incompatibility{terms: [package, dependency]} -> [package, dependency]
          end

        name = dependency_term.package_range.name
        constraint = package_term.package_range.constraint
        Map.update(acc, name, constraint, &Constraint.union(&1, constraint))
      end)

    {put_in(lister.already_returned[package], already_returned), incompatibilities}
  end

  defp lower_bound(versions_dependencies, version, constraint) do
    [{version, _} | versions_dependencies] = skip_to_version(versions_dependencies, version)

    skip_to_last_constraint(versions_dependencies, constraint, version)
  end

  defp upper_bound(versions_dependencies, version, constraint) do
    versions_dependencies = skip_to_version(versions_dependencies, version)
    skip_to_after_constraint(versions_dependencies, constraint)
  end

  defp skip_to_version([{version, _constraint} | _] = versions_dependencies, version) do
    versions_dependencies
  end

  defp skip_to_version([_ | versions_dependencies], version) do
    skip_to_version(versions_dependencies, version)
  end

  defp skip_to_last_constraint([{version, constraint} | versions_dependencies], constraint, _last) do
    skip_to_last_constraint(versions_dependencies, constraint, version)
  end

  defp skip_to_last_constraint([], _constraint, _last) do
    nil
  end

  defp skip_to_last_constraint(_versions_dependencies, _constraint, last) do
    last
  end

  defp skip_to_after_constraint(
         [{_, constraint}, {version, constraint} | versions_dependencies],
         constraint
       ) do
    skip_to_after_constraint([{version, constraint} | versions_dependencies], constraint)
  end

  defp skip_to_after_constraint([_, {version, _} | _versions_dependencies], _) do
    version
  end

  defp skip_to_after_constraint(_, _constraint) do
    nil
  end

  @version_1 Elixir.Version.parse!("1.0.0")

  defp versions(_lister, "$root"), do: {:ok, [@version_1]}
  defp versions(_lister, "$lock"), do: {:ok, [@version_1]}
  defp versions(%PackageLister{registry: registry}, package), do: registry.versions(package)

  defp dependencies(
         %PackageLister{root_dependencies: dependencies, locked: locked},
         "$root",
         @version_1
       ) do
    {:ok, dependencies ++ if(locked == [], do: [], else: [{"$lock", {@version_1, false}}])}
  end

  defp dependencies(%PackageLister{locked: locked}, "$lock", @version_1) do
    {:ok, locked}
  end

  defp dependencies(%PackageLister{registry: registry}, package, version) do
    registry.dependencies(package, version)
  end
end
