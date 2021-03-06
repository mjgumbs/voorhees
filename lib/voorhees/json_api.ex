defmodule Voorhees.JSONApi do
  import ExUnit.Assertions

  def assert_schema(%{"data" => list } = actual , expected) when is_list(list) do
    list
    |> Enum.map(&(_assert_resource(&1, expected)))

    if included = actual["included"] do
      included
      |> Enum.map(&(_assert_resource(&1, expected)))
    end

    actual
  end

  def assert_schema(%{"data" => resource } = actual , expected) when is_map(resource) do
    _assert_resource(resource, expected)

    actual
  end

  def assert_schema_contains(%{"data" => resource} = actual, expected) when is_map(resource) do
    assert_schema_contains(put_in(actual["data"], [resource]), expected)

    actual
  end
  def assert_schema_contains(%{"data" => resources} = actual, expected) when is_list(resources) do
    Enum.map(resources ++ List.wrap(actual["included"]), fn(resource) -> normalize_map(resource) end)
    |> _assert_schema_contains(normalize_map(expected))

    actual
  end

  defp _assert_schema_contains(actual, expected) do
    actual_types = Enum.map(actual, fn(resource) -> resource["type"] end)
    expected_types = Map.keys(expected)

    assert length(expected_types -- actual_types) == 0,
      "Expected types: #{Enum.join(expected_types, ", ")}\nGot: #{Enum.join(actual_types, ", ")}"

    Enum.each expected_types, fn(expected_type) ->
      expected_attributes = _stringify_items(expected[expected_type]["attributes"])
      Enum.each(actual, fn(resource) ->
        if resource["type"] == expected_type do
          actual_attributes = Map.keys(resource["attributes"])
          assert length(expected_attributes -- actual_attributes) == 0,
            "Expected type: #{expected_type} to contain: #{Enum.join(expected_attributes, ", ")}\nGot: #{Enum.join(actual_attributes, ", ")}"
        end
      end)
    end
  end

  def assert_payload_contains(%{"data" => resource} = actual, expected) when is_map(resource) do
    assert_payload_contains(put_in(actual["data"], [resource]), expected)

    actual
  end
  def assert_payload_contains(%{"data" => resources} = actual, expected) when is_list(resources) do
    Enum.map(resources ++ List.wrap(actual["included"]), fn(resource) -> normalize_map(resource) end)
    |> _assert_payload_contains(normalize_map(expected))

    actual
  end
  defp _assert_payload_contains(actual, expected) do
    Map.keys(expected)
    |> Enum.each(fn(expected_type) ->
      expected[expected_type]
      |> List.wrap()
      |> Enum.each(fn(%{"attributes" => expected_attributes}) ->
        assert Enum.reduce(actual, false, fn(%{"attributes" => actual_attributes, "type" => actual_type}, result) ->
          if !result && actual_type == expected_type do
            length(Map.to_list(expected_attributes) -- Map.to_list(actual_attributes)) == 0
          else
            result
          end
        end), "Expected type: #{expected_type} to contain record with values: #{Enum.map_join(expected_attributes, ", ", fn({k, v}) -> "#{k}: #{v}" end)}"
      end)
    end)
  end

  defp _assert_resource(resource, expected) do
    %{"type" => type, "attributes" => attributes} = resource

    expected
    |> Map.fetch(String.to_atom(type))
    |> case do
      :error ->
        assert false, "Expected schema did not contain type: #{type}"
      {:ok, expected_schema} ->
        %{attributes: expected_attributes} = expected_schema
        _assert_attributes(attributes, expected_attributes)
    end
  end

  defp _assert_attributes(attributes, expected_attributes) do
    attribute_names = attributes
    |> Map.keys
    |> Enum.map(&(String.to_atom(&1)))

    extra_attributes = attribute_names -- expected_attributes
    assert [] == extra_attributes, "Payload contained additional attributes: #{extra_attributes |> Enum.join(", ")}"

    missing_attributes = expected_attributes -- attribute_names
    assert [] == missing_attributes, "Payload was missing attributes: #{missing_attributes |> Enum.join(", ")}"
  end

  def assert_payload(actual, expected, options \\ []) do
    comparison = compare_payloads(actual, expected, options)
    assert :ok == comparison, error_message(comparison)

    actual
  end

  defp _stringify_items([]), do: []
  defp _stringify_items([head|tail]) when is_atom(head) do
    [Atom.to_string(head)|_stringify_items(tail)]
  end
  defp _stringify_items([head|tail]) when is_binary(head) do
    [head|_stringify_items(tail)]
  end

  defp error_message(:ok), do: ""
  defp error_message({:error, message}), do: "Payload did not match expected\n\n" <> message

  defp compare_property(actual, expected, property_name, options) do
    actual_value = Map.fetch(actual, property_name)

    case {Map.fetch(actual, property_name), Map.fetch(expected, property_name)} do
      {:error, :error} -> :ok
      {:error, {:ok, expected_value}} -> format_missing_actual_error(actual_value, expected_value, property_name)
      {_, :error} -> :ok
      {{:ok, actual_value}, {:ok, expected_value}} ->
         compare_resources(actual_value, expected_value, options)
         |> case do
           {:error, message} ->
             {:error, "\"#{property_name}\" did not match expected\n" <> message}
           :ok -> :ok
           {:ok, _} -> :ok # compare_resources_list returns this tuple due to reduce function
         end
    end
  end

  defp merge_results(existing, new) do
    case {existing, new} do
      {:ok, state} -> state
      {state, :ok} -> state
      {{:error, existing_message}, {:error, new_message}} ->
        {:error, existing_message <> "\n" <> new_message}
    end
  end

  defp compare_payloads(actual, expected, options) do
    expected = normalize_map(expected)

    compare_property(actual, expected, "data", options)
    |> merge_results(compare_property(actual, expected, "included", options))
    |> merge_results(compare_property(actual, expected, "meta", options))
    |> merge_results(compare_property(actual, expected, "links", options))
  end

  defp format_missing_actual_error(:error, _expected, property_name) do
    {:error, "\"#{property_name}\" was expected, but was not present\n"}
  end

  defp compare_resources(actual, expected, options) when is_map(actual) do
    filtered_actual = filter_out_extra_keys(actual, expected, options)

    if (filtered_actual == expected) do
      :ok
    else
      {:error, """
        Expected:
          #{inspect expected}
        Actual (filtered):
          #{inspect filtered_actual}
        Actual (untouched):
          #{inspect actual}
        """}
    end
  end

  defp compare_resources(actual, expected, options) when is_list(actual) do
    if Dict.get(options, :ignore_list_order) do
      compare_resources_list(actual, expected, options, :ignore_list_order)
    else
      compare_resources_list(actual, expected, options)
    end
  end

  defp compare_resources_list(actual, expected, options, :ignore_list_order) when is_list(actual) do
    filtered_actual = filter_out_extra_keys(actual, expected, options)

    extra_resources = filtered_actual -- expected
    missing_resources = expected -- filtered_actual

    if Enum.empty?(extra_resources) && Enum.empty?(missing_resources) do
      :ok
    else
      message = ""
      if Enum.any?(extra_resources) do
        extra_resources_inspection =
          extra_resources
          |> Enum.map(&inspect/1)
          |> Enum.join(",\n  ")
        message = message <> "Contained extra resources:\n  " <> extra_resources_inspection <> "\n"
      end
      if Enum.any?(missing_resources) do
        missing_resources_inspection =
          missing_resources
          |> Enum.map(&inspect/1)
          |> Enum.join(",\n  ")
        message = message <> "Missing resources:\n  " <> missing_resources_inspection <> "\n"
      end
      {:error, message}
    end
  end

  defp compare_resources_list(actual, expected, options) when is_list(actual) do
    actual
    |> Enum.zip(expected)
    |> Enum.map(fn
      {actual_resource, expected_resource} ->
        compare_resources(actual_resource, expected_resource, options)
    end)
    |> Enum.with_index()
    |> Enum.reduce({:ok, ""}, fn
      {{:error, message}, index}, {_state, acc_message} ->
        {:error, acc_message <> "\nResource at index #{index} did not match\n" <> message}
      _, acc -> acc
    end)
  end

  defp normalize_map(map) when is_map(map) do
    map
    |> Enum.map(&normalize_map_entry/1)
    |> Enum.into(%{})
  end

  defp normalize_map(list) when is_list(list), do: Enum.map(list, &normalize_map/1)
  defp normalize_map(value), do: value

  defp normalize_map_entry({key, value}) when is_map(value) or is_list(value), do: {normalize_key(key), normalize_map(value)}
  defp normalize_map_entry({key, value}), do: {normalize_key(key), value}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp filter_out_extra_keys(payload, expected_payload, options) when is_list(payload) do
    filtered_payload = payload
    |> Enum.with_index
    # When payload is longer than expected_payload, we need to filter out the other potential matches based on an existing payload
    |> Enum.map(fn {value, index} -> filter_out_extra_keys(value, Enum.at(expected_payload, index) || Enum.at(expected_payload, 0), options) end)

    if Dict.get(options, :ignore_list_order) do
      if filtered_payload -- expected_payload == [] && expected_payload -- filtered_payload == [] do
        filtered_payload = expected_payload
      end
    end

    filtered_payload
  end

  defp filter_out_extra_keys(payload, nil, _options) when is_map(payload), do: payload

  defp filter_out_extra_keys(payload, expected_payload, options) when is_map(payload) do
    payload
    |> Enum.filter(fn
      {key, _value} ->
        expected_payload
        |> Map.keys
        |> Enum.member?(key)
    end)
    |> Enum.map(fn
      {key, value} when is_map(value) or is_list(value) -> {key, filter_out_extra_keys(value, expected_payload[key], options)}
      entry -> entry
    end)
    |> Enum.into(%{})
  end

  defp filter_out_extra_keys(payload, _expected_payload, _options), do: payload

  ## Composable Helpers

  def assert_data(payload, record, opts \\ []) do
    serialized_record = serialize_record(record, opts)

    assert_record(payload["data"], serialized_record)

    payload
  end

  def refute_data(payload, record, opts \\ []) do
    serialized_record = serialize_record(record, opts)

    refute_record(payload["data"], serialized_record)

    payload
  end

  def assert_relationship(payload, child, opts \\ []) do
    serialized_child = serialize_record(child, opts)
    serialized_parent = serialize_record(opts[:for], opts)

    data_parent = assert_record(payload["data"], serialized_parent)

    as = opts[:as] || serialized_child["type"]

    relationship =
      get_in(data_parent, ["relationships", as, "data"])
      |> List.wrap()
      |> Enum.find(&(meta_data_compare(&1, serialized_child)))

    assert relationship, "could not find the relationship in the parent record"

    if opts[:included] do
      assert_included(payload, child)
    end

    payload
  end

  def refute_relationship(payload, child, opts \\ []) do
    serialized_child = serialize_record(child, opts)
    serialized_parent = serialize_record(opts[:for], opts)

    data_parent = assert_record(payload["data"], serialized_parent)

    as = opts[:as] || serialized_child["type"]

    relationship =
      get_in(data_parent, ["relationships", as, "data"])
      |> List.wrap()
      |> Enum.find(&(meta_data_compare(&1, serialized_child)))

    refute relationship, "found the relationship in the parent record"

    payload
  end

  def assert_included(payload, record, opts \\ []) do
    serialized_record = serialize_record(record, opts)

    assert_record(payload["included"], serialized_record)

    payload
  end

  def refute_included(payload, record, opts \\ []) do
    serialized_record = serialize_record(record, opts)

    refute_record(payload["included"], serialized_record)

    payload
  end

  defp assert_record(data, record) do
    data = find_record(data, record)

    assert data, "could not find the record with matching id or type in the data"

    Enum.each data["attributes"], fn({key, value}) ->
      assert value == format(record["attributes"][key])
    end

    data
  end

  defp refute_record(data, record) do
    case find_record(data, record) do
      nil -> nil
      data ->

        attrs = data["attributes"]

        matching = Enum.reduce attrs, [], fn({key, value}, acc) ->
          if value == format(record["attributes"][key]) do
            acc ++ [{key, value}]
          else
            acc
          end
        end

        refute Map.keys(attrs) |> length() == length(matching), "did not expect #{inspect record} to be found. Matching keys: #{inspect matching}"

        data
    end
  end

  def meta_data_compare(record_1, record_2),
    do: record_1["id"] == record_2["id"] && record_1["type"] == record_2["type"]

  defp format(%{__struct__: Ecto.DateTime} = value),
    do: apply(Ecto.DateTime, :to_iso8601, [value])
  defp format(%{__struct__: Ecto.Time} = value),
    do: apply(Ecto.Time, :to_iso8601, [value])
  defp format(%{__struct__: Ecto.Date} = value),
    do: apply(Ecto.Date, :to_string, [value])
  defp format(value), do: value

  defp serialize_record(record, opts) do
    primary_key = primary_key_from(record, opts)
    type = type_from(record, opts)

    data = %{
      "id" => stringify(Map.get(record, primary_key)),
      "type" => type
    }

    attributes =
      record
      |> Map.from_struct()
      |> Enum.into(%{}, fn({key, value}) ->
        {serialize_key(key), value}
      end)
      |> Map.delete(serialize_key(primary_key))

    Map.put(data, "attributes", attributes)
  end

  defp find_record(data, record) do
    data
    |> List.wrap()
    |> Enum.find(&(meta_data_compare(&1, record)))
  end

  defp primary_key_from(_record, opts) do
    atomize(opts[:primary_key]) || :id
  end

  defp type_from(record, opts) do
    default =
      record.__struct__
      |> Module.split()
      |> List.last()
      |> Mix.Utils.underscore()
      |> dasherize

    opts[:type] || default
  end

  defp dasherize(data), do:  String.replace(data, "_", "-")

  defp atomize(value) when is_binary(value),
    do: String.to_atom(value)
  defp atomize(value) when is_atom(value),
    do: value

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value),
    do: value
  defp stringify(value) when is_integer(value),
    do: Integer.to_string(value)

  defp serialize_key(key) when is_atom(key),
    do: key
        |> Atom.to_string()
        |> serialize_key()
  defp serialize_key(key) when is_binary(key),
    do: key
        |> String.downcase()
        |> String.replace("_", "-")
end
