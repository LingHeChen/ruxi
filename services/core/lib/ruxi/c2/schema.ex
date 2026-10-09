defmodule Ruxi.C2.Schema do
  @moduledoc "Validates the exact JSON Schema vocabulary used by the versioned C2 contracts."
  def load(name) do
    Application.app_dir(:ruxi, "priv/c2/#{name}.schema.json") |> File.read!() |> Jason.decode!()
  end

  def validate(value, schema), do: check(value, schema, schema, "", 0)

  defp error(path, message),
    do: [%{"code" => "SCHEMA_INVALID", "pointer" => path, "message" => message}]

  defp check(_, _, _, path, depth) when depth > 40, do: error(path, "结构层级超过限制")
  defp check(_, true, _, _, _), do: []
  defp check(_, false, _, path, _), do: error(path, "不允许此字段")

  defp check(value, %{"$ref" => ref}, root, path, depth) do
    target =
      ref
      |> String.trim_leading("#/")
      |> String.split("/")
      |> Enum.reduce(root, &Map.fetch!(&2, &1))

    check(value, target, root, path, depth + 1)
  end

  defp check(value, schema, root, path, depth) do
    base =
      if Map.has_key?(schema, "const") and value !== schema["const"],
        do: error(path, "固定值不匹配"),
        else: []

    base =
      base ++
        if(schema["enum"] && not Enum.any?(schema["enum"], &(&1 === value)),
          do: error(path, "不在允许选项中"),
          else: []
        )

    base =
      base ++
        if(
          schema["oneOf"] &&
            Enum.count(schema["oneOf"], &(check(value, &1, root, path, depth + 1) == [])) != 1,
          do: error(path, "结构必须符合一个且仅一个允许类型"),
          else: []
        )

    types = List.wrap(schema["type"])

    if types != [] and not Enum.any?(types, &type?(value, &1)) do
      base ++ error(path, "字段类型不匹配")
    else
      base ++ constraints(value, schema, root, path, depth)
    end
  end

  defp type?(v, "object"), do: is_map(v)
  defp type?(v, "array"), do: is_list(v)
  defp type?(v, "string"), do: is_binary(v)
  defp type?(v, "integer"), do: is_integer(v)
  defp type?(v, "number"), do: is_number(v)
  defp type?(v, "boolean"), do: is_boolean(v)
  defp type?(v, "null"), do: is_nil(v)
  defp type?(_, _), do: false

  defp constraints(value, schema, root, path, depth) when is_map(value) do
    required =
      Enum.flat_map(schema["required"] || [], fn key ->
        if Map.has_key?(value, key), do: [], else: error(child(path, key), "缺少必填字段")
      end)

    properties = schema["properties"] || %{}

    required ++
      Enum.flat_map(value, fn {key, item} ->
        names =
          if schema["propertyNames"],
            do: check(key, schema["propertyNames"], root, child(path, key), depth + 1),
            else: []

        field = Map.get(properties, key, Map.get(schema, "additionalProperties", true))
        names ++ check(item, field, root, child(path, key), depth + 1)
      end)
  end

  defp constraints(value, schema, root, path, depth) when is_list(value) do
    bounds(length(value), schema["minItems"], schema["maxItems"], path) ++
      if(schema["items"],
        do:
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {v, i} ->
            check(v, schema["items"], root, child(path, i), depth + 1)
          end),
        else: []
      )
  end

  defp constraints(value, schema, _, path, _) when is_binary(value) do
    bounds(String.length(value), schema["minLength"], schema["maxLength"], path) ++
      if(schema["pattern"] && not Regex.match?(Regex.compile!(schema["pattern"]), value),
        do: error(path, "编号格式不正确"),
        else: []
      ) ++
      if(schema["format"] == "uuid" and not Ruxi.Contract.uuid?(value),
        do: error(path, "需要 UUID"),
        else: []
      )
  end

  defp constraints(value, schema, _, path, _) when is_number(value),
    do: bounds(value, schema["minimum"], schema["maximum"], path)

  defp constraints(_, _, _, _, _), do: []

  defp bounds(v, min, max, path),
    do:
      if((min != nil and v < min) or (max != nil and v > max),
        do: error(path, "超出允许范围"),
        else: []
      )

  defp child(path, key),
    do: path <> "/" <> (to_string(key) |> String.replace("~", "~0") |> String.replace("/", "~1"))
end
